# Hermes Agent — contributor & agent guide

Read this before editing, especially the **Layout gotchas** — the QML rendering
path has several non-obvious failure modes that were expensive to find.

## What this is

A PySide6 (Qt Quick) desktop chat client for a local Hermes coding-agent
gateway. The UI is QML; the backend is in-process Python (`httpx` for HTTP/SSE,
`sqlite3` for reading history). It runs straight from this working tree —
`python3 main.py` — so QML/Python edits take effect on the next launch with no
build step.

In the author's NixOS setup, a Home-Manager module (`hermes-app.nix`, in the
separate `dotfiles` repo) wraps it: provides the Python env, points `appRoot` at
this checkout, generates `~/.config/HermesApp/colors.json` from stylix, and adds
a desktop entry + single-instance guard. This repo has no Nix of its own.

## Architecture

```
QML views ──bind──► ListModels ──mirrored by──► HermesService.qml
                                                      ▲ signals
                                                      │
                                          HermesBackend (Python QObject)
                                            │ stdio JSON-RPC │ sqlite3 / httpx
                                            ▼               ▼
                                      hermes-acp     ~/.hermes DB + gateway
                                      (runs)         (history + run fallback)
```

- **`HermesBackend`** (`backend/hermes_backend.py`) owns all I/O and state. It
  emits row-ops as signals: `sessionsReset(list)`, `messagesReset(list)`,
  `messageAppended(var)`, `messageUpdated(int, var)`, plus
  `runStarted/Completed/Failed`. State (connected, isRunning, currentModel,
  lastUsage, …) is exposed as `Property` with `*Changed` notify signals.
- **`HermesService.qml`** is a thin coordinator: it mirrors those backend
  signals into two `ListModel`s (`sessionList`, `messageList`) and re-exposes
  the property/method surface the views were written against. Views never touch
  the backend directly — they bind to `hermesService`.
- **Context properties** set in `main.py`: `hermesBackend`, `Platform`
  (`platform_bridge.py` — clipboard / image paste / Pygments), and
  `stylixColors` (a `base00…` palette from `theme_palette.load_palette()`, or
  `null` — see **Theming**).
- **Message rows** are plain dicts with a stable set of roles (see
  `db._row`). `type` selects the delegate in `ChatArea.qml`'s `Loader`:
  `user | assistant | thinking | tool_call | tool_result | approval`. Each
  delegate is its own file (`UserMessage`, `AssistantMessage`, `ThinkingCard`,
  `ToolCallCard`, `ToolResultCard`, `ApprovalCard`); `ChatArea` keeps only thin
  Loader-wrapper `Component`s that pass the row + deps each needs (`msg`,
  `rowIndex`, `hermesService`, and `chat` — the ChatArea root — for the two that
  call `editMessage`/`retryMessage`). `tests/chat_delegates_test.py` renders one
  of each type and asserts no warnings + no row overlap; run it after touching
  any delegate.
- **Slash commands** (`/new`, `/clear`, `/stop`, `/retry`, `/model`, `/history`,
  `/settings`, `/help`) are intercepted in the composer and run locally — never
  sent to the agent — modelled on hermes-webui's client-side registry. The
  catalog/parser is `services/slashCommands.js` (single source of truth, also
  feeds the autocomplete dropdown + `/help`); side effects are dispatched in
  `ChatArea.runCommand()` since they need `hermesService` + UI signals
  (`settingsRequested`/`paletteRequested`/`modelChangeRequested` bubble to
  `ChatContent`). Feedback is a transient in-composer toast — **not** a row
  injected into `messageList` (that would desync the backend↔QML row indices
  `resendFrom`/`messageUpdated` depend on). `/clear` and `/reset` alias `/new`
  for the same reason: a view-only clear can't be done safely here.

### Run transport: ACP primary, gateway fallback

