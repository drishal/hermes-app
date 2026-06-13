"""Resolve the UI colour palette from a base16/base24 scheme.

Theme.qml expects a dict of ``{"base00": "#rrggbb", …}`` (base16 slots) exposed
as the ``stylixColors`` context property; absent, it keeps its bundled gruvbox
defaults. This module finds that palette from, in order:

  1. ``themePath`` in settings.json — point it anywhere (e.g. a stylix-managed
     scheme inside ~/dotfiles). ``.json`` is read as a base16 JSON object,
     anything else as a base16/base24 scheme YAML.
  2. ``~/.config/HermesApp/theme.{yaml,yml}`` — drop a scheme file here.
  3. ``~/.config/HermesApp/colors.json`` — what the home-manager/stylix module
     generates.

Standard base16/base24 scheme files (the tinted-theming format, modern
``palette:`` map or the legacy flat form, with or without ``#`` and quotes) are
parsed without a YAML dependency — only ``baseNN: <6 hex>`` lines matter.
"""
from __future__ import annotations

import json
import os
import re

CONFIG_DIR = os.path.expanduser("~/.config/HermesApp")
SETTINGS_PATH = os.path.join(CONFIG_DIR, "settings.json")

# baseNN: "#rrggbb" / 'rrggbb' / #rrggbb — quotes, leading '#' and the
# enclosing `palette:` indentation are all optional.
_LINE = re.compile(
    r"""^\s*["']?(base[0-9A-Fa-f]{2})["']?\s*:\s*["']?\#?([0-9A-Fa-f]{6})(?![0-9A-Fa-f])""",
)


def _normalize(d) -> dict | None:
    """Keep only baseNN keys, coerce every value to ``#rrggbb``."""
    if not isinstance(d, dict):
        return None
    out = {}
    for k, v in d.items():
        if not isinstance(k, str) or not re.fullmatch(r"base[0-9A-Fa-f]{2}", k):
            continue
        s = str(v).strip().lstrip("#")
        if re.fullmatch(r"[0-9A-Fa-f]{6}", s):
            out[k] = "#" + s.lower()
    return out or None


def parse_scheme_yaml(text: str) -> dict | None:
    """Parse a base16/base24 scheme (YAML, any common dialect) to a palette."""
    out = {}
    for line in text.splitlines():
        m = _LINE.match(line)
        if m:
            out[m.group(1)] = "#" + m.group(2).lower()
    return out or None


def _load_one(path: str) -> dict | None:
    try:
        with open(path) as f:
            text = f.read()
    except OSError:
        return None
    ext = os.path.splitext(path)[1].lower()
    if ext == ".json":
        try:
            pal = _normalize(json.loads(text))
        except ValueError:
            pal = None
        # A mislabelled .json that's actually a scheme YAML still parses.
        return pal or parse_scheme_yaml(text)
    # YAML/anything else — and fall back to JSON if it happens to be one.
    pal = parse_scheme_yaml(text)
    if pal:
        return pal
    try:
        return _normalize(json.loads(text))
    except ValueError:
        return None


def _theme_path_setting() -> str:
    try:
        with open(SETTINGS_PATH) as f:
            return str(json.load(f).get("themePath") or "")
    except (OSError, ValueError):
        return ""


def load_palette() -> dict | None:
    """Return the resolved palette dict, or None to keep gruvbox defaults."""
    candidates = []
    tp = _theme_path_setting()
    if tp:
        candidates.append(os.path.expanduser(tp))
    candidates += [
        os.path.join(CONFIG_DIR, "theme.yaml"),
        os.path.join(CONFIG_DIR, "theme.yml"),
        os.path.join(CONFIG_DIR, "colors.json"),
    ]
    for path in candidates:
        pal = _load_one(path)
        if pal:
            return pal
    return None


if __name__ == "__main__":  # pragma: no cover - manual probe
    print(load_palette())
