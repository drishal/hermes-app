import QtQuick
import qs.Common
import qs.Widgets

// Permission-request card (msg.type === "approval"). Shows the command and,
// until resolved, allow-once / allow-session / deny buttons that answer the
// pending approval through hermesService.
//
// Extracted from ChatArea's inline delegate Component; wired by the Loader
// wrapper that passes `msg` and `hermesService`.
Item {
    id: apc
    width: parent.width

    property var msg: null
    property var hermesService: null

    readonly property string contentText: msg ? (msg.content || "") : ""
    readonly property string toolStatus: msg ? (msg.toolStatus || "") : ""
    readonly property bool resolved: toolStatus !== ""
    readonly property bool denied: toolStatus === "deny"
    readonly property color accent: resolved ? (denied ? Theme.error : Theme.primary) : Theme.tertiary
    height: approvalCard.height + Theme.spacingS

    Rectangle {
        id: approvalCard
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.rightMargin: parent.width * 0.06
        height: approvalCol.implicitHeight + Theme.spacingM * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh
        border.width: 1
        border.color: apc.accent
        Behavior on border.color { ColorAnimation { duration: 220 } }

        // Attention accent bar down the left edge.
        Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.margins: 1
            width: 3
            radius: 1.5
            color: apc.accent
            Behavior on color { ColorAnimation { duration: 220 } }
        }

        Column {
            id: approvalCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.leftMargin: Theme.spacingM
            anchors.rightMargin: Theme.spacingM
            anchors.topMargin: Theme.spacingM
            spacing: Theme.spacingS

            Row {
                spacing: Theme.spacingXS

                DankIcon {
                    name: apc.resolved ? (apc.denied ? "block" : "verified_user") : "admin_panel_settings"
                    size: 16
                    color: apc.accent
                    anchors.verticalCenter: parent.verticalCenter
                }

                StyledText {
                    text: "Permission required"
                    color: apc.accent
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Medium
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            // Highlighted, copyable command preview.
            CodeBlock {
                width: parent.width
                content: apc.contentText
                language: "bash"
                complete: true
            }

            // Action buttons.
            Row {
                visible: !apc.resolved
                spacing: Theme.spacingXS

                Rectangle {
                    width: allowOnceRow.implicitWidth + Theme.spacingM * 2
                    height: 30
                    radius: Math.max(4, Theme.cornerRadius / 2)
                    color: allowOnceMouse.containsMouse ? Theme.primaryPressed : Theme.primary
                    Behavior on color { ColorAnimation { duration: 120 } }

                    Row {
                        id: allowOnceRow
                        anchors.centerIn: parent
                        spacing: 4
                        DankIcon { name: "check"; size: 14; color: Theme.onPrimary; anchors.verticalCenter: parent.verticalCenter }
                        StyledText { text: "Allow once"; color: Theme.onPrimary; font.pixelSize: Theme.fontSizeSmall; font.weight: Font.Medium; anchors.verticalCenter: parent.verticalCenter }
                    }

                    MouseArea {
                        id: allowOnceMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: apc.hermesService.resolveApproval("once")
                    }
                }

                Rectangle {
                    width: allowSessionRow.implicitWidth + Theme.spacingM * 2
                    height: 30
                    radius: Math.max(4, Theme.cornerRadius / 2)
                    color: allowSessionMouse.containsMouse ? Theme.surfaceHover : Theme.surfaceVariantAlpha
                    Behavior on color { ColorAnimation { duration: 120 } }

                    Row {
                        id: allowSessionRow
                        anchors.centerIn: parent
                        spacing: 4
                        DankIcon { name: "schedule"; size: 14; color: Theme.surfaceText; anchors.verticalCenter: parent.verticalCenter }
                        StyledText { text: "Allow session"; color: Theme.surfaceText; font.pixelSize: Theme.fontSizeSmall; anchors.verticalCenter: parent.verticalCenter }
                    }

                    MouseArea {
                        id: allowSessionMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: apc.hermesService.resolveApproval("session")
                    }
                }

                Rectangle {
                    width: denyRow.implicitWidth + Theme.spacingM * 2
                    height: 30
                    radius: Math.max(4, Theme.cornerRadius / 2)
                    color: denyMouse.containsMouse ? Theme.error : Theme.errorPressed
                    Behavior on color { ColorAnimation { duration: 120 } }

                    Row {
                        id: denyRow
                        anchors.centerIn: parent
                        spacing: 4
                        DankIcon { name: "block"; size: 14; color: denyMouse.containsMouse ? Theme.onPrimary : Theme.error; anchors.verticalCenter: parent.verticalCenter }
                        StyledText { text: "Deny"; color: denyMouse.containsMouse ? Theme.onPrimary : Theme.error; font.pixelSize: Theme.fontSizeSmall; anchors.verticalCenter: parent.verticalCenter }
                    }

                    MouseArea {
                        id: denyMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: apc.hermesService.resolveApproval("deny")
                    }
                }
            }

            // Resolved status.
            Row {
                visible: apc.resolved
                spacing: Theme.spacingXS

                DankIcon {
                    name: apc.denied ? "cancel" : "check_circle"
                    size: 14
                    color: apc.accent
                    anchors.verticalCenter: parent.verticalCenter
                }

                StyledText {
                    text: apc.toolStatus === "once" || apc.toolStatus === "session"
                          ? "Approved (" + apc.toolStatus + ")"
                          : apc.toolStatus === "always" ? "Always approved" : "Denied"
                    color: apc.accent
                    font.pixelSize: Theme.fontSizeSmall
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }
    }
}
