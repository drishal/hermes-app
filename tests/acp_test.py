"""ACP run-path tests, headless.

Two layers:
  1. AcpClient against a fake hermes-acp subprocess (real pipes, real JSON-RPC
     framing): handshake, session/new, a prompt turn streaming thought /
     message / tool-call updates and a permission request, and pending-request
     failure when the process dies.
  2. HermesBackend's ACP update mapping (_on_acp_update / _on_acp_permission)
     driven directly, with row-op signals collected — no subprocess, no model.

Run:  QT_QPA_PLATFORM=offscreen python3 tests/acp_test.py
"""
from __future__ import annotations

import os
import sys
import tempfile
import textwrap
import threading
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

FAKE_SERVER = textwrap.dedent(
    """
    import json, sys

    def send(obj):
        sys.stdout.write(json.dumps(obj) + "\\n")
        sys.stdout.flush()

    def update(sid, upd):
        send({"jsonrpc": "2.0", "method": "session/update",
              "params": {"sessionId": sid, "update": upd}})

    for line in sys.stdin:
        msg = json.loads(line)
        m, i = msg.get("method"), msg.get("id")
        p = msg.get("params") or {}
        if m == "initialize":
            send({"jsonrpc": "2.0", "id": i, "result": {
                "protocolVersion": 1,
                "agentInfo": {"name": "fake-hermes", "version": "0.0"}}})
        elif m == "session/new":
            send({"jsonrpc": "2.0", "id": i, "result": {
                "sessionId": "sess-1",
                "models": {"currentModelId": "fake:model-x", "availableModels": []}}})
        elif m == "session/prompt":
            sid = p["sessionId"]
            for w in ("pondering", " deeply"):
                update(sid, {"sessionUpdate": "agent_thought_chunk",
                             "content": {"type": "text", "text": w}})
            update(sid, {"sessionUpdate": "tool_call", "toolCallId": "tc-1",
                         "title": "terminal: echo hi", "kind": "execute",
                         "content": [{"type": "content",
                                      "content": {"type": "text", "text": "$ echo hi"}}]})
            # Permission round-trip before the tool "runs"
            send({"jsonrpc": "2.0", "id": 999,
                  "method": "session/request_permission",
                  "params": {"sessionId": sid,
                             "toolCall": {"title": "terminal: echo hi"},
                             "options": [
                                 {"optionId": "opt-once", "kind": "allow_once", "name": "Once"},
                                 {"optionId": "opt-deny", "kind": "reject_once", "name": "Deny"}]}})
            answer = json.loads(sys.stdin.readline())
            chosen = (((answer.get("result") or {}).get("outcome")) or {}).get("optionId")
            update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": "tc-1",
                         "status": "completed",
                         "content": [{"type": "content",
                                      "content": {"type": "text", "text": "hi"}}]})
            for w in ("approved:", chosen or "none"):
                update(sid, {"sessionUpdate": "agent_message_chunk",
                             "content": {"type": "text", "text": w}})
            send({"jsonrpc": "2.0", "id": i, "result": {
                "stopReason": "end_turn",
                "usage": {"inputTokens": 10, "outputTokens": 2, "totalTokens": 12}}})
        elif m == "die":
            sys.exit(0)
    """
)


def make_fake_server() -> str:
    fd, path = tempfile.mkstemp(suffix="_fake_acp.py")
    with os.fdopen(fd, "w") as f:
        f.write(FAKE_SERVER)
    return path


def test_acp_client() -> None:
    from backend.acp_client import AcpClient, AcpError

    server = make_fake_server()
    updates: list[tuple[str, dict]] = []
    permissions: list[tuple] = []
    client = AcpClient(
        command=[sys.executable, server],
        on_update=lambda sid, upd: updates.append((sid, upd)),
        on_permission=lambda rid, sid, params: permissions.append((rid, sid, params)),
    )
    try:
        client.start(timeout=10)
        assert client.is_alive(), "client should be initialized"
        assert client.agent_info.get("name") == "fake-hermes"

        res = client.new_session()
        assert res.get("sessionId") == "sess-1"

        # Answer the permission as soon as it arrives, from another thread.
        def answer():
            deadline = time.time() + 10
            while not permissions and time.time() < deadline:
                time.sleep(0.01)
            assert permissions, "no permission request arrived"
            rid, sid, params = permissions[0]
            opts = params.get("options") or []
            assert opts[0]["kind"] == "allow_once"
            client.respond_permission(rid, opts[0]["optionId"])

        t = threading.Thread(target=answer, daemon=True)
        t.start()
        result = client.prompt("sess-1", "hello")
        t.join(timeout=5)

        assert result.get("stopReason") == "end_turn"
        assert (result.get("usage") or {}).get("totalTokens") == 12
        kinds = [u.get("sessionUpdate") for _, u in updates]
        assert kinds == [
            "agent_thought_chunk", "agent_thought_chunk",
            "tool_call", "tool_call_update",
            "agent_message_chunk", "agent_message_chunk",
        ], kinds
        # The approved optionId made it back through the loop
        texts = [u["content"]["text"] for _, u in updates
                 if u.get("sessionUpdate") == "agent_message_chunk"]
        assert "".join(texts) == "approved:opt-once", texts

        # Dead process must unblock pending requests with an error.
        client._proc.terminate()
        try:
            client.new_session(timeout=5)
            raise AssertionError("request against dead process should fail")
        except AcpError:
            pass
        assert not client.is_alive()
    finally:
        client.shutdown()
        os.unlink(server)
    print("acp_client: OK")


