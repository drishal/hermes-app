"""HermesBackend — the app's single source of truth.

Replaces the old HermesService.qml, which drove everything through curl/python3
subprocesses. This is plain in-process Python: httpx for HTTP + SSE, sqlite3 for
the DB, threads for anything blocking. It owns the message list and runs the SSE
event state machine; a thin QML coordinator (HermesService.qml) mirrors the
emitted signals into the ListModels the views bind to.
"""
from __future__ import annotations

import json
import logging
import os
import queue as _queue
import re
import threading
import time

import httpx
from PySide6.QtCore import (
    Property,
    QObject,
    QTimer,
    Signal,
    Slot,
)

from . import db, welcome
from .acp_client import AcpClient, AcpError

log = logging.getLogger(__name__)

SETTINGS_PATH = os.path.expanduser("~/.config/HermesApp/settings.json")
DEFAULTS = {
    "apiBaseUrl": "http://127.0.0.1:8642",
    "apiKey": "",
    "hermesHome": "~/.hermes",
    "selectedModel": "",
    # ACP is the primary run transport (live thinking + tool streaming); the
    # gateway /v1/runs SSE path remains as automatic fallback when the
    # hermes-acp binary is missing or fails to start.
    "acpCommand": "hermes-acp",
    # Optional path to a base16/base24 scheme (YAML or JSON) for the UI palette.
    # See backend/theme_palette.py for the resolution order; applied at startup.
    "themePath": "",
}


