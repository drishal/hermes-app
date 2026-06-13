import QtQuick
import qs.Common
import qs.Widgets

// Reasoning trace card (msg.type === "thinking"): a primary-tinted disclosure
// with a lightbulb + "Thinking" label, copy button and rotating chevron; the
// body holds the full trace in small muted monospace, scrollable past ~260px.
// Collapsed by default, but auto-opens while it's the newest row during a live
// run so the reasoning is visible as it streams.
//
// Extracted from ChatArea's inline delegate; the Loader wrapper passes `msg`,
// `rowIndex` and `hermesService`.
Item {
    id: tmc
    width: parent.width

    property var msg: null
    property int rowIndex: -1
    property var hermesService: null

    readonly property string contentText: msg ? (msg.content || "") : ""
    readonly property bool isExpanded: msg ? !!msg.expanded : false
    // The reasoning is streaming in right now: this is the newest row and a run
    // is active. Auto-open so the trace is visible live, without forcing the
    // persisted `expanded` state. Once the answer starts (a newer row appears)
    // or the run ends, it falls back to the user's choice.
    readonly property bool isLive: hermesService.isRunning
                                   && rowIndex === hermesService.messageList.count - 1
    readonly property bool showBody: isExpanded || isLive
    height: thinkCard.height + 2

    function toggleExpanded() {
        const ml = hermesService.messageList
        if (rowIndex >= 0 && rowIndex < ml.count)
            ml.setProperty(rowIndex, "expanded", !isExpanded)
    }

    Rectangle {
        id: thinkCard
        anchors.left: parent.left
        anchors.right: parent.right
        height: 26 + (tmc.showBody ? thinkBody.height : 0)
        radius: Math.max(6, Theme.cornerRadius / 2)
        color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.06)
        border.width: 1
        border.color: thinkMouse.containsMouse
            ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.35)
            : Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.16)
        Behavior on border.color { ColorAnimation { duration: 120 } }
        Behavior on height { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

        Item {
            id: thinkHeader
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: 26

            MouseArea {
                id: thinkMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: tmc.toggleExpanded()
            }

            DankIcon {
                id: thinkBulb
                anchors.left: parent.left
                anchors.leftMargin: Theme.spacingS
                anchors.verticalCenter: parent.verticalCenter
                name: "lightbulb"
                size: 13
                color: Theme.primary
                opacity: 0.7
            }

            StyledText {
                id: thinkLabel
                anchors.left: thinkBulb.right
                anchors.leftMargin: Theme.spacingXS
                anchors.verticalCenter: parent.verticalCenter
                text: tmc.isLive ? "Thinking…" : "Thinking"
                color: Theme.primary
                opacity: thinkMouse.containsMouse ? 1 : 0.85
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.DemiBold

                // Gentle pulse while the reasoning streams.
                SequentialAnimation on opacity {
                    running: tmc.isLive
                    loops: Animation.Infinite
                    NumberAnimation { from: 0.55; to: 1; duration: 700; easing.type: Easing.InOutSine }
                    NumberAnimation { from: 1; to: 0.55; duration: 700; easing.type: Easing.InOutSine }
                }
            }

            DankIcon {
                id: thinkChevron
                anchors.right: parent.right
                anchors.rightMargin: Theme.spacingS
                anchors.verticalCenter: parent.verticalCenter
                name: "chevron_right"
                size: 13
                color: Theme.primary
                opacity: 0.7
                rotation: tmc.showBody ? 90 : 0
                Behavior on rotation { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
            }

            // Copy the full trace (declared after thinkMouse so it stays on top
            // and clickable).
            Rectangle {
                anchors.right: thinkChevron.left
                anchors.rightMargin: Theme.spacingXS
                anchors.verticalCenter: parent.verticalCenter
                width: 20
                height: 18
                radius: 6
                color: thinkCopyMouse.containsMouse ? Theme.surfaceHover : "transparent"

                DankIcon {
                    anchors.centerIn: parent
                    name: "content_copy"
                    size: 11
                    color: Theme.primary
                    opacity: 0.8
                }

                MouseArea {
                    id: thinkCopyMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Platform.copyToClipboard(tmc.contentText)
                }
            }
        }

        Item {
            id: thinkBody
            visible: tmc.showBody
            anchors.top: thinkHeader.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: Math.min(thinkText.implicitHeight + Theme.spacingS, 260)

            Rectangle {
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                height: 1
                color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.16)
            }

            Flickable {
                id: thinkFlick
                anchors.fill: parent
                anchors.leftMargin: Theme.spacingS
                anchors.rightMargin: Theme.spacingS
                anchors.topMargin: Theme.spacingXS
                anchors.bottomMargin: Theme.spacingXS
                contentWidth: width
                contentHeight: thinkText.implicitHeight
                clip: true
                flickableDirection: Flickable.VerticalFlick
                interactive: contentHeight > height
                boundsBehavior: Flickable.StopAtBounds

                // Keep the newest reasoning in view while it streams.
                onContentHeightChanged: if (tmc.isLive) contentY = Math.max(0, contentHeight - height)

                TextEdit {
                    id: thinkText
                    width: parent.width
                    text: tmc.contentText
                    color: Theme.surfaceTextMedium
                    font.pixelSize: Theme.fontSizeSmall - 1
                    font.family: "monospace"
                    wrapMode: TextEdit.Wrap
                    textFormat: TextEdit.PlainText
                    readOnly: true
                    selectByMouse: true
                    selectionColor: Theme.primary
                    selectedTextColor: Theme.onPrimary
                    HoverHandler {
                        cursorShape: Qt.IBeamCursor
                    }
                }
            }
        }
    }
}
