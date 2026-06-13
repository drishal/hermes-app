#!/usr/bin/env python3
"""Regression test for the model picker fix.

Two bugs were fixed:
  1. The model chip's MouseArea in ChatArea.qml had no `anchors.fill: parent`,
     so it was 0x0 and clicks on the chip never registered. The picker
     therefore never opened.
  2. ModelPicker.qml set its own `anchors.bottom: parent.top` and
     `width: Math.min(parent.width, 360)`, overriding the parent-assigned
     anchors in ChatArea.qml and clamping the picker to 360px wide.

This test fails if either bug pattern reappears. Run alongside the smoke test
to verify the fix is in place and the QML still loads.

Run:  QT_QPA_PLATFORM=offscreen python3 tests/picker_test.py
"""
from __future__ import annotations

import os
import re
import sys

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

APP_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, APP_DIR)

CHAT_AREA = os.path.join(APP_DIR, "components", "ChatArea.qml")
MODEL_PICKER = os.path.join(APP_DIR, "components", "ModelPicker.qml")


def _read(path: str) -> str:
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def _block(text: str, anchor: str) -> str:
    """Return the text of the MouseArea/Item/Rectangle block that starts with
    the given anchor line. Finds the matching closing brace by depth-counting."""
    idx = text.find(anchor)
    if idx < 0:
        return ""
    # Walk to the opening brace after the anchor.
    brace = text.find("{", idx)
    if brace < 0:
        return ""
    depth = 0
    i = brace
    while i < len(text):
        ch = text[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[idx:i + 1]
        i += 1
    return ""


def main() -> int:
    failures: list[str] = []

    # ── Bug 1: chip MouseArea must fill its parent ──────────────
    chat = _read(CHAT_AREA)
    chip_mouse_block = _block(chat, "id: modelMouse")
    if not chip_mouse_block:
        failures.append("ChatArea.qml: could not locate MouseArea with id: modelMouse")
    else:
        if "anchors.fill: parent" not in chip_mouse_block:
            failures.append(
                "ChatArea.qml: modelMouse MouseArea is missing `anchors.fill: parent` — "
                "the chip click area is 0x0 and the picker never opens"
            )
        else:
            print("OK: modelMouse MouseArea has anchors.fill: parent")
        if "hoverEnabled: true" not in chip_mouse_block:
            failures.append("ChatArea.qml: modelMouse should have hoverEnabled: true for the chip hover state")
        else:
            print("OK: modelMouse MouseArea has hoverEnabled: true")

    # ── Bug 2: ModelPicker must not override parent's anchors/width ─
    picker = _read(MODEL_PICKER)
    # Old bug pattern: child sets its own anchors against the QML parent.
    if re.search(r"anchors\.horizontalCenter:\s*parent\s*\?\s*parent\.horizontalCenter", picker):
        failures.append(
            "ModelPicker.qml: still sets `anchors.horizontalCenter: parent ? parent.horizontalCenter` — "
            "the parent already positions it, so this fights that positioning"
        )
    if re.search(r"anchors\.bottom:\s*parent\s*\?\s*parent\.top", picker):
        failures.append(
            "ModelPicker.qml: still sets `anchors.bottom: parent ? parent.top` — "
            "this overrides the parent's `anchors.bottom: inputRow.top`"
        )
    if re.search(r"width:\s*parent\s*\?\s*Math\.min\(parent\.width,\s*360\)\s*:\s*360", picker):
        failures.append(
            "ModelPicker.qml: still clamps width to 360 — this overrides the "
            "parent's `width: root.contentWidth` (up to 800)"
        )
    if not failures:
        print("OK: ModelPicker.qml no longer sets conflicting anchors or width")

    # ── Sanity: ModelPicker must still own its content and visibility ─
    if "visible: open" not in picker:
        failures.append("ModelPicker.qml: missing `visible: open` (picker would always render)")
    else:
        print("OK: ModelPicker.qml owns `visible: open`")
    if "signal modelSelected" not in picker:
        failures.append("ModelPicker.qml: missing `signal modelSelected(string modelId)`")
    else:
        print("OK: ModelPicker.qml exposes modelSelected signal")

    # ── Sanity: ChatArea must still wire the picker correctly ────
    if "ModelPicker {" not in chat:
        failures.append("ChatArea.qml: no ModelPicker instance found")
    else:
        print("OK: ChatArea.qml instantiates ModelPicker")
    if "onModelSelected: modelId => {" not in chat:
        failures.append("ChatArea.qml: ModelPicker.onModelSelected handler is missing or changed shape")
    else:
        print("OK: ChatArea.qml wires onModelSelected → hermesService.selectModel")

    # ── QML still loads cleanly ─────────────────────────────────
    from PySide6.QtCore import QTimer, QUrl  # noqa: E402
    from PySide6.QtQml import QQmlApplicationEngine  # noqa: E402
    from PySide6.QtWidgets import QApplication  # noqa: E402
    from backend.hermes_backend import HermesBackend  # noqa: E402
    from backend.platform_bridge import Platform  # noqa: E402

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
    QTimer.singleShot(300, app.quit)
    app.exec()
    if not engine.rootObjects():
        failures.append("Window.qml produced no root object")
    elif warnings:
        for w in warnings:
            failures.append(f"QML warning: {w}")
    else:
        print("OK: Window.qml loads with zero warnings")

    if failures:
        print("\nFAIL:", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        return 1

    print("\nALL CHECKS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