class HermesBackend(QObject):
    # ── Coordinator-facing signals ─────────────────────────────
    sessionsReset = Signal(list)
    messagesReset = Signal(list)
    messageAppended = Signal("QVariant")
    messageUpdated = Signal(int, "QVariant")

    runStarted = Signal()
    runCompleted = Signal(str)
    runFailed = Signal(str)

    # ── Property notifications ─────────────────────────────────
    connectedChanged = Signal()
    currentSessionIdChanged = Signal()
    currentModelChanged = Signal()
    isRunningChanged = Signal()
    currentRunIdChanged = Signal()
    lastUsageChanged = Signal()
    lastErrorChanged = Signal()
    welcomeInfoChanged = Signal()
    configChanged = Signal()
    availableModelsChanged = Signal()
    modelsLoadingChanged = Signal()

    def __init__(self) -> None:
        super().__init__()
        self._lock = threading.Lock()
        self._messages: list[dict] = []

        # Config (loaded from settings.json, with env-key fallback)
        s = self._load_settings()
        self._apiBaseUrl = s["apiBaseUrl"]
        self._apiKey = s["apiKey"]
        self._hermesHome = s["hermesHome"]
        self._selectedModel = s["selectedModel"]
        self._acpCommand = s["acpCommand"]
        self._themePath = s["themePath"]
        self._envApiKey = ""

        # ACP run transport (lazily spawned on first send)
        self._acp: AcpClient | None = None
        self._acpLoadedSessions: set[str] = set()
        self._acpReplaying = False      # suppress session/load history replay
        self._acpRunSession = ""        # session id of the in-flight ACP run
        self._pendingPermission = None  # (request_id, options) awaiting the user
        # Sessions whose client-side view was truncated (edit/retry). The ACP
        # agent keeps the full server-side history, so these must run through
        # the gateway path, which replays conversation_history explicitly.
        self._divergedSessions: set[str] = set()

        # Runtime state
        self._connected = False
        self._currentSessionId = ""
        self._currentModel = ""
        self._isRunning = False
        self._currentRunId = ""
        self._lastUsage: dict = {}
        self._lastError = ""
        self._welcomeInfo: dict = {}
        self._availableModels: list = []
        self._modelsLoading = False

        # SSE gating
        self._accepting = False
        self._sseStop = threading.Event()

        # GUI thread safety: daemon threads emit signals through this queue
        # so that ListModel mutations always happen on the main thread.
        self._gui_queue: _queue.Queue = _queue.Queue()
        self._gui_timer = QTimer(self)
        self._gui_timer.setInterval(16)  # ~60 fps
        self._gui_timer.timeout.connect(self._drain_gui_queue)
        self._gui_timer.start()

        self._client = httpx.Client(timeout=httpx.Timeout(10.0, read=None))

        self._healthTimer = QTimer(self)
        self._healthTimer.setInterval(15000)
        self._healthTimer.timeout.connect(self.checkHealth)

    # ───────────────────────────────────────────────────────────
    #  Lifecycle
    # ───────────────────────────────────────────────────────────
    def start(self) -> None:
        """Kick off the initial loads once QML is wired up."""
        self._discover_env_key()
        self._healthTimer.start()
        self.checkHealth()
        self.loadSessions()
        self.loadWelcomeInfo()

    # ───────────────────────────────────────────────────────────
    #  Settings
    # ───────────────────────────────────────────────────────────
    def _load_settings(self) -> dict:
        data = dict(DEFAULTS)
        try:
            with open(SETTINGS_PATH) as f:
                data.update({k: v for k, v in json.load(f).items() if k in DEFAULTS})
        except (OSError, ValueError):
            pass
        return data

    def _save_settings(self) -> None:
        os.makedirs(os.path.dirname(SETTINGS_PATH), exist_ok=True)
        try:
            with open(SETTINGS_PATH, "w") as f:
                json.dump(
                    {
                        "apiBaseUrl": self._apiBaseUrl,
                        "apiKey": self._apiKey,
                        "hermesHome": self._hermesHome,
                        "selectedModel": self._selectedModel,
                        "acpCommand": self._acpCommand,
                        "themePath": self._themePath,
                    },
                    f,
                    indent=2,
                )
        except OSError:
            pass

    def _discover_env_key(self) -> None:
        """When no explicit key is set, read API_SERVER_KEY from <home>/.env so
        the local gateway works out of the box."""
        if self._apiKey:
            return
        env_path = os.path.join(os.path.expanduser(self._hermesHome), ".env")
        try:
            with open(env_path) as f:
                for line in f:
                    m = re.match(
                        r"^\s*(?:export\s+)?API_SERVER_KEY=(.*)$", line.rstrip("\n")
                    )
                    if m:
                        self._envApiKey = m.group(1).strip().strip("\"'")
                        break
        except OSError:
            pass

    @property
    def _effective_key(self) -> str:
        return self._apiKey or self._envApiKey

    def _headers(self, json_body: bool = False) -> dict:
        h = {}
        if self._effective_key:
            h["Authorization"] = f"Bearer {self._effective_key}"
        if json_body:
            h["Content-Type"] = "application/json"
        return h

    # ───────────────────────────────────────────────────────────
    #  Threading helper
    # ───────────────────────────────────────────────────────────
    @staticmethod
    def _spawn(fn) -> None:
        # Daemon threads so a blocked SSE read can never hold up process exit.
        threading.Thread(target=fn, daemon=True).start()

    # ───────────────────────────────────────────────────────────
    #  GUI-thread marshal
    # ───────────────────────────────────────────────────────────
    def _gui(self, fn) -> None:
        """Schedule *fn* to run on the GUI thread.  Thread-safe.

        Use this whenever a signal must be emitted from a daemon thread
        (e.g. the SSE reader) so that the corresponding QML slot — which
        mutates a ListModel — always runs on the main thread.
        """
        self._gui_queue.put(fn)

    def _drain_gui_queue(self) -> None:
        """Process pending GUI updates (runs on the main thread via QTimer)."""
        for _ in range(64):
            try:
                fn = self._gui_queue.get_nowait()
            except _queue.Empty:
                break
            try:
                fn()
            except Exception:
                log.exception("GUI queue callback failed")

    # ───────────────────────────────────────────────────────────
    #  Health
    # ───────────────────────────────────────────────────────────
    @Slot()
    def checkHealth(self) -> None:
        self._spawn(self._do_health)

    def _do_health(self) -> None:
        ok = False
        try:
            r = self._client.get(
                self._apiBaseUrl + "/health", headers=self._headers(), timeout=3.0
            )
            data = r.json()
            ok = data.get("status") in ("ok", "healthy")
            if data.get("model") and not (self._acp and self._acp.is_alive()):
                self._set_current_model(data["model"])
        except Exception:
            pass
        # A live ACP subprocess can run turns without the gateway.
        if not ok and self._acp is not None and self._acp.is_alive():
            ok = True
        self._set_connected(ok)

    # ───────────────────────────────────────────────────────────
    #  Sessions / messages (sqlite)
    # ───────────────────────────────────────────────────────────
    @Slot()
    def loadSessions(self) -> None:
        def work():
            try:
                rows = db.load_sessions(self._db_path())
            except Exception:
                rows = []
            self._gui(lambda r=rows: self.sessionsReset.emit(r))

        self._spawn(work)

    @Slot(str)
    def loadMessages(self, session_id: str) -> None:
        self._detach_run()
        self._set_current_session(session_id)
        with self._lock:
            self._messages = []
        self.messagesReset.emit([])

        def work():
            try:
                rows = db.load_messages(self._db_path(), session_id)
            except Exception:
                rows = []
            with self._lock:
                self._messages = list(rows)
            self._gui(lambda r=rows: self.messagesReset.emit(r))

        self._spawn(work)

    @Slot()
    def newChat(self) -> None:
        self._detach_run()
        self._set_current_session("")
        with self._lock:
            self._messages = []
        self.messagesReset.emit([])

    @Slot(int)
    def truncateTo(self, row: int) -> None:
        """Drop every row from `row` onward. Used by edit-and-resend: the user
        message is removed and its text loaded back into the input."""
        if self._isRunning:
            return
        with self._lock:
            if row < 0 or row > len(self._messages):
                return
            self._messages = self._messages[:row]
            snapshot = list(self._messages)
        if self._currentSessionId:
            self._divergedSessions.add(self._currentSessionId)
        self.messagesReset.emit(snapshot)

    @Slot(int, str)
    def resendFrom(self, row: int, text: str) -> None:
        """Truncate to before `row`, then send `text` as a fresh turn. Powers
        retry (resend the preceding user message) from the message actions."""
        if self._isRunning or not text.strip():
            return
        with self._lock:
            if row < 0 or row > len(self._messages):
                return
            self._messages = self._messages[:row]
            snapshot = list(self._messages)
        if self._currentSessionId:
            self._divergedSessions.add(self._currentSessionId)
        self.messagesReset.emit(snapshot)
        self.sendMessage(text)

    def _db_path(self) -> str:
        return os.path.join(os.path.expanduser(self._hermesHome), "state.db")

    # ───────────────────────────────────────────────────────────
    #  Welcome
    # ───────────────────────────────────────────────────────────
    @Slot()
    def loadWelcomeInfo(self) -> None:
        def work():
            try:
                info = welcome.gather(self._hermesHome)
            except Exception:
                info = {}
            self._set_welcome(info)

        self._spawn(work)

    # ───────────────────────────────────────────────────────────
    #  Send message → POST /v1/runs, then stream events
    # ───────────────────────────────────────────────────────────
    @Slot(str)
    def sendMessage(self, text: str) -> None:
        if self._isRunning or not text.strip():
            return
        history = self._conversation_history()

        self._append(db._row("user", content=text, timestamp=time.time()))
        self._append(
            db._row(
                "assistant",
                isStreaming=True,
                timestamp=time.time(),
                startedAt=time.time(),
                usage={},
                duration=0,
            )
        )

        body = {"input": text, "conversation_history": history}
        if self._currentSessionId:
            body["session_id"] = self._currentSessionId
        if self._selectedModel:
            body["model"] = self._selectedModel

        # ACP first (live thinking/tool streaming); gateway SSE as fallback.
        self._spawn(lambda: self._do_run_acp(text, body))

    def _do_run(self, body: dict) -> None:
        try:
            r = self._client.post(
                self._apiBaseUrl + "/v1/runs",
                headers=self._headers(json_body=True),
                json=body,
                timeout=15.0,
            )
            resp = r.json()
        except Exception as e:
            self._fail_pending(f"Failed to start run: {e}")
            return

        run_id = resp.get("run_id")
        if not run_id:
            err = resp.get("error")
            if isinstance(err, dict):
                msg = err.get("message") or "Unknown error"
            elif isinstance(err, str):
                msg = err
            else:
                msg = "Gateway returned no run_id"
            self._fail_pending(msg)
            return

        self._set_current_run(run_id)
        self._set_running(True)
        self._gui(self.runStarted.emit)
        self._stream_events(run_id)

    # ───────────────────────────────────────────────────────────
    #  ACP run path (primary) — hermes-acp subprocess, JSON-RPC stdio
    # ───────────────────────────────────────────────────────────
    def _ensure_acp(self) -> AcpClient:
        if self._acp is None:
            self._acp = AcpClient(
                command=self._acpCommand,
                on_update=self._on_acp_update,
                on_permission=self._on_acp_permission,
            )
        if not self._acp.is_alive():
            # Fresh process knows none of our previously loaded sessions.
            self._acpLoadedSessions.clear()
            self._acp.start()
        return self._acp

    def _do_run_acp(self, text: str, fallback_body: dict) -> None:
        """Run one turn over ACP. Falls back to the gateway SSE path when the
        hermes-acp subprocess can't start, or when an existing session can't
        be attached (the gateway path replays conversation_history itself)."""
        sid = self._currentSessionId
        if sid and sid in self._divergedSessions:
            self._do_run(fallback_body)
            return
        try:
            client = self._ensure_acp()
        except (AcpError, OSError) as e:
            log.warning("ACP unavailable (%s) — falling back to gateway", e)
            self._do_run(fallback_body)
            return
        try:
            if sid and sid not in self._acpLoadedSessions:
                try:
                    self._acpReplaying = True
                    client.load_session(sid)
                finally:
                    self._acpReplaying = False
                self._acpLoadedSessions.add(sid)
            elif not sid:
                res = client.new_session()
                sid = res.get("sessionId") or ""
                if not sid:
                    raise AcpError("session/new returned no sessionId")
                self._acpLoadedSessions.add(sid)
                self._set_current_session(sid)
                self._apply_acp_models(client, sid, res.get("models") or {})
        except AcpError as e:
            log.warning("ACP session setup failed (%s) — falling back to gateway", e)
            self._do_run(fallback_body)
            return

        self._acpRunSession = sid
        self._accepting = True
        self._set_running(True)
        self._gui(self.runStarted.emit)
        try:
            result = client.prompt(sid, text)
        except AcpError as e:
            if self._acpRunSession == sid:  # not detached meanwhile
                self._acpRunSession = ""
                self._fail_pending(str(e))
            return
        # A session switch mid-run detaches us: results were already ignored,
        # and a newer run may own the state now — touch nothing.
        if self._acpRunSession != sid:
            return
        self._acpRunSession = ""
        self._accepting = False
        stop = result.get("stopReason") or ""
        if stop in ("cancelled", "canceled"):
            self._cancel_run()
            return
        usage = result.get("usage") or {}
        event = {
            "output": self._last_assistant_text(),
            "usage": {
                "input_tokens": usage.get("inputTokens") or 0,
                "output_tokens": usage.get("outputTokens") or 0,
                "total_tokens": usage.get("totalTokens") or 0,
            } if usage else {},
        }
        if stop == "refusal" or stop.startswith("error"):
            self._fail_run(f"Run stopped: {stop}")
            return
        self._finalize_run(event)

    def _apply_acp_models(self, client: AcpClient, sid: str, models: dict) -> None:
        """Reflect the agent's current model in the UI; honour selectedModel."""
        current = models.get("currentModelId") or ""
        available = models.get("availableModels") or []
        if self._selectedModel and self._selectedModel != current:
            # Accept either the full modelId or the bare display name.
            for m in available:
                if self._selectedModel in (m.get("modelId"), m.get("name")):
                    try:
                        client.set_model(sid, m["modelId"])
                        current = m["modelId"]
                    except AcpError as e:
                        log.warning("session/set_model failed: %s", e)
                    break
        self._set_models(self._normalize_models(available))
        if current:
            self._set_current_model(current.split(":")[-1])

    @staticmethod
    def _normalize_models(available: list) -> list:
        """ACP ModelInfo → UI rows: {modelId, name, provider, description}.

        The adapter encodes the provider into modelId ("<provider>:<model>") and
        repeats it in description ("Provider: <Label> • <desc> • current"); pull
        out a clean provider label and a description without that boilerplate."""
        out = []
        for m in available or []:
            if not isinstance(m, dict):
                continue
            model_id = str(m.get("modelId") or "")
            name = str(m.get("name") or model_id)
            raw_desc = str(m.get("description") or "")
            provider = ""
            desc_bits = []
            for part in raw_desc.split(" • "):
                p = part.strip()
                if not p or p.lower() == "current":
                    continue
                if p.lower().startswith("provider:"):
                    provider = p.split(":", 1)[1].strip()
                else:
                    desc_bits.append(p)
            if not provider and ":" in model_id:
                provider = model_id.split(":", 1)[0]
            out.append({
                "modelId": model_id,
                "name": name,
                "provider": provider,
                "description": " • ".join(desc_bits),
            })
        return out

    def _last_assistant_text(self) -> str:
        with self._lock:
            for m in reversed(self._messages):
                if m["type"] == "assistant":
                    return m.get("content") or ""
        return ""

    # ── ACP callbacks (fire on the AcpClient reader thread) ────
    def _on_acp_update(self, session_id: str, update: dict) -> None:
        if self._acpReplaying or not self._accepting:
            return
        if session_id != self._acpRunSession:
            return
        kind = update.get("sessionUpdate") or ""
        if kind == "agent_thought_chunk":
            self._add_thinking(self._acp_text(update.get("content")), delta=True)
        elif kind == "agent_message_chunk":
            self._append_delta(self._acp_text(update.get("content")))
        elif kind == "tool_call":
            self._acp_tool_call(update)
        elif kind == "tool_call_update":
            self._acp_tool_update(update)
        # usage_update / available_commands_update / plan: no UI yet

    @staticmethod
    def _acp_text(content) -> str:
        """Extract plain text from an ACP ContentBlock (or list of them)."""
        if isinstance(content, list):
            return "".join(HermesBackend._acp_text(c) for c in content)
        if isinstance(content, dict):
            if content.get("type") == "content":
                return HermesBackend._acp_text(content.get("content"))
            return content.get("text") or ""
        return ""

    def _acp_tool_call(self, update: dict) -> None:
        title = update.get("title") or update.get("kind") or "tool"
        # "terminal: echo hi" → chip "terminal", preview "echo hi"
        tool, _, rest = title.partition(": ")
        preview = self._acp_text(update.get("content")) or rest
        args = update.get("rawInput") if isinstance(update.get("rawInput"), dict) else None
        self._add_tool_call(tool or title, preview, "running", args)
        call_id = update.get("toolCallId") or ""
        if call_id:
            with self._lock:
                for m in reversed(self._messages):
                    if m["type"] == "tool_call" and m["toolStatus"] == "running":
                        m["toolCallId"] = call_id
                        break

    def _acp_tool_update(self, update: dict) -> None:
        call_id = update.get("toolCallId") or ""
        status = update.get("status") or ""
        mapped = {"completed": "completed", "failed": "error"}.get(status, "running")
        result_text = self._acp_text(update.get("content"))
        with self._lock:
            for i in range(len(self._messages) - 1, -1, -1):
                m = self._messages[i]
                if m["type"] != "tool_call":
                    continue
                if call_id and m.get("toolCallId") != call_id:
                    continue
                if not call_id and m["toolStatus"] != "running":
                    continue
                props = {}
                if result_text:
                    prior = m.get("toolPreview") or ""
                    m["toolPreview"] = f"{prior}\n{result_text}" if prior else result_text
                    props["toolPreview"] = m["toolPreview"]
                if mapped != "running" and m["toolStatus"] == "running":
                    m["toolStatus"] = mapped
                    m["toolDuration"] = max(0.0, time.time() - (m.get("timestamp") or time.time()))
                    props["toolStatus"] = mapped
                    props["toolDuration"] = m["toolDuration"]
                if props:
                    self._gui(lambda i=i, p=props: self.messageUpdated.emit(i, p))
                return

    def _on_acp_permission(self, request_id, session_id: str, params: dict) -> None:
        if session_id != self._acpRunSession or not self._accepting:
            # Not our run — refuse rather than leaving the agent blocked.
            try:
                self._acp.respond_permission(request_id, None)
            except AcpError:
                pass
            return
        self._pendingPermission = (request_id, params.get("options") or [])
        tool_call = params.get("toolCall") or {}
        desc = tool_call.get("title") or self._acp_text(tool_call.get("content")) \
            or "Approval requested"
        self._add_approval({"command": desc})

    def _resolve_acp_permission(self, choice: str) -> bool:
        """Map the approval card's once/session/deny onto the request's
        options. Returns True when an ACP permission was pending."""
        if self._pendingPermission is None:
            return False
        request_id, options = self._pendingPermission
        self._pendingPermission = None
        wanted = {
            "once": ["allow_once", "allow_always"],
            "session": ["allow_always", "allow_once"],
            "always": ["allow_always", "allow_once"],
            "deny": ["reject_once", "reject_always"],
        }.get(choice, ["reject_once", "reject_always"])
        option_id = None
        for kind in wanted:
            for o in options:
                if o.get("kind") == kind:
                    option_id = o.get("optionId")
                    break
            if option_id:
                break
        if option_id is None and options:
            option_id = options[0].get("optionId")
        try:
            self._acp.respond_permission(request_id, option_id)
        except AcpError as e:
            log.warning("permission response failed: %s", e)
        return True

    def _conversation_history(self) -> list[dict]:
        out = []
        with self._lock:
            snapshot = list(self._messages)
        for m in snapshot:
            if m["type"] in ("user", "assistant") and (m.get("content") or "").strip():
                out.append(
                    {
                        "role": "user" if m["type"] == "user" else "assistant",
                        "content": m["content"],
                    }
                )
        return out

    # ───────────────────────────────────────────────────────────
    #  SSE stream → GET /v1/runs/{id}/events
    # ───────────────────────────────────────────────────────────
    def _stream_events(self, run_id: str) -> None:
        self._accepting = True
        self._sseStop.clear()
        url = f"{self._apiBaseUrl}/v1/runs/{run_id}/events"
        try:
            with self._client.stream(
                "GET", url, headers=self._headers(), timeout=httpx.Timeout(5.0, read=300.0)
            ) as resp:
                if resp.status_code != 200:
                    body = resp.text[:500]
                    log.error("SSE endpoint returned %s: %s", resp.status_code, body)
                    self._gui(lambda: self._fail_pending(f"SSE endpoint returned {resp.status_code}"))
                    return
                current_event = ""  # Track SSE event name across lines
                for line in resp.iter_lines():
                    if self._sseStop.is_set() or run_id != self._currentRunId:
                        return
                    current_event = self._handle_sse_line(line, current_event)
        except httpx.ReadTimeout:
            log.warning("SSE read timeout for run %s", run_id)
        except Exception as exc:
            log.exception("SSE stream error for run %s", run_id)
        finally:
            # Stream ended without an explicit terminal event — seal the bubble.
            if run_id == self._currentRunId and run_id:
                self._gui(lambda: self._set_running(False))
                self._gui(lambda: self._seal_streaming())

    def _handle_sse_line(self, line: str, current_event: str) -> str:
        """Parse one SSE line.  Returns the current event name (stateful).

        The Hermes /v1/runs endpoint sends ``data: {json}\\n\\n`` frames
        where the JSON payload itself contains an ``"event"`` key.
        The /api/chat/stream endpoint uses named ``event:`` lines instead.
        We handle both formats.
        """
        if not self._accepting:
            return current_event
        line = (line or "").strip()
        if not line or line.startswith(":"):
            return current_event
        # Named-event line: "event: <name>"
        if line.startswith("event: "):
            return line[7:].strip()
        # Data line: "data: <json>"
        if line.startswith("data: "):
            try:
                payload = json.loads(line[6:])
            except ValueError:
                log.warning("SSE: invalid JSON in data line: %s", line[:120])
                return current_event
            # Resolve event name: prefer named SSE event, fall back to
            # the "event" key embedded in the JSON payload.
            event_name = current_event or payload.get("event", "")
            if event_name:
                self._handle_event(event_name, payload)
            else:
                log.warning("SSE: data line with no event name: %s", line[:120])
            return ""  # Reset — each data frame is self-contained
        return current_event

    def _handle_event(self, event_name: str, data: dict) -> None:
        # ── Streaming text ──────────────────────────────────────
        # /v1/runs sends "message.delta" with {"delta": "..."}
        # /api/chat/stream sends "assistant.delta" with {"delta": "..."}
        if event_name in ("message.delta", "assistant.delta"):
            self._append_delta(data.get("delta") or "")

        # ── Reasoning / thinking ────────────────────────────────
        # /v1/runs sends "reasoning.available" with {"text": "..."}
        # /api/chat/stream sends "reasoning" with {"text": "..."} (the
        # webui's put('reasoning', ...) path) or "tool.progress" with
        # {"tool_name": "_thinking", "delta": "..."}
        elif event_name == "reasoning.available":
            self._add_thinking(data.get("text") or "")
        elif event_name == "reasoning":
            self._add_thinking(data.get("text") or data.get("delta") or "", delta=True)
        elif event_name == "tool.progress" and data.get("tool_name") == "_thinking":
            self._add_thinking(data.get("delta") or "", delta=True)

        # ── Non-thinking tool progress (live output) ───────────────
        # Some gateways send tool.progress for running tools with partial
        # output (e.g. terminal commands). Append the delta to the most
        # recent running tool_call's preview so the QML can show it live.
        elif event_name == "tool.progress":
            tool_name = data.get("tool") or data.get("tool_name") or ""
            if tool_name and tool_name != "_thinking":
                delta_text = data.get("delta") or data.get("preview") or ""
                if delta_text:
                    with self._lock:
                        for m in reversed(self._messages):
                            if m["type"] == "tool_call" and m["tool"] == tool_name and m.get("toolStatus") == "running":
                                # Append live output to toolPreview
                                m["toolPreview"] = (m.get("toolPreview") or "") + delta_text
                                preview = m["toolPreview"]
                                idx = self._messages.index(m)
                                self._gui(lambda i=idx, p=preview: self.messageUpdated.emit(i, {"toolPreview": p}))
                                break

        # ── Tool calls ──────────────────────────────────────────
        elif event_name == "tool.started":
            self._add_tool_call(
                data.get("tool") or data.get("tool_name") or "tool",
                data.get("preview") or "",
                "running",
                data.get("args") if isinstance(data.get("args"), dict) else None,
            )
        elif event_name == "tool.completed":
            self._complete_tool_call(
                data.get("tool") or data.get("tool_name") or "",
                data.get("duration") or 0,
                bool(data.get("error") or data.get("is_error")),
            )
        elif event_name == "tool.failed":
            self._complete_tool_call(
                data.get("tool") or data.get("tool_name") or "",
                data.get("duration") or 0,
                True,
            )

        # ── Approval ────────────────────────────────────────────
        elif event_name == "approval.request":
            self._add_approval(data)

        # ── Run lifecycle ───────────────────────────────────────
        elif event_name == "run.completed":
            self._finalize_run(data)
        elif event_name in ("run.failed", "error"):
            self._fail_run(data.get("error") or data.get("message") or "Run failed")
        elif event_name == "run.cancelled":
            self._cancel_run()

        # ── Terminal / informational (no UI action needed) ──────
        elif event_name in ("done", "stream_end", "run.started",
                            "message.started", "assistant.completed"):
            pass

        else:
            log.debug("SSE: unhandled event %s", event_name)

    # ── Event handlers (mutate self._messages, emit row ops) ───
    def _append_delta(self, delta: str) -> None:
        if not delta:
            return
        with self._lock:
            if self._messages:
                idx = len(self._messages) - 1
                last = self._messages[idx]
                if last["type"] == "assistant" and last.get("isStreaming"):
                    if not last["content"]:
                        delta = delta.lstrip("\n")
                    last["content"] += delta
                    content = last["content"]  # snapshot for closure
                    self._gui(lambda i=idx, c=content: self.messageUpdated.emit(i, {"content": c}))
                    return
            for i in range(len(self._messages) - 1, -1, -1):
                if self._messages[i].get("isStreaming"):
                    m = self._messages[i]
                    m["isStreaming"] = False
                    props = {"isStreaming": False}
                    # An empty placeholder superseded by a later bubble would
                    # render nothing but its timestamp line — hide it.
                    if m["type"] == "assistant" and not m.get("content"):
                        m["timestamp"] = 0
                        props["timestamp"] = 0
                    self._gui(lambda i=i, p=props: self.messageUpdated.emit(i, p))
        self._append(
            db._row(
                "assistant",
                content=delta.lstrip("\n"),
                isStreaming=True,
                timestamp=time.time(),
                startedAt=time.time(),
                usage={},
                duration=0,
            )
        )

    def _add_thinking(self, text: str, delta: bool = False) -> None:
        if not text:
            return
        # Deduplicate reasoning echoes for the /v1/runs path where
        # "reasoning.available" can carry text already shown as content.
        # The /api/chat/stream "reasoning" event is already deduped by
        # the server's _is_visible_output_echo(), so skip the check for
        # delta-style events (which come from the "reasoning" SSE path).
        if not delta:
            norm = " ".join(text.split())
            if norm:
                with self._lock:
                    for m in reversed(self._messages):
                        if m["type"] == "assistant" and m.get("content"):
                            c = " ".join(m["content"].split())
                            if c == norm or c.startswith(norm) or norm.startswith(c):
                                return
                            break
        # Accumulate a contiguous reasoning stream into one row (one card),
        # the same way the webui grows a single live thinking card. A new row
        # starts only after something else (content, a tool call) interleaves.
        # reasoning.available carries discrete paragraphs (join with a blank
        # line); the _thinking tool.progress path streams raw deltas.
        with self._lock:
            if self._messages and self._messages[-1]["type"] == "thinking":
                idx = len(self._messages) - 1
                m = self._messages[idx]
                sep = "" if delta or not m["content"] else "\n\n"
                m["content"] += sep + text
                content = m["content"]
                self._gui(lambda i=idx, c=content: self.messageUpdated.emit(i, {"content": c}))
                return
        self._append(db._row("thinking", content=text, timestamp=time.time()))

    def _add_tool_call(self, tool: str, preview: str, status: str, args: dict | None = None) -> None:
        args_json = ""
        if args and isinstance(args, dict):
            try:
                args_json = json.dumps(args, ensure_ascii=False)
            except (TypeError, ValueError):
                args_json = str(args)
        self._append(
            db._row("tool_call", tool=tool, toolPreview=preview, toolArgs=args_json, toolStatus=status, timestamp=time.time())
        )

    def _complete_tool_call(self, tool: str, duration, error: bool) -> None:
        with self._lock:
            for i in range(len(self._messages) - 1, -1, -1):
                m = self._messages[i]
                if m["type"] == "tool_call" and m["tool"] == tool and m["toolStatus"] == "running":
                    m["toolStatus"] = "error" if error else "completed"
                    m["toolDuration"] = duration
                    status = m["toolStatus"]
                    self._gui(lambda i=i, s=status, d=duration: self.messageUpdated.emit(i, {"toolStatus": s, "toolDuration": d}))
                    return

    def _add_approval(self, event: dict) -> None:
        self._append(
            db._row(
                "approval",
                content=event.get("command") or event.get("message") or "Approval requested",
                timestamp=time.time(),
            )
        )

    def _finalize_run(self, event: dict) -> None:
        end = time.time()
        with self._lock:
            for i in range(len(self._messages) - 1, -1, -1):
                m = self._messages[i]
                if m.get("isStreaming"):
                    m["isStreaming"] = False
                    props = {"isStreaming": False, "duration": end - m.get("startedAt", end)}
                    if event.get("usage"):
                        m["usage"] = event["usage"]
                        props["usage"] = event["usage"]
                    self._gui(lambda i=i, p=props: self.messageUpdated.emit(i, p))
                    break
        if event.get("usage"):
            self._set_last_usage(event["usage"])
        if not self._currentSessionId and self._currentRunId:
            self._fetch_run_session_id(self._currentRunId)
        self._set_running(False)
        self._gui(lambda o=event.get("output") or "": self.runCompleted.emit(o))
        self.loadSessions()

    def _fail_run(self, error: str) -> None:
        self._seal_streaming(content="Error: " + error)
        self._set_running(False)
        self._set_last_error(error)
        self._gui(lambda e=error: self.runFailed.emit(e))

    def _cancel_run(self) -> None:
        self._seal_streaming()
        self._set_running(False)

    def _seal_streaming(self, content: str | None = None) -> None:
        with self._lock:
            for i in range(len(self._messages) - 1, -1, -1):
                if self._messages[i].get("isStreaming"):
                    self._messages[i]["isStreaming"] = False
                    props = {"isStreaming": False}
                    if content is not None:
                        self._messages[i]["content"] = content
                        props["content"] = content
                    self._gui(lambda i=i, p=props: self.messageUpdated.emit(i, p))
                    break

    def _fail_pending(self, msg: str) -> None:
        with self._lock:
            sealed = False
            for i in range(len(self._messages) - 1, -1, -1):
                m = self._messages[i]
                if m["type"] == "assistant" and m.get("isStreaming"):
                    m["content"] = "Error: " + msg
                    m["isStreaming"] = False
                    c = m["content"]
                    self._gui(lambda i=i, c=c: self.messageUpdated.emit(i, {"content": c, "isStreaming": False}))
                    sealed = True
                    break
        if not sealed:
            self._append(db._row("assistant", content="Error: " + msg, timestamp=time.time()))
        self._set_running(False)
        self._set_last_error(msg)
        self._gui(lambda m=msg: self.runFailed.emit(m))

    # ── Run session-id fetch ───────────────────────────────────
    def _fetch_run_session_id(self, run_id: str) -> None:
        def work():
            try:
                r = self._client.get(
                    f"{self._apiBaseUrl}/v1/runs/{run_id}", headers=self._headers(), timeout=5.0
                )
                sid = r.json().get("session_id")
                if sid and not self._currentSessionId:
                    self._set_current_session(sid)
            except Exception:
                pass

        self._spawn(work)

    # ───────────────────────────────────────────────────────────
    #  Stop / approval
    # ───────────────────────────────────────────────────────────
    @Slot()
    def stopRun(self) -> None:
        # ACP run: unblock any pending permission, cancel the session. The
        # blocked prompt() then returns stopReason=cancelled; we seal now so
        # the UI reacts immediately.
        if self._acpRunSession:
            self._accepting = False
            if self._pendingPermission is not None:
                request_id, _ = self._pendingPermission
                self._pendingPermission = None
                self._spawn(lambda: self._acp_quiet(
                    lambda: self._acp.respond_permission(request_id, None)))
            sid = self._acpRunSession
            self._spawn(lambda: self._acp_quiet(lambda: self._acp.cancel(sid)))
            self._cancel_run()
            return
        if not self._currentRunId:
            return
        run_id = self._currentRunId
        self._sseStop.set()
        self._set_running(False)
        self._cancel_run()
        self._spawn(
            lambda: self._post_quiet(f"{self._apiBaseUrl}/v1/runs/{run_id}/stop")
        )

    @Slot(str)
    def resolveApproval(self, choice: str) -> None:
        if self._pendingPermission is not None:
            choice_ = choice
            self._spawn(lambda: self._resolve_acp_permission(choice_))
            return
        if not self._currentRunId:
            return
        run_id = self._currentRunId
        self._spawn(
            lambda: self._post_quiet(
                f"{self._apiBaseUrl}/v1/runs/{run_id}/approval",
                json_body={"choice": choice},
            )
        )

    def _post_quiet(self, url: str, json_body: dict | None = None) -> None:
        try:
            self._client.post(
                url,
                headers=self._headers(json_body=json_body is not None),
                json=json_body,
                timeout=5.0,
            )
        except Exception:
            pass

    @staticmethod
    def _acp_quiet(fn) -> None:
        try:
            fn()
        except (AcpError, OSError):
            pass

    def _detach_run(self) -> None:
        """Stop listening to the current run without cancelling it server-side."""
        self._accepting = False
        self._sseStop.set()
        # A permission request left unanswered would block the detached agent
        # forever — refuse it so the background run can finish and persist.
        if self._pendingPermission is not None:
            request_id, _ = self._pendingPermission
            self._pendingPermission = None
            self._spawn(lambda: self._acp_quiet(
                lambda: self._acp.respond_permission(request_id, None)))
        self._acpRunSession = ""
        self._set_running(False)
        self._set_current_run("")

    # ───────────────────────────────────────────────────────────
    #  Settings update (from the SettingsPanel)
    # ───────────────────────────────────────────────────────────
    @Slot(str, str, str, str)
    def updateSettings(self, api_base_url: str, api_key: str, hermes_home: str, model: str) -> None:
        self._apiBaseUrl = api_base_url
        self._apiKey = api_key
        self._hermesHome = hermes_home
        self._selectedModel = model
        self._envApiKey = ""
        self._discover_env_key()
        self._save_settings()
        self.configChanged.emit()
        self.checkHealth()
        self.loadSessions()
        self.loadWelcomeInfo()
    # ───────────────────────────────────────────────────────────
    #  Model selection
    # ───────────────────────────────────────────────────────────
    @Slot(str)
    def selectModel(self, model_id: str) -> None:
        """Choose a model from the UI picker.

        Updates the persisted setting and, if a session is active, asks the
        ACP adapter to switch to it immediately. model_id is the full
        provider:model string from availableModels."""
        if not model_id:
            return
        self._selectedModel = model_id
        self._save_settings()
        self.configChanged.emit()
        self._set_current_model(model_id.split(":")[-1])

        sid = self._currentSessionId
        if sid and self._acp and self._acp.is_alive():
            def work():
                try:
                    self._acp.set_model(sid, model_id)
                except AcpError as e:
                    log.warning("session/set_model failed: %s", e)
            self._spawn(work)

    @Slot()
    def refreshModels(self) -> None:
        """Populate availableModels before the first run if needed.

        Creates a fresh ACP session when none exists; otherwise the list from
        the existing session is already reflected in availableModels."""
        if self._availableModels:
            return
        if self._modelsLoading:
            return
        self._set_models_loading(True)

        def work():
            try:
                client = self._ensure_acp()
                if self._currentSessionId:
                    # Already have a session; models were fetched when it was
                    # created and are stored in availableModels.
                    return
                res = client.new_session()
                sid = res.get("sessionId") or ""
                if sid:
                    self._set_current_session(sid)
                    self._acpLoadedSessions.add(sid)
                    self._apply_acp_models(client, sid, res.get("models") or {})
            except Exception:
                log.exception("refreshModels failed")
            finally:
                self._set_models_loading(False)

        self._spawn(work)

    # ───────────────────────────────────────────────────────────
    #  Append helper
    # ───────────────────────────────────────────────────────────
    def _append(self, row: dict) -> None:
        with self._lock:
            self._messages.append(row)
        self._gui(lambda r=row: self.messageAppended.emit(r))

    # ───────────────────────────────────────────────────────────
    #  Property setters (all go through _gui so daemon threads
    #  never emit directly into the QML event loop)
    # ───────────────────────────────────────────────────────────
    def _set_connected(self, v: bool):
        if v != self._connected:
            self._connected = v
            self._gui(self.connectedChanged.emit)

    def _set_current_session(self, v: str):
        if v != self._currentSessionId:
            self._currentSessionId = v
            self._gui(self.currentSessionIdChanged.emit)

    def _set_current_model(self, v: str):
        if v != self._currentModel:
            self._currentModel = v
            self._gui(self.currentModelChanged.emit)

    def _set_models(self, v: list):
        if v != self._availableModels:
            self._availableModels = v
            self._gui(self.availableModelsChanged.emit)

    def _set_models_loading(self, v: bool):
        if v != self._modelsLoading:
            self._modelsLoading = v
            self._gui(self.modelsLoadingChanged.emit)

    def _set_running(self, v: bool):
        if v != self._isRunning:
            self._isRunning = v
            self._gui(self.isRunningChanged.emit)

    def _set_current_run(self, v: str):
        if v != self._currentRunId:
            self._currentRunId = v
            self._gui(self.currentRunIdChanged.emit)

    def _set_last_usage(self, v: dict):
        self._lastUsage = v
        self._gui(self.lastUsageChanged.emit)

    def _set_last_error(self, v: str):
        self._lastError = v
        self._gui(self.lastErrorChanged.emit)

    def _set_welcome(self, v: dict):
        self._welcomeInfo = v
        self._gui(self.welcomeInfoChanged.emit)

    # ───────────────────────────────────────────────────────────
    #  Qt Properties
    # ───────────────────────────────────────────────────────────
    apiBaseUrl = Property(str, lambda s: s._apiBaseUrl, notify=configChanged)
    apiKey = Property(str, lambda s: s._apiKey, notify=configChanged)
    hermesHome = Property(str, lambda s: s._hermesHome, notify=configChanged)
    selectedModel = Property(str, lambda s: s._selectedModel, notify=configChanged)

    connected = Property(bool, lambda s: s._connected, notify=connectedChanged)
    currentSessionId = Property(str, lambda s: s._currentSessionId, notify=currentSessionIdChanged)
    currentModel = Property(str, lambda s: s._currentModel, notify=currentModelChanged)
    availableModels = Property("QVariant", lambda s: s._availableModels, notify=availableModelsChanged)
    modelsLoading = Property(bool, lambda s: s._modelsLoading, notify=modelsLoadingChanged)
    isRunning = Property(bool, lambda s: s._isRunning, notify=isRunningChanged)
    currentRunId = Property(str, lambda s: s._currentRunId, notify=currentRunIdChanged)
    lastUsage = Property("QVariant", lambda s: s._lastUsage, notify=lastUsageChanged)
    lastError = Property(str, lambda s: s._lastError, notify=lastErrorChanged)
    welcomeInfo = Property("QVariant", lambda s: s._welcomeInfo, notify=welcomeInfoChanged)
