"""base16/base24 scheme parsing + palette resolution, headless (no Qt, no deps).

Run:  python3 tests/theme_palette_test.py
"""
from __future__ import annotations

import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from backend import theme_palette as tp  # noqa: E402

# Modern tinted-theming format (nested under `palette:`, quoted, #-prefixed).
MODERN = """\
system: "base16"
name: "Gruvbox dark, medium"
author: "dawikur"
variant: "dark"
palette:
  base00: "#282828"
  base01: "#3c3836"
  base05: "#d4be98"
  base0D: "#7daea3"
  base0E: "#d3869b"
"""

# Legacy base16 format (flat, unquoted, no leading '#').
LEGACY = """\
scheme: "Gruvbox dark"
author: "someone"
base00: 282828
base01: 3c3836
base05: d4be98
base0d: 7daea3
"""

# base24 adds base10..base17 — must still parse (and not choke).
BASE24 = """\
system: "base24"
palette:
  base00: "#0d0e1c"
  base07: "#ffffff"
  base10: "#0a0b16"
  base17: "#e0def4"
"""


def test_parse_modern():
    pal = tp.parse_scheme_yaml(MODERN)
    assert pal["base00"] == "#282828", pal
    assert pal["base0D"] == "#7daea3", pal
    assert pal["base05"] == "#d4be98", pal
    assert len(pal) == 5, pal


def test_parse_legacy():
    pal = tp.parse_scheme_yaml(LEGACY)
    assert pal["base00"] == "#282828", pal
    # case of the slot letter is preserved as written
    assert pal["base0d"] == "#7daea3", pal
    assert "author" not in str(pal)


def test_parse_base24():
    pal = tp.parse_scheme_yaml(BASE24)
    assert pal["base10"] == "#0a0b16", pal
    assert pal["base17"] == "#e0def4", pal
    assert pal["base07"] == "#ffffff", pal


def test_normalize_json():
    pal = tp._normalize({"base00": "282828", "base01": "#3C3836", "name": "x", "bad": "zzz"})
    assert pal == {"base00": "#282828", "base01": "#3c3836"}, pal


def test_load_palette_order(tmpdir):
    cfg = os.path.join(tmpdir, "HermesApp")
    os.makedirs(cfg)
    # Redirect module paths into the temp config dir.
    tp.CONFIG_DIR = cfg
    tp.SETTINGS_PATH = os.path.join(cfg, "settings.json")

    # Only colors.json present → it wins.
    with open(os.path.join(cfg, "colors.json"), "w") as f:
        json.dump({"base00": "#111111", "base05": "#222222"}, f)
    assert tp.load_palette()["base00"] == "#111111"

    # Drop a theme.yaml → overrides colors.json.
    with open(os.path.join(cfg, "theme.yaml"), "w") as f:
        f.write(MODERN)
    assert tp.load_palette()["base00"] == "#282828"

    # themePath in settings → highest priority.
    custom = os.path.join(tmpdir, "my-scheme.yml")
    with open(custom, "w") as f:
        f.write(LEGACY.replace("282828", "abcdef"))
    with open(tp.SETTINGS_PATH, "w") as f:
        json.dump({"themePath": custom}, f)
    assert tp.load_palette()["base00"] == "#abcdef"


if __name__ == "__main__":
    test_parse_modern()
    test_parse_legacy()
    test_parse_base24()
    test_normalize_json()
    with tempfile.TemporaryDirectory() as d:
        test_load_palette_order(d)
    print("theme_palette_test: OK")
