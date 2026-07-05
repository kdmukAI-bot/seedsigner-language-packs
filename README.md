# seedsigner-language-packs

Reproducible, signable **language packs** for SeedSigner — the runtime i18n assets
(subset fonts, pre-shaped glyph runs, native-name endonym images, compiled `.mo`
catalogs) that every non-English locale needs on both the Pi Zero and the ESP32-S3.

This repo is **fully self-sufficient**: it owns the pack format, the locale policy,
the producer tooling, and the source fonts. It does **not** depend on the screens
render layer or any other SeedSigner repo — its only submodule is
[`seedsigner-translations`](https://github.com/kdmukAI-bot/seedsigner-translations)
(the `.po` source). LVGL — needed only for the `lv_shape` Arabic/Persian oracle — is
pinned inside the pack-builder Docker image, not submoduled.

```
seedsigner-language-packs/
├── locales.h                 # MASTER locale policy — X-macro table. C #includes it;
│                             #   tools/locales_h.py parses it. Replaces
│                             #   `screenshot_gen --dump-locales`.
├── fonts/                    # source TTFs (OpenSans + Noto families)
├── tools/                    # the producer: build_fontpacks.py + Dockerfile + shaper/…
├── scripts/                  # build_packs.sh (docker wrapper) + parity/verify helpers
├── seedsigner-translations/  # submodule — .po catalogs (pinned)
├── signed-packs/<locale>/    # THE DELIVERABLE — signed release packs (committed by hand)
└── build/                    # gitignored — on-the-fly UNSIGNED build output
```

## What a pack is

One self-contained, distributable unit per locale — uniform layout, contents vary
by what the locale needs:

```
<locale>/
    manifest.json           # self-describing: fonts/endonym/catalog + sha256s
    <locale>.ttf            # subset font (CJK/shaping)  |  <locale>_{regular,semibold}.ttf (block-range Latin)
    runs.bin                # pre-shaped glyph runs (complex scripts: hi/th/ur)
    endonym_240/320/480.bin # native-name images per display height (SSA8)
    LC_MESSAGES/messages.mo # compiled translation catalog (gettext-standard path)
```

Locale → pack contents is decided entirely by `locales.h` policy + the `.po` set:

| Locale type | Pack contents |
|---|---|
| Non-Latin / shaping (ja ko zh hi th ur fa el ru …) | subset font (+ `runs.bin`) + endonym + manifest + `messages.mo` |
| Latin-script font (vi) | subset font + endonym + manifest + `messages.mo` |
| Baked-Latin (es fr de cs …) | `messages.mo` only (baked floor renders it; live-text name) |
| English | *no pack* (source language) |

## Build packs (dev)

Everything runs inside the pinned Docker image, so you need only Docker + git.

```sh
git submodule update --init            # fetch the .po source
scripts/build_packs.sh                 # all locales -> build/
scripts/build_packs.sh --locale hi --locale th   # a subset
scripts/build_packs.sh --catalogs-only # just recompile .mo (fast; translations change often)
REBUILD_IMAGE=1 scripts/build_packs.sh # force a clean image rebuild
```

Output is **unsigned** and lands in `build/` (gitignored). Dev consumers rebuild on
the fly; nothing here signs or commits automatically.

## Reproducibility (the linchpin)

The signing model relies on **byte-identical rebuilds**: anyone can rebuild a pack
from the pinned inputs and compare its hash to the one a signed pack embeds — content
integrity with **no key**. Every byte-affecting input is therefore pinned:

- **Base image** — `ubuntu:24.04` by **digest** (`tools/Dockerfile`); fixes system
  libicu (PyICU word segmentation), freetype/fontconfig, the toolchain.
- **Python toolchain** — exact pins in `tools/requirements.txt`. `uharfbuzz` bundles
  its own libharfbuzz (pins shaping); `Pillow` bundles libraqm (pins endonym bytes).
- **LVGL** — pinned SHA `85aa60d…` (v9.5.0) in the image, matching the device/screens
  LVGL so the `lv_shape` `fa` oracle mirrors on-device shaping.
- **fontTools `--no-recalc-timestamp`** — never stamp `head.modified` with "now"
  (the #1 churn risk); `PYTHONHASHSEED=0`; deterministic JSON key order.

CI (`.github/workflows/packs.yml`) enforces this: it builds **twice** and `diff -rq`s
the outputs (determinism gate) and checks that every `locales.h` locale produced a
pack (parity gate). It runs with a read-only token and **never signs or commits**.

### Reproduce a release (input closure)

To independently rebuild-and-verify, pin the full closure:

1. this repo at the signed release ref (gives `locales.h`, `fonts/`, `tools/`),
2. the `seedsigner-translations` submodule SHA it points at,
3. the Docker base-image **digest** + `requirements.txt` pins + LVGL SHA (all in the repo),

then `scripts/build_packs.sh` and compare against the signed pack's embedded content
hash. (Publishing the exact image digest + tool versions per release is tracked under
"open" below.)

## Signing & release (DEFERRED — open sub-design)

The delivery model is decided; the **signing scheme is not yet** (algorithm, key
management, content-hash format, on-device bootloader path). Until it lands:

- `signed-packs/` stays **empty** — no packs are committed.
- Dev + CI build unsigned packs on the fly.

The intended flow, once the scheme is chosen:

1. Build a reproducible **unsigned** pack (`scripts/build_packs.sh`).
2. Embed a **content hash of the unsigned bytes** in the pack.
3. **Sign that hash offline** (air-gapped key, per-locale cadence) and **commit** the
   signed pack under `signed-packs/<locale>/` at a release tag.
4. Independent verification is two separate checks: (a) rebuild → hash → compare
   (keyless content integrity); (b) verify the signature over that hash (authenticity).
   On-device, the secure bootloader does (b) via the `ss_pack_provider` chokepoint.

## Delivery (copy step)

Consumers **copy** `signed-packs/<locale>/` into their runtime path — they never build
or submodule the screens toolchain:

- **seedsigner (app):** copy → `src/lang-packs` (gitignored, staged; zero app-code change).
- **Pi (raspi-lvgl):** copy → `src/lang-packs` beside the `.so` (drops the old workstation
  path + device symlink).
- **ESP32 (micropython-builder):** `sd_format_push.py` sources packs here (submodule) and
  stages them onto the microSD.

The pinned version is the git ref / release tag. Dev rebuilds on the fly.

## Adding / changing a locale

1. Edit `locales.h` (add an `SS_LOCALE(...)` row; add the source TTF to `fonts/` if new).
2. `scripts/build_packs.sh --locale <new>` and eyeball `build/<new>/`.
3. Re-sign + release (per cadence).
4. Downstream: re-vendor `locales.h` into the screens repo if policy changed, and bump
   the pack pin in each consumer.

`locales.h` is the **single source of truth** for locale→font policy — one file the C
render layer `#include`s and this repo's Python reader parses, with no codegen. It
replaced `screenshot_gen --dump-locales`; the reader is verified against that dump's
historical output.
