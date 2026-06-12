import QtQuick
import qs.Common
import qs.Widgets

// Renders structured tool content (classified by toolFormat.js) in a
// Claude-like style instead of raw JSON. Supports four content types:
//   "code"  — code block with optional meta line
//   "diff"  — diff view with +/- colouring and header
//   "text"  — simple text line
//   "kv"    — key-value pair list
// Falls back to a JsonView tree for unrecognised / "json" types.

Item {
    id: root

    // The classified content object from Tf.classifyResultContent or
    // Tf.classifyCallContent. Set this, not the individual sub-properties.
    property var content: null
    // For "json" fallback: raw text to feed to JsonView.
    property string rawText: ""
    // Accent colour for the JsonView source badge.
    property color sourceAccent: Theme.primary

    readonly property string _type: content ? (content.type || "json") : "json"

    implicitHeight: _bodyHeight
    height: implicitHeight

    readonly property real _bodyHeight: {
        if (_type === "code") return codeBlock.height
        if (_type === "diff")  return diffBlock.height
        if (_type === "text")  return textLine.height + Theme.spacingS
        if (_type === "kv")    return kvList.height + Theme.spacingS
        // "json" fallback
        return Math.min(jsonFallback.height, 320) + Theme.spacingS
    }

    // ── Code block (terminal output, file content, commands) ──
    CodeBlock {
        id: codeBlock
        visible: root._type === "code"
        anchors.left: parent.left
        anchors.right: parent.right
        content: visible && root.content ? (root.content.body || "") : ""
        language: visible && root.content ? (root.content.language || "") : ""
        complete: true
    }

    // ── Diff block (patch results) ────────────────────────────
    Rectangle {
        id: diffBlock
        visible: root._type === "diff"
        anchors.left: parent.left
        anchors.right: parent.right
        color: Theme.surfaceContainerHighest
        radius: Math.max(4, Theme.cornerRadius / 2)
        border.width: 1
        border.color: Theme.outlineVariant
        clip: true

        height: visible ? diffHeader.height + 4 + diffCode.height + Theme.spacingS * 2 : 0

        Item {
            id: diffHeader
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Theme.spacingS
            anchors.rightMargin: Theme.spacingS
            anchors.topMargin: Theme.spacingS
            height: 18

            StyledText {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: root.content && root.content.path
                      ? root.content.path : "diff"
                color: Theme.surfaceTextMedium
                font.pixelSize: Theme.fontSizeSmall - 1
                font.italic: true
            }

            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingS

                StyledText {
                    text: "+" + (root.content ? root.content.added : 0)
                    color: Theme.success
                    font.pixelSize: Theme.fontSizeSmall - 1
                    font.weight: Font.Medium
                }
                StyledText {
                    text: "−" + (root.content ? root.content.removed : 0)
                    color: Theme.error
                    font.pixelSize: Theme.fontSizeSmall - 1
                    font.weight: Font.Medium
                }
            }
        }

        Rectangle {
            anchors.top: diffHeader.bottom
            anchors.topMargin: 4
            anchors.left: parent.left
            anchors.right: parent.right
            height: 1
            color: Theme.outlineVariant
        }

        Flickable {
            id: diffCode
            anchors.top: diffHeader.bottom
            anchors.topMargin: 5
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Theme.spacingS
            anchors.rightMargin: Theme.spacingS
            height: Math.min(diffText.implicitHeight, 260)
            contentWidth: Math.max(diffText.implicitWidth + Theme.spacingS * 2, width)
            contentHeight: diffText.implicitHeight
            clip: true
            flickableDirection: Flickable.HorizontalFlick
            boundsBehavior: Flickable.StopAtBounds

            TextEdit {
                id: diffText
                text: root.content ? (root.content.body || "") : ""
                color: Theme.surfaceText
                font.family: "monospace"
                font.pixelSize: Theme.fontSizeSmall
                wrapMode: TextEdit.NoWrap
                readOnly: true
                selectByMouse: true
                selectionColor: Theme.primary
                selectedTextColor: Theme.onPrimary
                persistentSelection: true
                HoverHandler { cursorShape: Qt.IBeamCursor }
            }
        }
    }

    // ── Simple text line ──────────────────────────────────────
    StyledText {
        id: textLine
        visible: root._type === "text"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Theme.spacingS
        anchors.top: parent.top
        anchors.topMargin: Theme.spacingXS
        text: visible && root.content ? (root.content.body || "") : ""
        color: Theme.surfaceTextMedium
        font.pixelSize: Theme.fontSizeSmall
        wrapMode: Text.WordWrap
    }

    // ── Key-value list ────────────────────────────────────────
    Column {
        id: kvList
        visible: root._type === "kv"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: Theme.spacingXS
        spacing: Theme.spacingXS

        Repeater {
            model: root._type === "kv" && root.content && root.content.fields
                   ? root.content.fields : []

            Item {
                width: kvList.width
                height: kvValue.implicitHeight + Theme.spacingXS

                StyledText {
                    id: kvKey
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.spacingM
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.key
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall - 1
                    font.weight: Font.Medium
                }

                StyledText {
                    id: kvValue
                    anchors.left: kvKey.right
                    anchors.leftMargin: Theme.spacingS
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.spacingS
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.value
                    color: modelData.highlight ? Theme.primary : Theme.surfaceText
                    font.pixelSize: Theme.fontSizeSmall - 1
                    font.family: modelData.highlight ? "monospace" : Theme.fontFamily
                    elide: Text.ElideMiddle
                    wrapMode: Text.NoWrap
                }
            }
        }
    }

    // ── JSON fallback (JsonView tree) ─────────────────────────
    Flickable {
        id: jsonFallbackFlick
        visible: root._type === "json"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: Theme.spacingXS
        anchors.leftMargin: Theme.spacingS + 22
        anchors.rightMargin: Theme.spacingS
        contentWidth: width
        contentHeight: jsonFallback.height
        clip: true
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        boundsBehavior: Flickable.StopAtBounds

        JsonView {
            id: jsonFallback
            width: parent.width
            content: root.rawText
            sourceAccent: root.sourceAccent
        }
    }
}
