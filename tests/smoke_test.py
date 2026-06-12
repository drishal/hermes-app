#!/usr/bin/env python3
"""Offscreen smoke test: load the full QML tree headless and fail on any error.

Run with Qt's offscreen platform so it needs no display:

    QT_QPA_PLATFORM=offscreen python3 tests/smoke_test.py

It instantiates the real backend + platform bridge, sets the same context
properties main.py does, loads qml/Window.qml, and asserts the root object
built with zero QML warnings. Exit code 0 = pass, non-zero = fail.
"""
from __future__ import annotations

import os
import sys

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

APP_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, APP_DIR)

from PySide6.QtCore import QTimer, QUrl  # noqa: E402
from PySide6.QtQml import QQmlApplicationEngine  # noqa: E402
from PySide6.QtWidgets import QApplication  # noqa: E402

from backend.hermes_backend import HermesBackend  # noqa: E402
from backend.platform_bridge import Platform  # noqa: E402


def main() -> int:
    app = QApplication(sys.argv)

    warnings: list[str] = []
    engine = QQmlApplicationEngine()
    engine.addImportPath(APP_DIR)
    engine.warnings.connect(
        lambda errs: warnings.extend(e.toString() for e in errs)
    )

    ctx = engine.rootContext()
    ctx.setContextProperty("stylixColors", None)
    ctx.setContextProperty("hermesBackend", HermesBackend())
    ctx.setContextProperty("Platform", Platform())

    engine.load(QUrl.fromLocalFile(os.path.join(APP_DIR, "qml", "Window.qml")))

    # Let bindings + delegate creation settle, then quit.
    QTimer.singleShot(500, app.quit)
    app.exec()

    roots = engine.rootObjects()
    ok = bool(roots) and not warnings

    if not roots:
        print("FAIL: Window.qml produced no root object", file=sys.stderr)
    for w in warnings:
        print("QML WARNING:", w, file=sys.stderr)
    print("smoke_test:", "OK" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