def test_backend_mapping() -> None:
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    from PySide6.QtCore import QCoreApplication

    app = QCoreApplication.instance() or QCoreApplication(sys.argv)
    from backend.hermes_backend import HermesBackend

    b = HermesBackend()
    appended: list[dict] = []
    updated: list[tuple[int, dict]] = []
    b.messageAppended.connect(lambda r: appended.append(dict(r)))
    b.messageUpdated.connect(lambda i, p: updated.append((i, dict(p))))

    b._acpRunSession = "sess-1"
    b._accepting = True

    def upd(update_kind, **kw):
        b._on_acp_update("sess-1", {"sessionUpdate": update_kind, **kw})
        b._drain_gui_queue()

    txt = lambda s: {"type": "text", "text": s}

    upd("agent_thought_chunk", content=txt("let me "))
    upd("agent_thought_chunk", content=txt("think"))
    assert [m["type"] for m in appended] == ["thinking"]
    assert b._messages[-1]["content"] == "let me think"

    upd("tool_call", toolCallId="tc-9", title="terminal: ls /tmp", kind="execute",
        content=[{"type": "content", "content": txt("$ ls /tmp")}])
    assert appended[-1]["type"] == "tool_call"
    assert appended[-1]["tool"] == "terminal"
    assert b._messages[-1]["toolCallId"] == "tc-9"
    assert b._messages[-1]["toolStatus"] == "running"

    upd("tool_call_update", toolCallId="tc-9", status="completed",
        content=[{"type": "content", "content": txt("file.txt")}])
    assert b._messages[-1]["toolStatus"] == "completed"
    # Result appends below the command preview rather than replacing it
    assert b._messages[-1]["toolPreview"] == "$ ls /tmp\nfile.txt"
    assert any("toolStatus" in p for _, p in updated)

    upd("agent_message_chunk", content=txt("Hello"))
    upd("agent_message_chunk", content=txt(" world"))
    assert b._messages[-1]["type"] == "assistant"
    assert b._messages[-1]["content"] == "Hello world"
    assert b._messages[-1]["isStreaming"] is True

    # Updates for foreign sessions / after detach are ignored
    before = len(b._messages)
    b._on_acp_update("other-session", {"sessionUpdate": "agent_message_chunk",
                                       "content": txt("nope")})
    b._accepting = False
    b._on_acp_update("sess-1", {"sessionUpdate": "agent_message_chunk",
                                "content": txt("nope")})
    assert len(b._messages) == before
    assert b._messages[-1]["content"] == "Hello world"

    # Permission request → approval row + pending state
    b._accepting = True
    sent = []
    b._acp = type("FakeAcp", (), {
        "respond_permission": lambda self, rid, opt: sent.append((rid, opt)),
    })()
    b._on_acp_permission(7, "sess-1", {
        "toolCall": {"title": "terminal: rm -rf /tmp/x"},
        "options": [{"optionId": "a1", "kind": "allow_once", "name": "Once"},
                    {"optionId": "r1", "kind": "reject_once", "name": "Deny"}],
    })
    b._drain_gui_queue()
    assert appended[-1]["type"] == "approval"
    assert "rm -rf" in appended[-1]["content"]
    assert b._resolve_acp_permission("deny") is True
    assert sent == [(7, "r1")]
    assert b._pendingPermission is None

    print("backend_mapping: OK")


if __name__ == "__main__":
    test_acp_client()
    test_backend_mapping()
    print("acp_test: OK")
