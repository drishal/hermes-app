import QtQuick
import qs.Common
import qs.Widgets
import "../services/toolFormat.js" as Tf
import "../services/slashCommands.js" as Sc

Item {
    id: root

    required property var hermesService

    // Claude-style centered reading column: messages and the input bar are
    // capped at this width and centered; the window grows whitespace instead
    // of line length.
    readonly property int contentMaxWidth: 800
    readonly property int contentWidth: Math.min(width - Theme.spacingL * 2, contentMaxWidth)

    // Set true when this ChatArea is being rendered inside the detached
    // FloatingWindow. The expand button toggles its icon/tooltip accordingly.
    property bool expanded: false
    signal expandToggled()

    // Slash commands that need actions ChatArea doesn't own bubble up to
    // ChatContent (which owns the settings panel, palette and model save).
    signal settingsRequested()
    signal paletteRequested()
    signal modelChangeRequested(string model)

    // ── Pasted image attachments ───────────────────────────────
    // List of {path, name} for images pulled off the clipboard. Cleared
    // after send. On send, each path is prepended to the message text as
    // [Attached image: <path>] so Hermes' file/vision tools can pick it up
    // (Hermes config has trust_recent_files: true / 600s window).
    property var attachedImages: []

    function scrollToBottom() {
        messageListView.autoFollow = true
        Qt.callLater(() => messageListView.positionViewAtEnd())
    }

    function removeAttachment(idx) {
        const next = attachedImages.slice()
        next.splice(idx, 1)
        attachedImages = next
    }

    function clearAttachments() {
        attachedImages = []
    }

    function buildOutgoingMessage(text) {
        if (!attachedImages.length) return text
        let prefix = ""
        for (const img of attachedImages) {
            prefix += "[Attached image: " + img.path + "]\n"
        }
        return prefix + text
    }

    function sendCurrent(text) {
        const payload = buildOutgoingMessage(text)
        hermesService.sendMessage(payload)
        clearAttachments()
        messageListView.autoFollow = true
    }

    // Composer submit: a recognised slash command runs locally and is never
    // sent to the agent; everything else is a normal message. Returns true if
    // it consumed the input (so the caller clears the field).
    function submit() {
        const text = chatInput.text
        if (!text.trim() && root.attachedImages.length === 0) return false
        const parsed = Sc.parse(text.trim())
        if (parsed) {
            runCommand(parsed)
            return true
        }
        sendCurrent(text)
        return true
    }

    // ── Slash-command dispatch ─────────────────────────────────
    // Side effects live here (they need hermesService + the UI signals);
    // services/slashCommands.js owns the catalog/parsing.
    function runCommand(parsed) {
        switch (parsed.name) {
        case "help":
            showToast(Sc.helpText(), 9000)
            break
        case "new":
            hermesService.newChat()
            showToast("Started a new conversation")
            break
        case "stop":
            if (hermesService.isRunning) { hermesService.stopRun(); showToast("Stopping the run…") }
            else showToast("No active run to stop")
            break
        case "retry":
            retryLast()
            break
        case "model":
            if (parsed.args) {
                root.modelChangeRequested(parsed.args)
                showToast("Model set to " + parsed.args + " — applies to new turns")
            } else {
                const m = hermesService.currentModel || hermesService.selectedModel
                showToast("Current model: " + (m || "(gateway default)"))
            }
            break
        case "history":
            root.paletteRequested()
            break
        case "settings":
            root.settingsRequested()
            break
        }
    }

    // Resend the most recent user message (drops everything after it).
    function retryLast() {
        if (hermesService.isRunning) { showToast("Can't retry while a run is active"); return }
        const ml = hermesService.messageList
        for (let i = ml.count - 1; i >= 0; i--) {
            if (ml.get(i).type === "user") {
                hermesService.resendFrom(i, ml.get(i).content)
                messageListView.autoFollow = true
                return
            }
        }
        showToast("Nothing to retry")
    }

    function showToast(text, ms) {
        toast.text = text
        toast.shown = true
        toastTimer.interval = ms || 3500
        toastTimer.restart()
    }

    // ── Slash-command autocomplete state ───────────────────────
    property var _slashSuggestions: []
    property int _slashSel: 0

    function applySlash(name) {
        chatInput.text = "/" + name + " "
        chatInput.cursorPosition = chatInput.text.length
    }

    // Retry: resend the user message that preceded this assistant reply,
    // dropping everything from that point so a fresh response streams in.
    function retryMessage(assistantIndex) {
        if (hermesService.isRunning) return
        const ml = hermesService.messageList
        for (let i = assistantIndex - 1; i >= 0; i--) {
            if (ml.get(i).type === "user") {
                hermesService.resendFrom(i, ml.get(i).content)
                messageListView.autoFollow = true
                return
            }
        }
    }

    // Edit: pull a user message back into the input and truncate the
    // conversation to before it, so the next send resumes from there.
    function editMessage(userIndex, text) {
        if (hermesService.isRunning) return
        hermesService.truncateTo(userIndex)
        chatInput.text = text
        chatInput.forceActiveFocus()
        chatInput.cursorPosition = text.length
        messageListView.autoFollow = true
    }

    function tryPasteImage() {
        // Pulls a PNG off the Qt clipboard into /tmp and returns its path, or
        // "" when the clipboard holds no image (the normal text-paste case).
        const path = Platform.pasteImage()
        if (!path) return
        const name = path.split("/").pop()
        root.attachedImages = root.attachedImages.concat([{ path: path, name: name }])
    }

    Column {
        anchors.fill: parent
        spacing: 0

        // ═══════════════════════════════════════════════════════
        //  MESSAGE LIST
        // ═══════════════════════════════════════════════════════

        ListView {
            id: messageListView
            width: parent.width
            height: parent.height - statusBar.height - inputRowWrap.height - attachStrip.height
            clip: true
            spacing: Theme.spacingM
            leftMargin: Theme.spacingL
            rightMargin: Theme.spacingL
            topMargin: Theme.spacingL
            bottomMargin: Theme.spacingM

            model: hermesService.messageList
            boundsBehavior: Flickable.StopAtBounds

            // Pin to the newest content while the user is reading near the
            // bottom; release the pin when they scroll up to read back, so
            // streaming tokens follow smoothly without yanking the view.
            property bool autoFollow: true
            property bool _pinning: false
            // Coalesced, re-entrancy-guarded pin. Calling positionViewAtEnd()
            // instantiates bottom delegates, which changes contentHeight — so
            // doing it directly from onContentHeightChanged loops forever (CPU
            // pegs, UI freezes) when variable-height rows like code blocks load.
            function _pinBottom() {
                if (!autoFollow || _pinning) return
                _pinning = true
                positionViewAtEnd()
                _pinning = false
            }
            onCountChanged: if (autoFollow) Qt.callLater(_pinBottom)
            // Follow growing content only while a reply is streaming (monotonic,
            // stable); a session load just pins once via onCountChanged.
            onContentHeightChanged: if (autoFollow && hermesService.isRunning) Qt.callLater(_pinBottom)
            onMovementEnded: autoFollow = atYEnd
            onFlickEnded: autoFollow = atYEnd

            // A window resize re-wraps every delegate (text reflows, tables
            // re-measure) and ListView's cached row positions go stale — rows
            // overlap until something forces a relayout. The cascade is:
            //   width change → delegate TextEdit/TableBlock re-wrap →
            //   their _relayout via Qt.callLater → delegate height changes →
            //   ListView needs forceLayout()
            // Qt.callLater is too early: it fires before delegates finish
            // their own queued relayouts, so forceLayout sees stale heights.
            // A short debounced Timer lets the full cascade settle first.
            Timer {
                id: resettleTimer
                interval: 16
                onTriggered: {
                    messageListView.forceLayout()
                    if (messageListView.autoFollow) messageListView._pinBottom()
                }
            }
            function _requestResettle() { resettleTimer.restart() }
            onWidthChanged: _requestResettle()
            onHeightChanged: _requestResettle()

            // After a session load, delegate heights have just settled (rich
            // text, tables) — relayout once and pin to the latest message,
            // same as what a manual window resize was fixing by accident.
            // Run completion gets the same treatment: the streamed reply
            // re-segments from plain text into markdown/tables/code blocks,
            // so row heights jump and cached positions go stale.
            Connections {
                target: root.hermesService
                ignoreUnknownSignals: true
                function onMessagesLoaded() {
                    messageListView.autoFollow = true
                    messageListView._requestResettle()
                }
                function onRunCompleted(output) {
                    messageListView._requestResettle()
                }
                function onRunFailed(error) {
                    messageListView._requestResettle()
                }
            }

            // New rows fade in — but ONLY during a live run. Two traps avoided:
            //  • `bulkLoading` is too short-lived to gate on: ListView creates
            //    delegates lazily, after the append loop (and the flag) have
            //    finished, so the transition still fired on session loads. An
            //    in-flight add transition desyncs a row whose height then
            //    settles async (markdown/table re-measure) → rows overlap, and
            //    ListView never corrects it. Gating on isRunning keeps loads
            //    completely static.
            //  • No `displaced` transition at all — animating neighbour y has
            //    the same settle-desync problem. Neighbours snap to final y.
            add: Transition {
                enabled: root.hermesService.isRunning && !root.hermesService.bulkLoading
                NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 220; easing.type: Easing.OutCubic }
                NumberAnimation { property: "scale"; from: 0.95; to: 1; duration: 240; easing.type: Easing.OutBack }
            }

            // Scroll-to-bottom button
            Rectangle {
                visible: messageListView.contentHeight > messageListView.height && messageListView.contentY < messageListView.contentHeight - messageListView.height - 50
                anchors.bottom: parent.bottom
                anchors.right: parent.right
                anchors.margins: Theme.spacingM
                width: 32
                height: 32
                radius: 16
                color: Theme.surfaceContainerHigh
                border.width: 1
                border.color: Theme.outlineMedium

                DankIcon {
                    anchors.centerIn: parent
                    name: "keyboard_arrow_down"
                    size: 18
                    color: Theme.surfaceText
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.scrollToBottom()
                }
            }

            delegate: Item {
                objectName: "msgRow"
                width: messageListView.width - messageListView.leftMargin - messageListView.rightMargin
                height: contentLoader.height + Theme.spacingXS
                // Row heights settle asynchronously (MessageContent/TableBlock
                // re-wrap and re-measure). The resettleTimer handles this:
                // it debounces and runs after the cascade finishes.
                onHeightChanged: messageListView._requestResettle()

                Loader {
                    id: contentLoader
                    // Centered reading column — rows span the ListView, content
                    // is capped and centered within them.
                    width: Math.min(parent.width, root.contentMaxWidth)
                    anchors.horizontalCenter: parent.horizontalCenter
                    // Capture row data here — Components are declared outside the
                    // delegate, so they don't inherit the delegate's `model` context.
                    // Each loaded item reaches the row via `parent.msg` / `parent.msgIndex`.
                    property var msg: model
                    property int msgIndex: index
                    sourceComponent: {
                        switch (msg ? msg.type : "") {
                        case "user":        return userMsgComponent
                        case "assistant":   return assistantMsgComponent
                        case "thinking":    return thinkingMsgComponent
                        case "tool_call":   return toolCallMsgComponent
                        case "tool_result": return toolResultMsgComponent
                        case "approval":    return approvalMsgComponent
                        default:            return null
                        }
                    }
                }
            }

            WelcomeDashboard {
                visible: messageListView.count === 0
                anchors.fill: parent
                hermesService: root.hermesService
            }
        }

        // ═══════════════════════════════════════════════════════
        //  STATUS BAR
        // ═══════════════════════════════════════════════════════

        Rectangle {
            id: statusBar
            width: parent.width
            height: 24
            color: "transparent"

            Row {
                width: root.contentWidth
                height: parent.height
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Theme.spacingS

                // Connection dot
                Rectangle {
                    width: 8
                    height: 8
                    radius: 4
                    color: hermesService.connected ? Theme.primary : Theme.error
                    anchors.verticalCenter: parent.verticalCenter

                    Behavior on color { ColorAnimation { duration: 300 } }

                    SequentialAnimation on opacity {
                        running: hermesService.isRunning
                        loops: Animation.Infinite
                        NumberAnimation { from: 1; to: 0.3; duration: 800 }
                        NumberAnimation { from: 0.3; to: 1; duration: 800 }
                    }
                }

                StyledText {
                    text: hermesService.connected
                          ? (hermesService.isRunning ? "Running…" : hermesService.currentModel || "Ready")
                          : "Disconnected"
                    color: hermesService.connected ? Theme.surfaceTextMedium : Theme.error
                    font.pixelSize: Theme.fontSizeSmall
                    anchors.verticalCenter: parent.verticalCenter
                }

                // Token usage
                StyledText {
                    visible: hermesService.lastUsage && hermesService.lastUsage.total_tokens > 0
                    text: {
                        const u = hermesService.lastUsage
                        if (!u) return ""
                        const total = u.total_tokens || 0
                        return "· " + total + " tokens"
                    }
                    color: Theme.surfaceTextMedium
                    font.pixelSize: Theme.fontSizeSmall
                    anchors.verticalCenter: parent.verticalCenter
                }

                Item { width: Math.max(0, parent.width - 360); height: 1 }

                // Session ID indicator
                StyledText {
                    visible: hermesService.currentSessionId !== ""
                    text: hermesService.currentSessionId.length > 12
                          ? hermesService.currentSessionId.substring(0, 12) + "…"
                          : hermesService.currentSessionId
                    color: Theme.surfaceTextMedium
                    font.pixelSize: Theme.fontSizeSmall
                    font.family: "monospace"
                    anchors.verticalCenter: parent.verticalCenter
                }

            }
        }

        // ═══════════════════════════════════════════════════════
        //  ATTACHMENT STRIP
        // ═══════════════════════════════════════════════════════

        Item {
            id: attachStrip
            width: parent.width
            height: root.attachedImages.length > 0 ? 64 : 0
            visible: root.attachedImages.length > 0
            clip: true

            Behavior on height {
                NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
            }

            ListView {
                id: attachList
                anchors.fill: parent
                anchors.leftMargin: Math.max(Theme.spacingS, (parent.width - root.contentWidth) / 2)
                anchors.rightMargin: Math.max(Theme.spacingS, (parent.width - root.contentWidth) / 2)
                anchors.topMargin: 4
                anchors.bottomMargin: 4
                orientation: ListView.Horizontal
                spacing: Theme.spacingXS
                model: root.attachedImages
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                delegate: Rectangle {
                    width: 56
                    height: 56
                    radius: Math.max(4, Theme.cornerRadius / 2)
                    color: Theme.surfaceContainerHighest
                    border.width: 1
                    border.color: Theme.outlineMedium
                    clip: true

                    Image {
                        anchors.fill: parent
                        anchors.margins: 1
                        source: "file://" + modelData.path
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        cache: false
                    }

                    Rectangle {
                        anchors.top: parent.top
                        anchors.right: parent.right
                        anchors.margins: 2
                        width: 16
                        height: 16
                        radius: 8
                        color: removeMouse.containsMouse ? Theme.error : Qt.rgba(0, 0, 0, 0.55)

                        DankIcon {
                            anchors.centerIn: parent
                            name: "close"
                            size: 10
                            color: "white"
                        }

                        MouseArea {
                            id: removeMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.removeAttachment(index)
                        }
                    }
                }
            }
        }

        // ═══════════════════════════════════════════════════════
        //  INPUT ROW
        // ═══════════════════════════════════════════════════════

        Item {
            id: inputRowWrap
            width: parent.width
            // Bottom inset so the centered input floats off the window edge.
            height: inputRow.height + Theme.spacingM

            Rectangle {
                id: inputRow
                width: root.contentWidth
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.top
                height: Math.min(140, Math.max(44, chatInput.implicitHeight + 20))
                color: Theme.surfaceContainerHigh
                radius: Theme.cornerRadius
                border.width: 1
                border.color: chatInput.activeFocus ? Theme.primary : Theme.outlineMedium

                Behavior on height {
                    NumberAnimation { duration: 80; easing.type: Easing.OutCubic }
                }

            Rectangle {
                id: inputField
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.right: sendButton.left
                anchors.margins: Theme.spacingXS
                anchors.rightMargin: Theme.spacingXS
                color: Theme.surfaceContainerHighest
                radius: Theme.cornerRadius
                border.width: chatInput.activeFocus ? 1 : 0
                border.color: Theme.primary

                Flickable {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.spacingS
                    anchors.rightMargin: Theme.spacingS
                    anchors.topMargin: 6
                    anchors.bottomMargin: 6
                    contentWidth: width
                    contentHeight: chatInput.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    TextEdit {
                        id: chatInput
                        width: parent.width
                        color: Theme.surfaceText
                        font.pixelSize: Theme.fontSizeMedium
                        selectionColor: Theme.primary
                        selectedTextColor: Theme.onPrimary
                        wrapMode: TextEdit.Wrap
                        selectByMouse: true
                        textFormat: TextEdit.PlainText
                        tabStopDistance: 32

                        // Recompute slash suggestions as the command word is typed.
                        onTextChanged: {
                            root._slashSuggestions = Sc.suggest(chatInput.text)
                            root._slashSel = 0
                        }

                        Keys.onPressed: event => {
                            const sugg = root._slashSuggestions
                            const hasSugg = sugg && sugg.length > 0
                            if (hasSugg && event.key === Qt.Key_Down) {
                                event.accepted = true
                                root._slashSel = (root._slashSel + 1) % sugg.length
                                return
                            }
                            if (hasSugg && event.key === Qt.Key_Up) {
                                event.accepted = true
                                root._slashSel = (root._slashSel - 1 + sugg.length) % sugg.length
                                return
                            }
                            if (hasSugg && event.key === Qt.Key_Tab) {
                                event.accepted = true
                                root.applySlash(sugg[root._slashSel].name)
                                return
                            }
                            if (event.key === Qt.Key_Escape && hasSugg) {
                                event.accepted = true
                                root._slashSuggestions = []
                                return
                            }
                            if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                                && !(event.modifiers & Qt.ShiftModifier)) {
                                event.accepted = true
                                // A fully-typed command executes; a partial one
                                // first completes the highlighted suggestion.
                                if (Sc.parse(chatInput.text.trim())) {
                                    if (root.submit()) chatInput.text = ""
                                } else if (hasSugg) {
                                    root.applySlash(sugg[root._slashSel].name)
                                } else if (root.submit()) {
                                    chatInput.text = ""
                                }
                            } else if (event.key === Qt.Key_V
                                       && (event.modifiers & Qt.ControlModifier)) {
                                // Try to pull an image off the clipboard alongside
                                // the regular text paste. If the clipboard has only
                                // text the process exits 0 with empty stdout and
                                // nothing gets attached. Don't preventDefault — let
                                // Qt's text paste run too.
                                root.tryPasteImage()
                            }
                        }

                        StyledText {
                            visible: chatInput.text.length === 0 && !chatInput.activeFocus
                            text: "Message Hermes…   (Shift+Enter for newline)"
                            color: Theme.surfaceTextMedium
                            font.pixelSize: Theme.fontSizeMedium
                            anchors.left: parent.left
                            anchors.top: parent.top
                        }
                    }
                }
            }

            Rectangle {
                id: sendButton
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.rightMargin: Theme.spacingXS
                anchors.bottomMargin: Theme.spacingXS
                width: hermesService.isRunning ? 72 : 36
                height: 36
                radius: height / 2
                color: {
                    if (hermesService.isRunning) return Theme.error
                    if (chatInput.text.trim()) return Theme.primary
                    return Theme.surfaceVariant
                }

                Behavior on color { ColorAnimation { duration: 160 } }

                // Expanding "ping" ring while a run is active.
                Rectangle {
                    anchors.centerIn: parent
                    width: parent.width
                    height: parent.height
                    radius: height / 2
                    color: "transparent"
                    border.width: 2
                    border.color: Theme.error
                    visible: hermesService.isRunning
                    z: -1
                    SequentialAnimation on opacity {
                        running: hermesService.isRunning
                        loops: Animation.Infinite
                        NumberAnimation { from: 0.55; to: 0; duration: 1000; easing.type: Easing.OutCubic }
                    }
                    SequentialAnimation on scale {
                        running: hermesService.isRunning
                        loops: Animation.Infinite
                        NumberAnimation { from: 0.85; to: 1.5; duration: 1000; easing.type: Easing.OutCubic }
                    }
                }

                Row {
                    anchors.centerIn: parent
                    spacing: 4

                    DankIcon {
                        name: hermesService.isRunning ? "stop" : "arrow_upward"
                        size: 20
                        color: {
                            if (hermesService.isRunning) return Theme.primaryText
                            if (chatInput.text.trim()) return Theme.primaryText
                            return Theme.surfaceTextMedium
                        }
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    StyledText {
                        visible: hermesService.isRunning
                        text: "Stop"
                        color: Theme.primaryText
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Medium
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (hermesService.isRunning) {
                            hermesService.stopRun()
                        } else if (root.submit()) {
                            chatInput.text = ""
                        }
                    }
                }

                Behavior on width {
                    NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
                }
            }
            }

            // ── Slash-command autocomplete dropdown ────────────
            Rectangle {
                id: slashPopup
                visible: root._slashSuggestions.length > 0 && chatInput.activeFocus
                width: root.contentWidth
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: inputRow.top
                anchors.bottomMargin: Theme.spacingXS
                height: visible ? slashCol.height + Theme.spacingXS * 2 : 0
                radius: Theme.cornerRadius
                color: Theme.surfaceContainerHigh
                border.width: 1
                border.color: Theme.outlineMedium

                Column {
                    id: slashCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.topMargin: Theme.spacingXS

                    Repeater {
                        model: root._slashSuggestions
                        delegate: Rectangle {
                            width: slashCol.width
                            height: 30
                            color: index === root._slashSel ? Theme.primaryBackground : "transparent"

                            Row {
                                anchors.fill: parent
                                anchors.leftMargin: Theme.spacingM
                                anchors.rightMargin: Theme.spacingM
                                spacing: Theme.spacingS

                                StyledText {
                                    id: slashName
                                    text: "/" + modelData.name + (modelData.arg ? " " + modelData.arg : "")
                                    color: Theme.primary
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.family: "monospace"
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                StyledText {
                                    text: modelData.desc
                                    color: Theme.surfaceTextMedium
                                    font.pixelSize: Theme.fontSizeSmall - 1
                                    elide: Text.ElideRight
                                    width: parent.width - slashName.width - Theme.spacingS
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onEntered: root._slashSel = index
                                onClicked: { root.applySlash(modelData.name); chatInput.forceActiveFocus() }
                            }
                        }
                    }
                }
            }

            // ── Transient command-result toast ─────────────────
            Rectangle {
                id: toast
                property string text: ""
                property bool shown: false
                width: root.contentWidth
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: inputRow.top
                anchors.bottomMargin: Theme.spacingS
                height: toastText.implicitHeight + Theme.spacingM * 2
                radius: Theme.cornerRadius
                color: Theme.surfaceContainerHighest
                border.width: 1
                border.color: Theme.outlineMedium
                opacity: shown ? 1 : 0
                visible: opacity > 0
                Behavior on opacity { NumberAnimation { duration: 160 } }

                StyledText {
                    id: toastText
                    anchors.centerIn: parent
                    width: parent.width - Theme.spacingL * 2
                    text: toast.text
                    color: Theme.surfaceText
                    font.pixelSize: Theme.fontSizeSmall
                    font.family: toast.text.indexOf("\n") >= 0 ? "monospace" : Qt.application.font.family
                    wrapMode: Text.Wrap
                    horizontalAlignment: toast.text.indexOf("\n") >= 0 ? Text.AlignLeft : Text.AlignHCenter
                }

                MouseArea { anchors.fill: parent; onClicked: toast.shown = false }
                Timer { id: toastTimer; onTriggered: toast.shown = false }
            }
        }
    }

    // ═══════════════════════════════════════════════════════════
    //  MESSAGE DELEGATE COMPONENTS
    // ═══════════════════════════════════════════════════════════

    // ── User Message ───────────────────────────────────────────
    Component {
        id: userMsgComponent
        UserMessage {
            msg: parent.msg
            rowIndex: parent.msgIndex
            hermesService: root.hermesService
            chat: root
        }
    }

    // ── Assistant Message ──────────────────────────────────────
    Component {
        id: assistantMsgComponent
        AssistantMessage {
            msg: parent.msg
            rowIndex: parent.msgIndex
            hermesService: root.hermesService
            chat: root
        }
    }

    // ── Thinking (collapsible reasoning card, webui-style) ─────
    // Mirrors hermes-webui's thinking card: a primary-tinted disclosure row
    // with a lightbulb + "Thinking" label, copy button and rotating chevron;
    // the body holds the full reasoning trace in small muted monospace,
    // scrollable past ~260px. Collapsed by default, including while the
    // reasoning is still streaming into it.
    Component {
        id: thinkingMsgComponent
        ThinkingCard {
            msg: parent.msg
            rowIndex: parent.msgIndex
            hermesService: root.hermesService
        }
    }

    // ── Tool Call ──────────────────────────────────────────────
    // Claude-style activity card: icon · tool name · muted one-line preview,
    // click to expand the full arguments. Status (spinner / check) only shows
    // while running — once completed, the header is quiet, matching the
    // Claude web UI where the result card carries the success affordance.
    Component {
        id: toolCallMsgComponent
        ToolCallCard {
            msg: parent.msg
            rowIndex: parent.msgIndex
            hermesService: root.hermesService
        }
    }

    // ── Tool Result (collapsible card) ─────────────────────────
    // Claude-web-style: header shows icon · friendly label · chevron, with
    // a right-side count ("9 results", "+3 −1", "12 lines", …). For
    // web_search-shaped payloads the body is a tidy list (favicon · title ·
    // url); anything else falls back to the JsonView tree. A small "Done"
    // pill at the bottom of the expanded body signals the run is finished.
    Component {
        id: toolResultMsgComponent
        ToolResultCard {
            msg: parent.msg
            rowIndex: parent.msgIndex
            hermesService: root.hermesService
        }
    }

    // ── Approval Message ───────────────────────────────────────
    Component {
        id: approvalMsgComponent
        ApprovalCard {
            msg: parent.msg
            hermesService: root.hermesService
        }
    }
}
