"""Minimal ACP (Agent Client Protocol) client for the hermes-acp stdio server.

Replaces the gateway /v1/runs SSE path as the run transport: the gateway never
forwards live reasoning (its /v1/runs platform doesn't register the agent's
reasoning_callback), while the ACP adapter wires every streaming callback and
sends thought/message/tool-call updates as they happen.

Protocol: newline-delimited JSON-RPC 2.0 over the subprocess's stdin/stdout
(agent-client-protocol v1). We implement just the client half the app needs:

    client → agent : initialize, session/new, session/load, session/prompt,
                     session/cancel (notification), session/set_model
    agent → client : session/update (notification), session/request_permission
                     (request — answered via respond_permission())

No Qt imports here — callbacks fire on this client's reader thread; the
caller (HermesBackend) marshals them onto the GUI thread itself.
"""
from __future__ import annotations

import json
import logging
import os
import subprocess
import threading

log = logging.getLogger(__name__)

PROTOCOL_VERSION = 1


class AcpError(Exception):
    """JSON-RPC error response, or transport failure."""

    def __init__(self, message: str, code: int | None = None, data=None):
        super().__init__(message)
        self.code = code
        self.data = data


class AcpClient:
    """One hermes-acp subprocess; thread-safe request/notify surface.

    Lifecycle: construct once, ``start()`` lazily (it spawns + initializes),
    ``shutdown()`` on app exit. If the subprocess dies, ``start()`` may be
    called again — it re-spawns from scratch (sessions must be re-loaded).
    """

    def __init__(
        self,
        command: str | list[str] = "hermes-acp",
        on_update=None,        # fn(session_id: str, update: dict)
        on_permission=None,    # fn(request_id, session_id: str, params: dict)
    ) -> None:
        self._command = [command] if isinstance(command, str) else list(command)
        self._on_update = on_update
        self._on_permission = on_permission

        self._proc: subprocess.Popen | None = None
        self._write_lock = threading.Lock()
        self._state_lock = threading.Lock()
        self._next_id = 0
        self._pending: dict[int, dict] = {}  # id -> {event, result, error}
        self._initialized = False
        self.agent_info: dict = {}

    # ───────────────────────────────────────────────────────────
    #  Lifecycle
    # ───────────────────────────────────────────────────────────
    def is_alive(self) -> bool:
        return self._proc is not None and self._proc.poll() is None and self._initialized

    def start(self, timeout: float = 30.0) -> None:
        """Spawn the subprocess (if needed) and run the initialize handshake."""
        with self._state_lock:
            if self._proc is not None and self._proc.poll() is None and self._initialized:
                return
            self._spawn()
        result = self._request(
            "initialize",
            {
                "protocolVersion": PROTOCOL_VERSION,
                "clientCapabilities": {
                    "fs": {"readTextFile": False, "writeTextFile": False},
                    "terminal": False,
                },
                "clientInfo": {"name": "hermes-app", "version": "1.0"},
            },
            timeout=timeout,
        )
        self.agent_info = result.get("agentInfo") or {}
        self._initialized = True

    def _spawn(self) -> None:
        self._initialized = False
        self._pending.clear()
        self._proc = subprocess.Popen(
            self._command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            # The agent runs tools relative to its cwd; pin it to $HOME so a
            # run never executes relative to wherever the app was launched.
            cwd=os.path.expanduser("~"),
        )
        threading.Thread(target=self._read_loop, args=(self._proc,), daemon=True).start()
        threading.Thread(target=self._stderr_loop, args=(self._proc,), daemon=True).start()

    def shutdown(self) -> None:
        proc = self._proc
        self._proc = None
        self._initialized = False
        if proc is not None and proc.poll() is None:
            try:
                proc.terminate()
            except OSError:
                pass

    # ───────────────────────────────────────────────────────────
    #  Sessions
    # ───────────────────────────────────────────────────────────
    def new_session(self, cwd: str | None = None, timeout: float = 60.0) -> dict:
        """Returns the session/new result: {sessionId, models, ...}."""
        return self._request(
            "session/new",
            {"cwd": cwd or os.path.expanduser("~"), "mcpServers": []},
            timeout=timeout,
        )

    def load_session(self, session_id: str, cwd: str | None = None, timeout: float = 60.0) -> dict:
        """Attach to a persisted session. The agent replays history as
        session/update notifications before responding — the caller decides
        whether to render or ignore those."""
        return self._request(
            "session/load",
            {
                "sessionId": session_id,
                "cwd": cwd or os.path.expanduser("~"),
                "mcpServers": [],
            },
            timeout=timeout,
        )

    def set_model(self, session_id: str, model_id: str, timeout: float = 15.0) -> None:
        self._request(
            "session/set_model",
            {"sessionId": session_id, "modelId": model_id},
            timeout=timeout,
        )

    def prompt(self, session_id: str, text: str) -> dict:
        """Run one turn. Blocks until the agent finishes (updates stream to
        on_update meanwhile). Returns {stopReason, usage?}. No timeout —
        agent runs are open-ended; a dead subprocess unblocks with AcpError."""
        return self._request(
            "session/prompt",
            {"sessionId": session_id, "prompt": [{"type": "text", "text": text}]},
            timeout=None,
        )

    def cancel(self, session_id: str) -> None:
        """Fire-and-forget session/cancel; the in-flight prompt() then
        returns with stopReason=cancelled."""
        self._notify("session/cancel", {"sessionId": session_id})

    def respond_permission(self, request_id, option_id: str | None) -> None:
        """Answer a session/request_permission. None option = cancelled."""
        if option_id is None:
            outcome = {"outcome": {"outcome": "cancelled"}}
        else:
            outcome = {"outcome": {"outcome": "selected", "optionId": option_id}}
        self._send({"jsonrpc": "2.0", "id": request_id, "result": outcome})

    # ───────────────────────────────────────────────────────────
    #  JSON-RPC plumbing
    # ───────────────────────────────────────────────────────────
    def _send(self, msg: dict) -> None:
        proc = self._proc
        if proc is None or proc.poll() is not None or proc.stdin is None:
            raise AcpError("hermes-acp process is not running")
        data = json.dumps(msg) + "\n"
        with self._write_lock:
            try:
                proc.stdin.write(data)
                proc.stdin.flush()
            except (OSError, ValueError) as e:
                raise AcpError(f"write to hermes-acp failed: {e}") from e

    def _notify(self, method: str, params: dict) -> None:
        self._send({"jsonrpc": "2.0", "method": method, "params": params})

    def _request(self, method: str, params: dict, timeout: float | None) -> dict:
        with self._state_lock:
            self._next_id += 1
            req_id = self._next_id
            entry = {"event": threading.Event(), "result": None, "error": None}
            self._pending[req_id] = entry
        try:
            self._send({"jsonrpc": "2.0", "id": req_id, "method": method, "params": params})
        except AcpError:
            self._pending.pop(req_id, None)
            raise
        if not entry["event"].wait(timeout):
            self._pending.pop(req_id, None)
            raise AcpError(f"{method} timed out after {timeout}s")
        if entry["error"] is not None:
            err = entry["error"]
            raise AcpError(
                err.get("message") or f"{method} failed",
                code=err.get("code"),
                data=err.get("data"),
            )
        return entry["result"] or {}

    def _fail_all_pending(self, reason: str) -> None:
        with self._state_lock:
            pending, self._pending = self._pending, {}
        for entry in pending.values():
            entry["error"] = {"message": reason}
            entry["event"].set()

    # ───────────────────────────────────────────────────────────
    #  Reader threads
    # ───────────────────────────────────────────────────────────
    def _read_loop(self, proc: subprocess.Popen) -> None:
        try:
            for line in proc.stdout:
                line = line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except ValueError:
                    log.warning("ACP: non-JSON line on stdout: %.200s", line)
                    continue
                try:
                    self._dispatch(msg)
                except Exception:
                    log.exception("ACP: dispatch failed for %.200s", line)
        finally:
            self._initialized = False
            self._fail_all_pending("hermes-acp process exited")
            log.info("ACP: reader loop ended (process exited)")

    def _stderr_loop(self, proc: subprocess.Popen) -> None:
        for line in proc.stderr:
            log.debug("hermes-acp: %s", line.rstrip())

    def _dispatch(self, msg: dict) -> None:
        if "method" in msg and "id" in msg:
            # Agent → client request. Only permission requests get a real
            # handler; anything else (fs/terminal — capabilities we declared
            # false) is refused so the agent never blocks on us.
            if msg["method"] == "session/request_permission" and self._on_permission:
                params = msg.get("params") or {}
                self._on_permission(msg["id"], params.get("sessionId") or "", params)
            else:
                self._send({
                    "jsonrpc": "2.0",
                    "id": msg["id"],
                    "error": {"code": -32601, "message": f"unsupported: {msg['method']}"},
                })
        elif "method" in msg:
            if msg["method"] == "session/update" and self._on_update:
                params = msg.get("params") or {}
                self._on_update(params.get("sessionId") or "", params.get("update") or {})
        elif "id" in msg:
            entry = self._pending.pop(msg["id"], None)
            if entry is None:
                return
            if "error" in msg:
                entry["error"] = msg["error"] or {"message": "unknown ACP error"}
            else:
                entry["result"] = msg.get("result") or {}
            entry["event"].set()