History (`sessionList`, `messageList`) is read **directly from the Hermes
sqlite DB** under `hermesHome`. Runs go over **ACP** (Agent Client Protocol):
`backend/acp_client.py` spawns the `hermes-acp` binary (settings key
`acpCommand`) and speaks newline-delimited JSON-RPC on its stdio —
`initialize` → `session/new`-or-`session/load` → `session/prompt` (blocks for
the turn), `session/cancel` to stop.

ACP is the *only* hermes surface that streams reasoning live: the gateway's
`/v1/runs` never registers the agent's `reasoning_callback`, so thinking
tokens die in-process there and `reasoning.available` only fires post-hoc.

**`session/update` notifications handled** (`_on_acp_update`):
`agent_thought_chunk` → thinking row (delta-accumulated per phase),
`agent_message_chunk` → assistant delta, `tool_call` → tool row (correlated by
`toolCallId`; title `"name: preview"` is split for the chip),
`tool_call_update` → status/result (result text appends below the command
preview). `session/request_permission` (a JSON-RPC *request*) becomes the
approval row; the card's once/session/deny is mapped onto the request's
option kinds (`allow_once`/`allow_always`/`reject_*`) and answered by id.

Update routing is gated on `_accepting` and `_acpRunSession` — `session/load`
history replay and updates for detached/foreign sessions are dropped. A
truncated session (edit/retry) is marked *diverged* and runs through the
gateway instead, because the ACP agent keeps the full server-side history
while the gateway path replays `conversation_history` explicitly.

The old gateway path (`POST /v1/runs` + SSE `GET /v1/runs/{id}/events`,
`_handle_event`) is kept as automatic fallback when `hermes-acp` is missing
or a session can't be attached. `GET /health` still drives the connected dot
(a live ACP process also counts). Auth for the HTTP calls:
`Authorization: Bearer <key>` — the Settings field or `API_SERVER_KEY` from
`~/.hermes/.env`.

## Threading & process model

- SSE/HTTP runs on **daemon `threading.Thread`s** (`_spawn`). Daemon so a blocked
  SSE read never holds up process exit. **Do not** use `QThreadPool` — it waits
  for runnables on shutdown and the long SSE job would hang exit.
- Signals must reach the GUI thread safely: daemon threads enqueue closures via
  `_gui(fn)` and a GUI-thread timer drains them (`_drain_gui_queue`). Never emit
  a signal that mutates a `ListModel` directly from a worker thread.
- `main.py` resets `SIGINT`/`SIGTERM` to `SIG_DFL` **after** constructing
  `QApplication`, so `kill`/`timeout` terminate cleanly (otherwise the
  single-instance guard stays stuck on a lingering process).
- Uses `QApplication` (not `QGuiApplication`) so `QSystemTrayIcon` works.

## Layout gotchas (the important part)

The chat is a `ListView` of variable-height delegates loaded via `Loader`. Two
classes of bug recur here; both are now worked around, don't reintroduce them.

1. **QML positioners are unreliable in the delegate Loader chain.** A `Column`/
   `Row`'s `implicitHeight` is computed during *polish*, which doesn't settle
   correctly through `Loader → external Component`. Symptoms: children stuck at
   `y=0` (overlapping) or a height frozen at a stale value. **Fix pattern:** stack
   children manually — a `Repeater` + a coalesced `_relayout()` that assigns each
   child's `y` and sums the total into a `_stackedHeight` property used as
   `implicitHeight`. See `MessageContent.qml`, `TableBlock.qml`, `JsonView.qml`.
   Card heights are computed arithmetically (`header + expanded body`), never
   from a positioner.

2. **`ListView` `add`/`displaced` transitions desync the layout.** When a
   transition is mid-flight and a delegate's height *settles asynchronously*
   (markdown/table re-measure), ListView locks a position from the pre-settle
   height and never corrects it — even `forceLayout()` won't. So: **no
   `displaced` transition** (neighbours snap), and the `add` fade is gated on
   `hermesService.isRunning` (it must not fire on session loads — delegates are
   created lazily, after the append loop and any `bulkLoading` flag finish).

Supporting rules:

- A delegate whose height settles late must nudge a **coalesced**
  `ListView.forceLayout()` via `onHeightChanged: Qt.callLater(_resettle)`.
  `_resettle` also re-pins to the bottom when auto-follow is on.
