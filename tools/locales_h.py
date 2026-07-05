#!/usr/bin/env python3
"""
locales.h reader — the Python half of the master locale config.

`locales.h` (repo root) is an X-macro table that is the SINGLE SOURCE OF TRUTH for
locale->{font, chain, size, shaping, endonym} policy. C #includes it; this module
parses the same `SS_LOCALE(...)` / `SS_DISPLAY_PROFILE(...)` lines so the pack
builder never compiles the render layer to learn policy.

This REPLACES `screenshot_gen --dump-locales`: it exposes exactly the two views the
builder consumed from that dump —

  * manifest_locales()        -> {locale: {source_family, chain, unicode_range,
                                            shaping, script, rtl}}     (policy)
  * endonym_sizes_by_locale() -> {locale: [(height, button_px), ...]}  (endonym sizes)

plus endonyms() (native names, formerly read from supported_locales.json).

Deliberately dependency-free (stdlib only) and side-effect-free, so it stays cheap
enough for the --catalogs-only fast path to import without pulling in anything.
"""

import os
import re

# locales.h lives at the repo root; this reader lives in tools/.
DEFAULT_CONFIG = os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "locales.h"))

# A row is on ONE line: `SS_LOCALE(...)`. Anchored at start-of-line so the doc
# comment (which prefixes the signature with " * ") and `#undef SS_LOCALE` never
# match. `.*` is greedy → captures up to the row's final ')'.
_LOCALE_RE  = re.compile(r"^\s*SS_LOCALE\((.*)\)\s*$")
_PROFILE_RE = re.compile(r"^\s*SS_DISPLAY_PROFILE\(([^)]*)\)\s*$")
_BASE_RE    = re.compile(r"^\s*#define\s+SS_ENDONYM_BUTTON_BASE_(PRIMARY|FALLBACK)\s+(\d+)")


def _tokenize_args(s):
    """Split a C macro arg list into ('str'|'tok', value) tokens, honoring
    double-quoted strings — a unicode_range like "U+01A0-01A1,U+0300-036F" carries
    commas that a naive split would break on."""
    args = []
    i, n = 0, len(s)
    while i < n:
        while i < n and s[i] in " \t\r\n":
            i += 1
        if i >= n:
            break
        if s[i] == '"':
            # Quoted string: collect until the closing quote, then skip to the comma.
            j = i + 1
            buf = []
            while j < n and s[j] != '"':
                if s[j] == "\\" and j + 1 < n:
                    buf.append(s[j + 1]); j += 2
                else:
                    buf.append(s[j]); j += 1
            args.append(("str", "".join(buf)))
            j += 1  # closing quote
            while j < n and s[j] != ",":
                j += 1
            i = j + 1
        else:
            # Bare token (e.g. ChainRole::Primary, true, false): up to the next comma.
            j = i
            while j < n and s[j] != ",":
                j += 1
            args.append(("tok", s[i:j].strip()))
            i = j + 1
    return args


def read_config(config_path=None):
    """Parse locales.h into {'locales': [...], 'profiles': [...], 'button_base': {...}}.

    Each locale dict: {locale, source_family, chain('primary'|'fallback'),
    unicode_range(None if empty), rtl, shaping, script(None if empty), endonym}.
    Profiles: [{width, height, px_multiplier}]. button_base: {'primary':px,'fallback':px}.
    """
    path = config_path or DEFAULT_CONFIG
    locales, profiles, button_base = [], [], {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            m = _LOCALE_RE.match(line)
            if m:
                a = [v for _kind, v in _tokenize_args(m.group(1))]
                # id, source_family, chain, unicode_range, rtl, shaping, script, endonym
                locales.append({
                    "locale":        a[0],
                    "source_family": a[1],
                    "chain":         "primary" if "Primary" in a[2] else "fallback",
                    "unicode_range": a[3] or None,
                    "rtl":           a[4] == "true",
                    "shaping":       a[5] == "true",
                    "script":        a[6] or None,
                    "endonym":       a[7],
                })
                continue
            m = _PROFILE_RE.match(line)
            if m:
                w, h, mult = (int(x.strip()) for x in m.group(1).split(","))
                profiles.append({"width": w, "height": h, "px_multiplier": mult})
                continue
            m = _BASE_RE.match(line)
            if m:
                button_base[m.group(1).lower()] = int(m.group(2))
    return {"locales": locales, "profiles": profiles, "button_base": button_base}


def manifest_locales(config_path=None, only=None):
    """locale -> {source_family, chain, unicode_range, shaping, script, rtl},
    restricted to `only` if given. Drop-in for the old `--dump-locales` reader:
    px sizes are irrelevant to subsetting (one .ttf serves every size); unicode_range
    selects block-range vs corpus mode; shaping/script/rtl select complex-script mode."""
    out = {}
    for loc in read_config(config_path)["locales"]:
        name = loc["locale"]
        if only and name not in only:
            continue
        out[name] = {
            "source_family": loc["source_family"],
            "chain":         loc["chain"],
            "unicode_range": loc["unicode_range"],
            "shaping":       loc["shaping"],
            "script":        loc["script"],
            "rtl":           loc["rtl"],
        }
    return out


def endonyms(config_path=None):
    """locale -> native display name (endonym). Formerly supported_locales.json."""
    return {loc["locale"]: loc["endonym"] for loc in read_config(config_path)["locales"]}


def endonym_sizes_by_locale(config_path=None):
    """locale -> [(height_key, button_px), ...] sorted, deduped by height.

    Mirrors the render layer's px_scale(base, mult) = int(base * mult / 100). The
    endonym image is rendered at the locale's BUTTON px for each distinct display
    height so image rows match live-text rows. Primary packs take the legibility-
    bumped button base (20); Fallback packs match the baked baseline (18)."""
    cfg = read_config(config_path)
    base = cfg["button_base"]
    # Distinct display heights -> px_multiplier (first profile at a height wins;
    # 240x240 and 320x240 share height 240, hence the dedupe).
    heights = {}
    for p in cfg["profiles"]:
        heights.setdefault(str(p["height"]), p["px_multiplier"])
    out = {}
    for loc in cfg["locales"]:
        b = base[loc["chain"]]
        sizes = {h: int(b * mult / 100.0) for h, mult in heights.items()}
        out[loc["locale"]] = sorted(sizes.items())
    return out


if __name__ == "__main__":
    # Smoke/inspection: `python3 locales_h.py [locales.h]` dumps the parsed views.
    import json
    import sys
    cfg = sys.argv[1] if len(sys.argv) > 1 else None
    print(json.dumps({
        "manifest_locales": manifest_locales(cfg),
        "endonyms": endonyms(cfg),
        "endonym_sizes_by_locale": {k: dict(v) for k, v in endonym_sizes_by_locale(cfg).items()},
    }, ensure_ascii=False, indent=2))
