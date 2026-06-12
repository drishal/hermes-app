# Hermes Agent

A standalone desktop chat app for a local [Hermes](https://github.com/) coding-agent
gateway. PySide6 (Qt Quick) front end, in-process Python backend — httpx for
HTTP/SSE, sqlite3 for reading the session history. No Quickshell, no subprocess
shelling for core features, no desktop-shell dependency.

## Features

- **Streaming chat** over the gateway's `/v1/runs` SSE API, with a live typing cursor
- **Reasoning traces** in collapsible "thinking" cards that auto-open while the
  model is reasoning, then fold away once the answer starts
- **Tool calls & results** as tidy cards — name, a one-line preview, status
  (spinner → duration), expanding to a colour-coded, collapsible **JSON tree**
- **Markdown**: tables (custom renderer), fenced code blocks (Pygments
  highlighting), inline code, links, lists, headings
- **Approvals** inline (allow once / allow for session / deny)
- **Session sidebar**, **command palette** (`Ctrl+K`), **tray icon** + desktop
  notifications when the window is unfocused
- **Theming** derived from a host palette (e.g. stylix) via
  `~/.config/HermesApp/colors.json`, falling back to a bundled gruvbox scheme
- **Image paste** — paste a screenshot to attach it to the next message

## Requirements

- Python 3.11+
- [`PySide6`](https://pypi.org/project/PySide6/) (Qt 6)
- [`httpx`](https://pypi.org/project/httpx/)
- [`pygments`](https://pypi.org/project/pygments/)
- A running Hermes gateway (defaults to `http://127.0.0.1:8642`)

```bash
pip install PySide6 httpx pygments
```

On NixOS you can get an environment without touching pip:

```bash
nix shell nixpkgs#python3 --command \
  python3 -c 'import PySide6'   # or use the wrapper from the dotfiles module
```

## Run

```bash
python3 main.py
```

The app talks to `http://127.0.0.1:8642` by default and **auto-discovers** the
gateway key from `API_SERVER_KEY` in `~/.hermes/.env` (sent as a
`Authorization: Bearer …` header). Both the URL and key are editable in
**Settings** (the gear in the sidebar); settings persist to
`~/.config/HermesApp/settings.json`.

Session and message history is read directly from the Hermes sqlite DB under
`hermesHome` (default `~/.hermes`); only *runs* go over HTTP/SSE.

## Configuration

| Setting        | Default                  | Notes                                            |
|----------------|--------------------------|--------------------------------------------------|
| `apiBaseUrl`   | `http://127.0.0.1:8642`  | Gateway base URL                                 |
| `apiKey`       | *(empty)*                | Falls back to `API_SERVER_KEY` in `~/.hermes/.env` |
| `hermesHome`   | `~/.hermes`              | Holds `.env` and the sqlite session DB           |
| `selectedModel`| *(gateway default)*      | Model id passed to `/v1/runs`                     |

Stored at `~/.config/HermesApp/settings.json`.

### Theming

If `~/.config/HermesApp/colors.json` exists (keys `base00`–`base0E`, hex
strings), the app maps it onto its `Theme` tokens at startup. NixOS/Home-Manager
users can generate it from the active stylix scheme; everyone else gets the
gruvbox defaults baked into `qs/Common/Theme.qml`.

## Project layout

```
main.py                 entry point — loads QML, wires backend + context properties
backend/
  hermes_backend.py     HermesBackend QObject — HTTP/SSE, settings, signals
  db.py                 read sessions/messages from the Hermes sqlite DB
  platform_bridge.py    clipboard, image paste, Pygments highlighting
  tray.py               system tray icon + notifications
  welcome.py            empty-chat dashboard (shells out to the `hermes` CLI)
qml/
  Window.qml            top-level window
  HermesService.qml     QML coordinator mirroring backend signals into ListModels
components/             views — ChatArea, MessageContent, cards, JsonView, …
qs/Common, qs/Widgets   Theme singleton + small shared widgets (DankIcon, StyledText)
services/               pure-JS helpers: markdownSegments, jsonFormat, toolFormat
assets/fonts/           Material Symbols Rounded
tests/                  offscreen smoke test
```

## Development

See **[CLAUDE.md](CLAUDE.md)** for the architecture, conventions, and the
(many, hard-won) layout gotchas — read it before touching the QML rendering
path.

Quick verification without a display:

```bash
QT_QPA_PLATFORM=offscreen python3 tests/smoke_test.py
```

## License

Personal project; no license declared yet. Ask before reuse.
