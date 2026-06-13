import QtQuick
import qs.Common
import qs.Widgets
import "../services/toolFormat.js" as Tf

// Tool-call activity card (msg.type === "tool_call"), Claude-style: icon · tool
// name · status, click to expand the arguments/command via ToolContentView.
// Auto-expands while running; explicit height (no positioner) per the delegate
// Loader layout gotchas in CLAUDE.md.
//
// Extracted from ChatArea's inline delegate; the Loader wrapper passes `msg`,
// `rowIndex` and `hermesService`.
Item {
    id: tcc
    width: parent.width

    property var msg: null
    property int rowIndex: -1
    property var hermesService: null

    readonly property string toolName: msg ? (msg.tool || "") : ""
    readonly property string toolPreview: msg ? (msg.toolPreview || "") : ""
    readonly property string toolArgs: msg ? (msg.toolArgs || "") : ""
    readonly property string toolStatus: msg ? (msg.toolStatus || "") : ""
    readonly property real toolDuration: msg ? (msg.toolDuration || 0) : 0
    readonly property bool isExpanded: msg ? !!msg.expanded : false
    // Auto-expand while the tool is running so the user can see what's
    // executing (matches how the thinking card auto-opens during live
    // reasoning). Falls back to the user's explicit toggle once completed.
    readonly property bool isLive: toolStatus === "running"
    readonly property bool showBody: isExpanded || isLive
    readonly property string previewLine: toolPreview.replace(/\s+/g, " ").trim()
    readonly property string toolLabel: Tf.labelFor(toolName)
    height: card.height + 2

    function toggleExpanded() {
        const ml = hermesService.messageList
        if (rowIndex >= 0 && rowIndex < ml.count)
            ml.setProperty(rowIndex, "expanded", !isExpanded)
    }

    Rectangle {
        id: card
        anchors.left: parent.left
        anchors.right: parent.right
        // Explicit height: a positioner's implicitHeight doesn't settle
        // inside the delegate Loader chain (sticks at 0 — collapsed
        // cards, overlapping rows), so don't lean on a Column here.
        height: 30 + (tcc.showBody ? argsBox.height : 0)
        radius: Math.max(6, Theme.cornerRadius / 2)
        color: Theme.surfaceContainer
        border.width: 1
        border.color: headerMouse.containsMouse ? Theme.outlineMedium : Theme.outlineVariant
        Behavior on border.color { ColorAnimation { duration: 120 } }

        Item {
            id: callHeader
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 30

            DankIcon {
                id: toolIcon
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.spacingS
                    anchors.verticalCenter: parent.verticalCenter
                    name: Tf.iconFor(tcc.toolName)
                    size: 14
                    color: tcc.toolStatus === "error" ? Theme.error : Theme.surfaceTextMedium
                }

                StyledText {
                    id: toolNameText
                    anchors.left: toolIcon.right
                    anchors.leftMargin: Theme.spacingXS
                    anchors.verticalCenter: parent.verticalCenter
                    text: tcc.toolLabel
                    color: Theme.surfaceText
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Medium
                }

                // Far right: expand chevron when there's anything to show.
            DankIcon {
                id: chevron
                visible: tcc.previewLine.length > 0 || tcc.toolArgs.length > 0
                anchors.right: parent.right
                anchors.rightMargin: Theme.spacingS
                anchors.verticalCenter: parent.verticalCenter
                name: tcc.showBody ? "expand_less" : "expand_more"
                size: 14
                color: Theme.surfaceTextMedium
            }

                // Status: spinner while running, then duration / failed.
                // Hidden once completed so the result card carries the
                // success affordance — matches Claude web.
                DankIcon {
                    id: statusIcon
                    anchors.right: chevron.visible ? chevron.left : parent.right
                    anchors.rightMargin: Theme.spacingXS
                    anchors.verticalCenter: parent.verticalCenter
                    visible: tcc.toolStatus === "running" || tcc.toolStatus === "error"
                    name: tcc.toolStatus === "running" ? "progress_activity"
                        : "error_outline"
                    size: 13
                    color: tcc.toolStatus === "error" ? Theme.error
                         : Theme.tertiary

                    RotationAnimation on rotation {
                        running: tcc.toolStatus === "running"
                        loops: Animation.Infinite
                        from: 0; to: 360
                        duration: 900
                    }
                    Connections {
                        target: tcc
                        function onToolStatusChanged() {
                            if (tcc.toolStatus !== "running") statusIcon.rotation = 0
                        }
                    }
                }

                StyledText {
                    id: statusText
                    anchors.right: statusIcon.visible ? statusIcon.left
                                  : chevron.visible ? chevron.left : parent.right
                    anchors.rightMargin: Theme.spacingXS
                    anchors.verticalCenter: parent.verticalCenter
                    visible: tcc.toolStatus === "running" || tcc.toolStatus === "error"
                    text: tcc.toolStatus === "running" ? "running…"
                         : tcc.toolStatus === "error"  ? "failed"
                         : ""
                    color: tcc.toolStatus === "error" ? Theme.error : Theme.surfaceTextMedium
                    font.pixelSize: Theme.fontSizeSmall - 1
                    font.italic: tcc.toolStatus === "running"
                }

                // Preview hidden when collapsed — matches Claude web UI
                // where collapsed cards show only icon + label + chevron.

                MouseArea {
                    id: headerMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: (tcc.previewLine || tcc.toolArgs) ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: tcc.toggleExpanded()
                }
            }

        // Expanded: structured content via ToolContentView
        // (key-value, code, or JsonView fallback).
        Item {
            id: argsBox
            visible: tcc.showBody
            anchors.top: callHeader.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: tcc.showBody ? argsContent.height + Theme.spacingS : 0

            // Prefer structured args JSON over the preview string — the
            // gateway sends a proper args dict for tool.started events
            // which classifyCallContent can render as kv/code blocks.
            readonly property string contentSource: tcc.toolArgs.length > 0 ? tcc.toolArgs : tcc.toolPreview
            readonly property var _classified: Tf.classifyCallContent(tcc.toolName, contentSource)

            ToolContentView {
                id: argsContent
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                content: parent._classified.type !== "json" ? parent._classified : null
                rawText: parent._classified.type === "json" && tcc.showBody
                         ? parent.contentSource : ""
            }
        }
    }
}
