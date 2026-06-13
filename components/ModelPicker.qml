import QtQuick
import qs.Common
import qs.Widgets

// Claude-style model selector dropdown. Anchored above the composer toolbar by
// the parent; shows provider labels, model names, and a description. The current
// model is highlighted and checked.
Rectangle {
    id: root

    required property var hermesService

    property bool open: false
    property string currentModelId: hermesService.currentModel || ""
    property bool loading: hermesService.modelsLoading || false
    property var models: hermesService.availableModels || []

    // Resolve the full modelId for the active model so we can match it
    // against entries in `models` (which carry modelId like "provider:model").
    readonly property string activeModelId: {
        const m = hermesService.currentModel || ""
        for (let i = 0; i < models.length; i++) {
            if (models[i].name === m || models[i].modelId === m
                || models[i].modelId.split(":").slice(1).join(":") === m)
                return models[i].modelId
        }
        return m
    }

    // Friendly display name for the active model (falls back to the id).
    readonly property string activeModelName: {
        const m = hermesService.currentModel || ""
        for (let i = 0; i < models.length; i++) {
            if (models[i].name === m || models[i].modelId === m
                || models[i].modelId.split(":").slice(1).join(":") === m)
                return models[i].name
        }
        return m
    }
    signal modelSelected(string modelId)
    signal refreshRequested()

    visible: open
    width: parent ? Math.min(parent.width, 360) : 360
    height: open ? Math.min(listView.contentHeight + header.height + Theme.spacingM, 420) : 0
    anchors.horizontalCenter: parent ? parent.horizontalCenter : undefined
    anchors.bottom: parent ? parent.top : undefined
    anchors.bottomMargin: Theme.spacingS
    radius: Theme.cornerRadius * 1.2
    color: Theme.surfaceContainerHigh
    border.width: 1
    border.color: Theme.outlineMedium

    // Eat wheel events so scrolling over the picker doesn't scroll the chat.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.NoButton
        onWheel: wheel => wheel.accepted = true
    }

    Column {
        anchors.fill: parent
        anchors.margins: Theme.spacingS
        spacing: Theme.spacingXS

        // Header
        Row {
            id: header
            width: parent.width
            height: 28

            StyledText {
                text: "Models"
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                anchors.verticalCenter: parent.verticalCenter
            }

            Item { width: parent.width - refreshBtn.width; height: 1 }

            Rectangle {
                id: refreshBtn
                width: 28
                height: 28
                radius: 14
                color: refreshMouse.containsMouse ? Theme.surfaceHover : "transparent"
                anchors.verticalCenter: parent.verticalCenter

                DankIcon {
                    anchors.centerIn: parent
                    name: "refresh"
                    size: 16
                    color: Theme.surfaceTextMedium
                }

                MouseArea {
                    id: refreshMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.refreshRequested()
                }
            }
        }

        // Loading / empty states
        StyledText {
            visible: root.loading && root.models.length === 0
            width: parent.width
            text: "Loading models…"
            color: Theme.surfaceTextMedium
            font.pixelSize: Theme.fontSizeSmall
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
        }

        StyledText {
            visible: !root.loading && root.models.length === 0
            width: parent.width
            text: "No models loaded yet. Start a run or click refresh."
            color: Theme.surfaceTextMedium
            font.pixelSize: Theme.fontSizeSmall
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
        }

        // Model list
        ListView {
            id: listView
            width: parent.width
            height: Math.max(0, parent.height - header.height - Theme.spacingXS)
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: root.models

            delegate: Rectangle {
                id: rowBg

                width: ListView.view.width
                height: 44
                radius: Theme.cornerRadius / 1.5
                color: rowMouse.containsMouse ? Theme.surfaceHover
                                              : (rowBg.isCurrent ? Theme.primaryBackground : "transparent")

                readonly property bool isCurrent: modelData.modelId === root.activeModelId

                Row {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.spacingS
                    anchors.rightMargin: Theme.spacingS
                    spacing: Theme.spacingS

                    Rectangle {
                        id: providerBadge
                        width: Math.max(60, providerText.implicitWidth + Theme.spacingS * 2)
                        height: 20
                        radius: 10
                        StyledText {
                            id: providerText
                            anchors.centerIn: parent
                            text: modelData.provider || "Custom"
                            color: rowBg.isCurrent ? Theme.surfaceText : Theme.surfaceTextMedium
                            font.pixelSize: Theme.fontSizeSmall - 1
                            font.weight: Font.Medium
                        }
                    }

                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 1
                        width: parent.width - providerBadge.width - check.width - Theme.spacingS * 3

                        StyledText {
                            width: parent.width
                            text: modelData.name
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: rowBg.isCurrent ? Font.Medium : Font.Normal
                            elide: Text.ElideRight
                        }

                        StyledText {
                            width: parent.width
                            visible: (modelData.description || "").length > 0
                            text: modelData.description || ""
                            color: Theme.surfaceTextMedium
                            font.pixelSize: Theme.fontSizeSmall - 2
                            elide: Text.ElideRight
                        }
                    }

                    DankIcon {
                        id: check
                        anchors.verticalCenter: parent.verticalCenter
                        visible: rowBg.isCurrent
                        name: "check"
                        size: 16
                        color: Theme.primary
                    }
                }

                MouseArea {
                    id: rowMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.modelSelected(modelData.modelId)
                }
            }
        }
    }
}
