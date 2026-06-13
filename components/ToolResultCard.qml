import QtQuick
import qs.Common
import qs.Widgets
import "../services/toolFormat.js" as Tf

// Tool-result card (msg.type === "tool_result"), Claude-web-style: header shows
// icon · friendly label · chevron with a right-side count ("9 results", "12
// lines", …). For web-search-shaped payloads the body is a tidy results list;
// anything else goes through ToolContentView (structured / JsonView tree). A
// "Done" pill closes expanded web cards.
//
// Extracted from ChatArea's inline delegate; the Loader wrapper passes `msg`,
// `rowIndex` and `hermesService`.
Item {
    id: trc
    width: parent.width

    property var msg: null
    property int rowIndex: -1
    property var hermesService: null

    readonly property string toolName: msg ? (msg.tool || "") : ""
    readonly property string contentText: msg ? (msg.content || "") : ""
    readonly property bool isExpanded: msg ? !!msg.expanded : false
    readonly property var _summary: Tf.summarizeResult(toolName, contentText)
    readonly property bool success: !_summary || _summary.success !== false
    readonly property string toolLabel: Tf.labelFor(toolName)
    readonly property var _webResults: Tf.isWebResults(toolName, contentText)
                              ? Tf.parseWebResults(contentText) : []
    readonly property bool hasWebResults: _webResults && _webResults.length > 0
    // Explicit card height: header (30) + body (when expanded) +
    // Done pill footer (only when expanded and we have results).
    height: card.height + 2

    Rectangle {
        id: card
        anchors.left: parent.left
        anchors.right: parent.right
        // Explicit height — see the tool-call card for why no Column.
        height: 30
            + (trc.isExpanded
                ? resBodyContainer.height
                  + (trc.hasWebResults ? 36 + Theme.spacingS : 0)
                : 0)
        radius: Math.max(6, Theme.cornerRadius / 2)
        color: Theme.surfaceContainer
        border.width: 1
        border.color: trcHeaderMouse.containsMouse ? Theme.outlineMedium : Theme.outlineVariant
        Behavior on border.color { ColorAnimation { duration: 120 } }

        Item {
            id: resHeader
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 30

            DankIcon {
                id: resStateIcon
                anchors.left: parent.left
                anchors.leftMargin: Theme.spacingS
                anchors.verticalCenter: parent.verticalCenter
                name: trc.success ? "check_circle" : "error_outline"
                size: 13
                color: trc.success ? Theme.surfaceTextMedium : Theme.error
            }

            StyledText {
                id: resName
                anchors.left: resStateIcon.right
                anchors.leftMargin: Theme.spacingXS
                anchors.verticalCenter: parent.verticalCenter
                text: trc.toolLabel || "Result"
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
            }

            DankIcon {
                id: resChevron
                anchors.right: parent.right
                anchors.rightMargin: Theme.spacingS
                anchors.verticalCenter: parent.verticalCenter
                name: trc.isExpanded ? "expand_less" : "expand_more"
                size: 14
                color: Theme.surfaceTextMedium
            }

            // Right-side count: web result count, diff lines, lines,
            // items, etc — whatever summarizeResult thought was
            // most useful. Smaller and muted, Claude-web style.
            StyledText {
                id: resCount
                anchors.right: resChevron.left
                anchors.rightMargin: Theme.spacingXS
                anchors.verticalCenter: parent.verticalCenter
                visible: !!text
                text: {
                    if (trc._webResults && trc._webResults.length > 0)
                        return trc._webResults.length + " result"
                             + (trc._webResults.length === 1 ? "" : "s")
                    if (trc._summary && trc._summary.detail) return trc._summary.detail
                    return ""
                }
                color: Theme.surfaceTextMedium
                font.pixelSize: Theme.fontSizeSmall - 1
                opacity: 0.85
            }

            MouseArea {
                id: trcHeaderMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    const ml = trc.hermesService.messageList
                    if (trc.rowIndex >= 0 && trc.rowIndex < ml.count)
                        ml.setProperty(trc.rowIndex, "expanded", !trc.isExpanded)
                }
            }
        }

        // Expanded body: either the Claude-style results list (for
        // web_search-shaped payloads) or the JsonView tree. Both
        // share a single Item whose height is reported up to card
        // so the explicit card.height math stays simple.
        Item {
            id: resBodyContainer
            visible: trc.isExpanded
            anchors.top: resHeader.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: {
                if (!trc.isExpanded) return 0
                if (trc.hasWebResults)
                    return webResultsList.height + Theme.spacingS
                return resultStructured.height + Theme.spacingS
            }

            // ── Web-results list (favicon · title · url · snippet) ──
            ListView {
                id: webResultsList
                visible: trc.hasWebResults
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.topMargin: Theme.spacingXS
                anchors.leftMargin: Theme.spacingS
                anchors.rightMargin: Theme.spacingS
                interactive: false
                clip: true
                model: trc._webResults
                spacing: 0
                delegate: webResultRowComponent
            }

            Component {
                id: webResultRowComponent
                Item {
                    width: webResultsList.width
                    height: rowCol.implicitHeight + Theme.spacingM
                    // Thin separator between rows — Claude web uses
                    // a hairline divider rather than full gaps.
                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: 1
                        color: Theme.outlineVariant
                        opacity: 0.4
                    }
                    Column {
                        id: rowCol
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.topMargin: Theme.spacingM
                        spacing: 2
                        StyledText {
                            width: parent.width
                            text: modelData.title || modelData.url || "(untitled)"
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: Font.Medium
                            wrapMode: Text.WordWrap
                            visible: text.length > 0
                        }
                        StyledText {
                            width: parent.width
                            text: modelData.source
                                ? modelData.source
                                : (modelData.url ? modelData.url : "")
                            color: Theme.surfaceTextMedium
                            font.pixelSize: Theme.fontSizeSmall - 2
                            opacity: 0.75
                            elide: Text.ElideRight
                            visible: text.length > 0
                        }
                        StyledText {
                            width: parent.width
                            text: modelData.snippet
                            color: Theme.surfaceTextMedium
                            font.pixelSize: Theme.fontSizeSmall - 1
                            wrapMode: Text.WordWrap
                            visible: text.length > 0
                            elide: Text.ElideRight
                            maximumLineCount: 2
                        }
                    }
                }
            }

            // ── Structured content for non-web payloads ──
            // Uses ToolContentView for known tool types
            // (terminal, patch, read, write, search) and falls
            // back to the JsonView tree for anything else.
            Item {
                id: resultStructured
                visible: !trc.hasWebResults
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.topMargin: Theme.spacingXS
                height: visible ? resultToolContent.height : 0

                readonly property var _classified: Tf.classifyResultContent(trc.toolName, trc.contentText)

                ToolContentView {
                    id: resultToolContent
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    content: parent._classified.type !== "json" ? parent._classified : null
                    rawText: parent._classified.type === "json" && trc.isExpanded
                             ? trc.contentText : ""
                    sourceAccent: trc.success ? Theme.primary : Theme.error
                }
            }
        }

        // ── Done footer pill — matches the Claude web UI's "Done"
        //    button that sits at the bottom of expanded web cards.
        Rectangle {
            id: donePill
            visible: trc.isExpanded && trc.hasWebResults
            anchors.top: resBodyContainer.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.topMargin: 2
            width: doneRow.implicitWidth + Theme.spacingM * 2
            height: 28
            radius: height / 2
            color: doneMouse.containsMouse ? Theme.surfaceContainerHigh
                                           : "transparent"
            border.width: 1
            border.color: Theme.outlineVariant

            Row {
                id: doneRow
                anchors.centerIn: parent
                spacing: Theme.spacingXS
                DankIcon {
                    name: "check"
                    size: 12
                    color: Theme.surfaceTextMedium
                    anchors.verticalCenter: parent.verticalCenter
                }
                StyledText {
                    text: "Done"
                    color: Theme.surfaceTextMedium
                    font.pixelSize: Theme.fontSizeSmall - 1
                    font.weight: Font.Medium
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
            MouseArea {
                id: doneMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    const ml = trc.hermesService.messageList
                    if (trc.rowIndex >= 0 && trc.rowIndex < ml.count)
                        ml.setProperty(trc.rowIndex, "expanded", false)
                }
            }
        }
    }
}
