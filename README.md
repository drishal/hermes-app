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
- **Theming** from any base16/base24 scheme — drop a
  `~/.config/HermesApp/theme.yaml`, point `themePath` at a stylix-managed
  scheme in your dotfiles, or let the home-manager module write
  `~/.config/HermesApp/colors.json`; falls back to a bundled gruvbox scheme
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
`hermesHome` (default `~/.hermes`); only _runs_ go over HTTP/SSE.

## Configuration

| Setting         | Default                 | Notes                                              |
| --------------- | ----------------------- | -------------------------------------------------- |
| `apiBaseUrl`    | `http://127.0.0.1:8642` | Gateway base URL                                   |
| `apiKey`        | _(empty)_               | Falls back to `API_SERVER_KEY` in `~/.hermes/.env` |
| `hermesHome`    | `~/.hermes`             | Holds `.env` and the sqlite session DB             |
| `selectedModel` | _(gateway default)_     | Model id passed to `/v1/runs`                      |

Stored at `~/.config/HermesApp/settings.json`.

### Theming

The UI palette comes from a base16/base24 scheme, resolved at startup in this
order (first hit wins; absent → the gruvbox defaults in `qs/Common/Theme.qml`):

1. **`themePath`** in `settings.json` — point it anywhere, e.g. a stylix-managed
   scheme YAML inside your dotfiles. `.json` is read as a base16 object, anything
   else as a scheme YAML.
2. **`~/.config/HermesApp/theme.yaml`** (or `.yml`) — just drop a standard
   base16/base24 scheme file here (the tinted-theming `palette:` form or the
   legacy flat form, with or without `#`).
3. **`~/.config/HermesApp/colors.json`** — what the NixOS/Home-Manager module
   writes from the active stylix scheme (keys `base00`–`base0E`, hex strings).

Theme uses base16 slots `base00`–`base05`, `08`, `0A`–`0E`; base24's extra
slots are ignored. Parsing needs no YAML dependency. Applied at startup —
restart to pick up a change.

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

MIT — see [LICENSE](LICENSE). The bundled Material Symbols Rounded font
(`assets/fonts/MaterialSymbolsRounded.ttf`) is © Google LLC and distributed
under the Apache 2.0 license; full terms are in the same file.
