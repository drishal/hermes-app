#!/usr/bin/env python3
"""Render every chat delegate type and assert no QML warnings + no row overlap.

The smoke test only proves Window.qml *loads*; it never populates messageList,
so delegate-only runtime errors (and the recurring row-overlap layout bug)
slip through. This drives a real QQuickWindow with one row of each `type`,
lets layout settle, then walks the ListView's `msgRow` delegates and asserts
each sits below the previous one (no overlap) and nothing logged a warning.

Run:  QT_QPA_PLATFORM=offscreen python3 tests/chat_delegates_test.py
"""
from __future__ import annotations

import os
import sys
import time

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

APP_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, APP_DIR)

from PySide6.QtCore import QTimer, QUrl  # noqa: E402
from PySide6.QtQml import QQmlApplicationEngine  # noqa: E402
from PySide6.QtWidgets import QApplication  # noqa: E402
from PySide6.QtQuick import QQuickItem, QQuickWindow  # noqa: E402
import shiboken6  # noqa: E402

from backend.hermes_backend import HermesBackend  # noqa: E402
from backend.platform_bridge import Platform  # noqa: E402
from backend import db  # noqa: E402


def _rows() -> list[dict]:
    now = time.time()
    return [
        db._row("user", content="List the files at ~/Desktop", timestamp=now),
        db._row("thinking", content="Let me run ls.\nThen summarise.", timestamp=now),
        db._row("tool_call", tool="terminal", toolPreview="$ ls ~/Desktop\na\nb",
                toolStatus="completed", toolDuration=0.3, expanded=True, timestamp=now),
        db._row("tool_result", tool="read_file",
                content='<untrusted_tool_result source="read_file">\n'
                        '{"path": "~/x.txt", "content": "hello", "total_lines": 1}\n'
                        '</untrusted_tool_result>',
                expanded=True, toolStatus="completed", timestamp=now),
        db._row("approval", content="terminal: rm -rf /tmp/x", timestamp=now),
        db._row("assistant",
                content="Here are the files:\n\n- **a**\n- b\n\n```bash\nls ~/Desktop\n```",
                usage={"input_tokens": 10, "output_tokens": 5, "total_tokens": 15},
                duration=1.2, timestamp=now),
    ]


def main() -> int:
    app = QApplication(sys.argv)
    warnings: list[str] = []
    engine = QQmlApplicationEngine()
    engine.addImportPath(APP_DIR)
    engine.warnings.connect(lambda errs: warnings.extend(e.toString() for e in errs))

    backend = HermesBackend()
    platform = Platform()  # keep a ref — a GC'd context property reads as null
    ctx = engine.rootContext()
    ctx.setContextProperty("stylixColors", None)
    ctx.setContextProperty("hermesBackend", backend)
    ctx.setContextProperty("Platform", platform)
    engine.load(QUrl.fromLocalFile(os.path.join(APP_DIR, "qml", "Window.qml")))

    roots = engine.rootObjects()
    if not roots:
        print("FAIL: no root object", file=sys.stderr)
        return 1
    root = roots[0]
    root.setWidth(1100)
    root.setHeight(900)

    QTimer.singleShot(400, lambda: backend.messagesReset.emit(_rows()))

    result: dict = {}

    def check():
        # Offscreen, the ListView only instantiates delegates once the window
        # actually renders — force a frame (grab result discarded).
        win = shiboken6.wrapInstance(shiboken6.getCppPointer(root)[0], QQuickWindow)
        win.grabWindow()
        # Delegates are *visual* children of the ListView's contentItem (managed
        # by the view), not QObject children — findChildren won't reach them.
        rows = []
        for lv in root.findChildren(QQuickItem):
            if "ListView" not in lv.metaObject().className():
                continue
            ci = lv.property("contentItem")
            if not ci:
                continue
            found = [ch for ch in ci.childItems() if ch.objectName() == "msgRow"]
            if found:
                rows = found
                break
        rows = [r for r in rows if r.height() > 0]
        rows.sort(key=lambda r: r.y())
        overlaps = []
        for i in range(1, len(rows)):
            prev, cur = rows[i - 1], rows[i]
            if cur.y() < prev.y() + prev.height() - 1:
                overlaps.append((i, round(prev.y(), 1), round(prev.height(), 1), round(cur.y(), 1)))
        result["count"] = len(rows)
        result["overlaps"] = overlaps
        app.quit()

    QTimer.singleShot(1600, check)
    app.exec()

    ok = True
    for w in warnings:
        print("QML WARNING:", w, file=sys.stderr)
        ok = False
    n = result.get("count", 0)
    if n < 6:
        print(f"FAIL: expected 6 delegates, saw {n}", file=sys.stderr)
        ok = False
    for ov in result.get("overlaps", []):
        print(f"FAIL: row {ov[0]} overlaps (prev y={ov[1]} h={ov[2]} -> cur y={ov[3]})",
              file=sys.stderr)
        ok = False

    print("chat_delegates_test:", "OK" if ok else "FAIL", f"({n} rows)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
