#!/usr/bin/env python3
"""
Parity gate: every font-pack locale declared in locales.h must have a built pack
with a manifest.json in the output dir, and the manifest must self-identify with
the right locale + policy (chain / rtl / shaping). Fails loudly on any gap so a
locale can never silently ship without its pack.

Usage:  python3 scripts/check_parity.py [--out-dir build] [--config locales.h]

(The baked-Latin catalog-only locales are intentionally NOT checked here: they carry
no manifest.json — the app knows them from its own ALL_LOCALES — so they are not in
locales.h. This gate covers exactly the locales.h font-pack set.)
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)) + "/../tools")
import locales_h  # noqa: E402


def main():
    here = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out-dir", default=os.path.join(here, "build"))
    ap.add_argument("--config", default=os.path.join(here, "locales.h"))
    args = ap.parse_args()

    policy = locales_h.manifest_locales(args.config)
    if not policy:
        print("FAIL: locales.h declared no locales.", file=sys.stderr)
        return 1

    problems = []
    for loc, pol in sorted(policy.items()):
        mpath = os.path.join(args.out_dir, loc, "manifest.json")
        if not os.path.exists(mpath):
            problems.append(f"{loc}: missing pack ({mpath})")
            continue
        with open(mpath, encoding="utf-8") as f:
            m = json.load(f)
        if m.get("locale") != loc:
            problems.append(f"{loc}: manifest locale mismatch ({m.get('locale')!r})")
        if m.get("chain") != pol["chain"]:
            problems.append(f"{loc}: manifest chain {m.get('chain')!r} != policy {pol['chain']!r}")
        if bool(m.get("shaping")) != bool(pol["shaping"]):
            problems.append(f"{loc}: manifest shaping {m.get('shaping')!r} != policy {pol['shaping']!r}")
        if bool(m.get("rtl")) != bool(pol["rtl"]):
            problems.append(f"{loc}: manifest rtl {m.get('rtl')!r} != policy {pol['rtl']!r}")

    if problems:
        print("PARITY FAIL:", file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        return 1

    print(f"PARITY OK: {len(policy)} locales.h locale(s) each have a matching pack "
          f"in {args.out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
