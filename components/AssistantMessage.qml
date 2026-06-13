import QtQuick
import qs.Common
import qs.Widgets

// Assistant reply (msg.type === "assistant"): Claude-style text flowing on the
// background (no bubble), rendered as segmented markdown via MessageContent.
// While streaming it shows the live thinking trace (peeked from the nearest
// thinking row above) or a breathing "Hermes is thinking…" indicator, plus a
// blinking cursor; a hover toolbar offers copy / retry, and stats (duration ·
// tokens) show once finished.
//
// Extracted from ChatArea's inline delegate; the Loader wrapper passes `msg`,
// `rowIndex`, `hermesService` and `chat` (the ChatArea root, for retryMessage).
Item {
    id: amc
    width: parent.width

    property var msg: null
    property int rowIndex: -1
    property var hermesService: null
    property var chat: null

    readonly property bool streaming: msg ? !!msg.isStreaming : false
    readonly property string contentText: msg ? (msg.content || "") : ""
    readonly property bool hasContent: contentText.length > 0
    // Peek at the most recent thinking row above this assistant row so we can
    // show the live reasoning text instead of a static "Hermes is thinking…"
    // label while streaming.
    readonly property string liveThinkingText: {
        if (!streaming) return ""
        const ml = hermesService.messageList
        for (let i = rowIndex - 1; i >= 0; --i) {
            const m = ml.get(i)
            if (m.type === "thinking") return m.content || ""
            if (m.type !== "tool_call" && m.type !== "tool_result") break
        }
        return ""
    }
    readonly property real msgDuration: msg ? (msg.duration || 0) : 0
    readonly property int msgTotalTokens: msg && msg.usage ? (msg.usage.total_tokens || 0) : 0
    readonly property int msgInTokens: msg && msg.usage ? (msg.usage.input_tokens || 0) : 0
    readonly property int msgOutTokens: msg && msg.usage ? (msg.usage.output_tokens || 0) : 0
    readonly property bool hasStats: !streaming && (msgDuration > 0 || msgTotalTokens > 0)
    height: assistantBubble.height
            + (msgTime.visible ? msgTime.implicitHeight + 2 : 0)
            + (statsRow.visible ? statsRow.implicitHeight + 1 : 0)
            + 2

    // Claude-style: assistant text flows directly on the background —
    // no bubble, full measure.
    Item {
        id: assistantBubble
        anchors.left: parent.left
        width: parent.width
        height: bubbleContent.implicitHeight + Theme.spacingXS + (amc.streaming ? 4 : 0)

        Item {
            id: bubbleContent
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.topMargin: 2
            implicitHeight: {
                if (amc.streaming && !amc.hasContent) {
                    if (amc.liveThinkingText)
                        return liveThinkingDisplay.height
                    return thinkingIndicator.height
                }
                return messageContent.implicitHeight + (amc.streaming ? cursorDot.height + 2 : 0)
            }

            Row {
                id: thinkingIndicator
                visible: amc.streaming && !amc.hasContent && !amc.liveThinkingText
                spacing: Theme.spacingXS
                anchors.left: parent.left

                // Whole row breathes while we wait for the first token.
                SequentialAnimation on opacity {
                    running: thinkingIndicator.visible
                    loops: Animation.Infinite
                    NumberAnimation { from: 0.5; to: 1; duration: 750; easing.type: Easing.InOutSine }
                    NumberAnimation { from: 1; to: 0.5; duration: 750; easing.type: Easing.InOutSine }
                }

                DankIcon {
                    name: "auto_awesome"
                    size: 14
                    color: Theme.primary
                    anchors.verticalCenter: parent.verticalCenter
                }

                StyledText {
                    text: "Hermes is thinking…"
                    color: Theme.surfaceTextMedium
                    font.pixelSize: Theme.fontSizeMedium
                    font.italic: true
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            // Live reasoning text — shows the thinking card content inline
            // while the assistant is streaming but hasn't produced visible
            // content yet. Replaces the static "Hermes is thinking…" label
            // with the actual reasoning trace, matching the webui's live
            // thinking card behavior.
            Column {
                id: liveThinkingDisplay
                visible: amc.streaming && !amc.hasContent && amc.liveThinkingText.length > 0
                anchors.left: parent.left
                anchors.right: parent.right
                spacing: 0

                Row {
                    spacing: Theme.spacingXS

                    DankIcon {
                        name: "lightbulb"
                        size: 13
                        color: Theme.primary
                        opacity: 0.7
                        anchors.verticalCenter: parent.verticalCenter

                        SequentialAnimation on opacity {
                            running: liveThinkingDisplay.visible
                            loops: Animation.Infinite
                            NumberAnimation { from: 0.55; to: 1; duration: 700; easing.type: Easing.InOutSine }
                            NumberAnimation { from: 1; to: 0.55; duration: 700; easing.type: Easing.InOutSine }
                        }
                    }

                    StyledText {
                        text: "Thinking…"
                        color: Theme.primary
                        opacity: 0.85
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.DemiBold
                    }
                }

                Flickable {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: Math.min(thinkingLiveText.implicitHeight + 4, 200)
                    contentWidth: width
                    contentHeight: thinkingLiveText.implicitHeight
                    clip: true
                    flickableDirection: Flickable.VerticalFlick
                    interactive: contentHeight > height
                    boundsBehavior: Flickable.StopAtBounds
                    onContentHeightChanged: contentY = Math.max(0, contentHeight - height)

                    TextEdit {
                        id: thinkingLiveText
                        width: parent.width
                        text: amc.liveThinkingText
                        color: Theme.surfaceTextMedium
                        font.pixelSize: Theme.fontSizeSmall - 1
                        font.family: "monospace"
                        wrapMode: TextEdit.Wrap
                        textFormat: TextEdit.PlainText
                        readOnly: true
                        selectByMouse: true
                        selectionColor: Theme.primary
                        selectedTextColor: Theme.onPrimary
                    }
                }
            }

            MessageContent {
                id: messageContent
                visible: amc.hasContent
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                text: amc.contentText
                isStreaming: amc.streaming
            }

            Rectangle {
                id: cursorDot
                visible: amc.streaming && amc.hasContent
                anchors.left: messageContent.left
                anchors.top: messageContent.bottom
                anchors.topMargin: 2
                width: 6
                height: 14
                radius: 2
                color: Theme.primary

                SequentialAnimation on opacity {
                    running: cursorDot.visible
                    loops: Animation.Infinite
                    NumberAnimation { from: 1; to: 0; duration: 500 }
                    NumberAnimation { from: 0; to: 1; duration: 500 }
                }
            }
        }
    }

    HoverHandler { id: amcHover }

    // Hover toolbar: copy / retry.
    Rectangle {
        anchors.right: assistantBubble.right
        anchors.top: assistantBubble.top
        anchors.margins: 4
        width: amcActions.width + 6
        height: 22
        radius: 11
        color: Theme.surfaceContainerHighest
        border.width: 1
        border.color: Theme.outlineVariant
        opacity: (amcHover.hovered && !amc.streaming && amc.hasContent) ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 120 } }

        Row {
            id: amcActions
            anchors.centerIn: parent
            spacing: 0

            Rectangle {
                width: 24; height: 18; radius: 6
                color: copyAsstMouse.containsMouse ? Theme.surfaceHover : "transparent"
                DankIcon { anchors.centerIn: parent; name: "content_copy"; size: 13; color: Theme.surfaceTextMedium }
                MouseArea {
                    id: copyAsstMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Platform.copyToClipboard(amc.contentText)
                }
            }
            Rectangle {
                width: 24; height: 18; radius: 6
                opacity: amc.hermesService.isRunning ? 0.4 : 1
                color: retryAsstMouse.containsMouse ? Theme.surfaceHover : "transparent"
                DankIcon { anchors.centerIn: parent; name: "refresh"; size: 13; color: Theme.surfaceTextMedium }
                MouseArea {
                    id: retryAsstMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: amc.chat.retryMessage(amc.rowIndex)
                }
            }
        }
    }

    StyledText {
        id: msgTime
        anchors.top: assistantBubble.bottom
        anchors.left: assistantBubble.left
        anchors.topMargin: 2
        text: {
            const d = new Date(((amc.msg && amc.msg.timestamp) || 0) * 1000)
            return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
        }
        color: Theme.surfaceTextMedium
        font.pixelSize: Theme.fontSizeSmall - 1
        visible: amc.msg && amc.msg.timestamp > 0 && !amc.streaming
    }

    Row {
        id: statsRow
        anchors.top: msgTime.visible ? msgTime.bottom : assistantBubble.bottom
        anchors.left: assistantBubble.left
        anchors.topMargin: 1
        spacing: 6
        visible: amc.hasStats

        StyledText {
            visible: amc.msgDuration > 0
            text: amc.msgDuration < 1
                ? (amc.msgDuration * 1000).toFixed(0) + "ms"
                : amc.msgDuration.toFixed(1) + "s"
            color: Theme.surfaceTextMedium
            font.pixelSize: Theme.fontSizeSmall - 1
            opacity: 0.8
        }

        StyledText {
            visible: amc.msgDuration > 0 && amc.msgTotalTokens > 0
            text: "·"
            color: Theme.surfaceTextMedium
            font.pixelSize: Theme.fontSizeSmall - 1
            opacity: 0.5
        }

        StyledText {
            visible: amc.msgTotalTokens > 0
            text: (amc.msgInTokens && amc.msgOutTokens)
                ? amc.msgInTokens + "→" + amc.msgOutTokens + " tok"
                : amc.msgTotalTokens + " tok"
            color: Theme.surfaceTextMedium
            font.pixelSize: Theme.fontSizeSmall - 1
            opacity: 0.8
        }
    }
}
