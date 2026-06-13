import QtQuick
import qs.Common
import qs.Widgets

// User message bubble (msg.type === "user"): right-aligned primary bubble with
// a hover toolbar (copy / edit) and a timestamp. Edit pulls the text back into
// the composer and truncates the conversation via chat.editMessage.
//
// Extracted from ChatArea's inline delegate; the Loader wrapper passes `msg`,
// `rowIndex`, `hermesService` and `chat` (the ChatArea root).
Item {
    id: umc
    width: parent.width

    property var msg: null
    property int rowIndex: -1
    property var hermesService: null
    property var chat: null

    readonly property string contentText: msg ? (msg.content || "") : ""
    height: userBubble.height + (msgTime.visible ? msgTime.implicitHeight + 4 : 0) + 2

    HoverHandler { id: umcHover }

    // Hover toolbar in the empty space left of the user bubble: copy / edit.
    Rectangle {
        anchors.right: userBubble.left
        anchors.top: userBubble.top
        anchors.rightMargin: Theme.spacingXS
        width: umcActions.width + 6
        height: 22
        radius: 11
        color: Theme.surfaceContainerHighest
        border.width: 1
        border.color: Theme.outlineVariant
        opacity: (umcHover.hovered && !umc.hermesService.isRunning) ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 120 } }

        Row {
            id: umcActions
            anchors.centerIn: parent
            spacing: 0

            Rectangle {
                width: 24; height: 18; radius: 6
                color: copyUserMouse.containsMouse ? Theme.surfaceHover : "transparent"
                DankIcon { anchors.centerIn: parent; name: "content_copy"; size: 13; color: Theme.surfaceTextMedium }
                MouseArea {
                    id: copyUserMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Platform.copyToClipboard(umc.contentText)
                }
            }
            Rectangle {
                width: 24; height: 18; radius: 6
                color: editUserMouse.containsMouse ? Theme.surfaceHover : "transparent"
                DankIcon { anchors.centerIn: parent; name: "edit"; size: 13; color: Theme.surfaceTextMedium }
                MouseArea {
                    id: editUserMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: umc.chat.editMessage(umc.rowIndex, umc.contentText)
                }
            }
        }
    }

    Rectangle {
        id: userBubble
        anchors.right: parent.right
        width: Math.min(userText.implicitWidth + Theme.spacingM * 2, parent.width * 0.85)
        height: userText.implicitHeight + Theme.spacingS * 2
        color: Theme.primary
        radius: Theme.cornerRadius

        TextEdit {
            id: userText
            anchors.fill: parent
            anchors.margins: Theme.spacingS
            text: umc.msg ? umc.msg.content : ""
            color: Theme.primaryText
            font.pixelSize: Theme.fontSizeMedium
            wrapMode: TextEdit.Wrap
            textFormat: TextEdit.PlainText
            readOnly: true
            selectByMouse: true
            selectionColor: Theme.onPrimary
            selectedTextColor: Theme.primary
            persistentSelection: true
            HoverHandler {
                cursorShape: Qt.IBeamCursor
            }
        }
    }

    StyledText {
        id: msgTime
        anchors.top: userBubble.bottom
        anchors.right: userBubble.right
        anchors.topMargin: 2
        text: {
            const d = new Date(((umc.msg && umc.msg.timestamp) || 0) * 1000)
            return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
        }
        color: Theme.surfaceTextMedium
        font.pixelSize: Theme.fontSizeSmall - 1
        visible: umc.msg && umc.msg.timestamp > 0
    }
}