- **Run completion** re-segments the streamed plain-text reply into
  markdown/tables/code (heights jump), so it triggers the same `_resettle` as a
  session load (`messagesLoaded` / `runCompleted`).
- **Auto-follow** pins to the newest content only while near the bottom; never
  call `positionViewAtEnd()` from `onContentHeightChanged` unguarded (it
  instantiates delegates → changes height → infinite relayout → UI freeze). Use
  the re-entrancy-guarded `_pinBottom()`.

## ListModel reactivity

- **Every role a delegate binds to must exist when the row is appended.** A
  `ListModel.setProperty` that *adds* a new role does **not** re-evaluate
  bindings created before it existed. This is why `db._row` defaults include
  `expanded` (the collapse state) and all tool fields — omitting one silently
  breaks the card's expand toggle.
- `dynamicRoles: true` is set on `messageList`, but the rule above still holds.
- Delegates capture the row as `property var msg: parent.msg` (the whole model
  object). Sub-property reads (`msg.expanded`) *are* reactive — but only because
  the role pre-exists.

## Theming

`import QtCore` / `StandardPaths` is **not available** in the PySide6 build this
targets — importing it breaks the `Theme` singleton and cascades to every
component. So colours come in through a context property: `backend/theme_palette.py`
(`load_palette()`) resolves a base16/base24 palette and `main.py` sets it as
`stylixColors`; `Theme.qml` reads that root context property in
`Component.onCompleted` and overrides its gruvbox defaults. Keep `Theme` free of
QtCore.

Palette resolution order (first hit wins): `themePath` in `settings.json` →
`~/.config/HermesApp/theme.{yaml,yml}` → `~/.config/HermesApp/colors.json`. The
scheme parser is regex-only (no YAML dep) — it just picks `baseNN: <6 hex>`
lines, so the tinted-theming `palette:` form and the legacy flat form both work.
`stylixColors` is still the context-property name (it's just a `base00…` dict);
`Theme.qml` is unchanged. Applied at startup only.

## Provider / content quirks

- **Reasoning echo:** GLM-5 / M3-style models re-emit just-streamed visible
  content back through `reasoning.available`. `_add_thinking` drops text that
  matches recent assistant content; genuine reasoning still shows. Contiguous
  reasoning accumulates into **one** thinking row per phase (a new row starts
  only after content or a tool call interleaves).
- **Tool-result envelope:** results arrive wrapped in
  `<untrusted_tool_result source="…">` + a security preamble. `jsonFormat.unwrap`
  strips it and surfaces the source as a chip.
- **Live thinking:** the thinking card auto-opens while it's the newest row
  during an active run, then falls back to its persisted `expanded` state.

## Testing without a display

There's no display in CI / headless shells; use Qt's offscreen platform.

```bash
QT_QPA_PLATFORM=offscreen python3 tests/smoke_test.py
QT_QPA_PLATFORM=offscreen python3 tests/acp_test.py   # ACP client + row mapping
```

`tests/acp_test.py` drives `AcpClient` against a fake `hermes-acp` subprocess
(real pipes/framing, no model) and the backend's update→row mapping directly.

The smoke test loads the full QML tree against stub context properties and fails
on any QML warning or load error. For layout work, the effective pattern is a
`QQuickView` (so delegates actually render) populated with a stub
`hermesService` + `ListModel`, then walk `ListView.contentItem.children` and
assert no two `msgRow` delegates overlap (`row[i].y >= row[i-1].y + h - 1`).
Backend logic (e.g. `_add_thinking` accumulation/dedup) tests directly against
`HermesBackend` with `messageAppended`/`messageUpdated` connected to a list.

## Commit conventions

Match the existing history: lowercase, imperative, scope-prefixed.

```
hermes: render markdown tables in a dedicated TableBlock
hermes: fix row overlap on chat switch and window resize
```

Use a body only for non-obvious *why* (the diff shows the *what*). One logical
change per commit.
