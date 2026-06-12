# Hermes Agent

A standalone desktop chat app for a local [Hermes](https://github.com/) coding-agent
gateway. PySide6 (Qt Quick) front end, in-process Python backend (httpx for
HTTP/SSE, sqlite3 for the session DB) — no Quickshell, no subprocess shelling,
no desktop-shell dependency.

![Hermes Agent](assets/screenshot.png)

## Features

- Streaming chat over the Hermes gateway's `/v1/runs` SSE API
- Live reasoning traces in collapsible "thinking" cards
- Tool calls / results as tidy cards with a colour-coded, collapsible JSON tree
- Markdown rendering: tables, fenced code blocks (Pygments highlighting), links
- Approvals (allow once / session / deny) inline
- Session sidebar, command palette (Ctrl+K), tray icon + notifications
- Theme derived from a host palette (e.g. stylix) via `~/.config/HermesApp/colors.json`,
  falling back to a bundled gruvbox scheme

## Run

Needs Python 3 with `PySide6`, `httpx`, and `pygments`:

```bash
python3 main.py
```

The app talks to `http://127.0.0.1:8642` by default and auto-discovers the
gateway API key from `~/.hermes/.env`. Both are configurable in Settings.

## Theming

If `~/.config/HermesApp/colors.json` exists (keys `base00`–`base0E`), the app
maps it onto its Theme tokens at startup. NixOS/Home-Manager users can generate
it from the active stylix scheme; everyone else gets the gruvbox defaults.

## Layout

```
main.py             entry point — loads QML, wires backend + context properties
backend/            Python: hermes_backend (SSE), db (sqlite), tray, platform bridge
components/         QML views — ChatArea, MessageContent, cards, JsonView, …
qml/                Window + HermesService coordinator
qs/Common,Widgets/  Theme singleton + small shared widgets
services/           pure-JS helpers (markdown/json/tool formatting)
assets/fonts/       Material Symbols
```
