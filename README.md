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
├── signed-packs/             # future signed-release home — EMPTY until signing lands (§ Signing)
└── build/                    # gitignored — on-the-fly UNSIGNED build output
```

> **Nothing built is ever committed** (dev or signed-yet). Reproducibility comes from pinned
> inputs + the determinism gate, not from committed blobs. In **local dev this checkout is the
> source of truth**: build straight into the app with
> `scripts/build_packs.sh --out-dir "$SS_APP_DIR/src/lang-packs"` (see below).

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

`scripts/build_packs.sh` runs the builder inside the pinned toolchain image, which it **pulls
from GHCR** by default — the **public**, **digest-pinned** `ghcr.io/kdmukai-bot/seedsigner-langpack-builder`
(the digest is pinned in `BUILDER_IMAGE`) — so there's no reinstalling the shaping stack each run.
If the image can't be pulled (offline / air-gapped signer) it **falls back to a local `docker build`
of `tools/`**. Docker gives byte-identical,
reproducible output; it is **optional in local dev** only in the sense that you can instead run
the builder natively (`python3 tools/build_fontpacks.py …`) if you already have the shaping
toolchain installed. Reproducible/signed builds require the image.

```sh
git submodule update --init            # fetch the .po source (pinned)
scripts/build_packs.sh                 # all locales -> $SS_APP_DIR/src/lang-packs, else build/
scripts/build_packs.sh --out-dir "$SS_APP_DIR/src/lang-packs"   # explicit local-dev push into the app
scripts/build_packs.sh --locale hi --locale th   # a subset
scripts/build_packs.sh --catalogs-only # just recompile .mo (fast; translations change often)
scripts/build_packs.sh --skip-if-built # no-op if the out-dir already has packs
REBUILD_IMAGE=1 scripts/build_packs.sh # force a clean local `docker build --no-cache`
LOCAL_IMAGE=1   scripts/build_packs.sh # build tools/ locally instead of pulling GHCR
```

Output is **unsigned** and lands in `--out-dir`. When you don't pass `--out-dir` it defaults to
**`$SS_APP_DIR/src/lang-packs`** (when `SS_APP_DIR` is set) so **this checkout is the single
source of truth** — build here → the app runtime, the app's language tests, and the device
deployers (which read the app's `src/lang-packs`) all see it at once. With no `SS_APP_DIR` it
falls back to the gitignored `build/`. Different translation state? Check out a different ref in
the `seedsigner-translations` submodule and rebuild.

### Publishing the toolchain image (manual)

The image is published **manually** from the pinned `tools/Dockerfile` via the
`publish-builder-image` workflow (Actions → *Run workflow*) — the one place with `packages:write`.
It tags `:latest` + the commit SHA and prints the pushed **digest** to the run summary. Pin that
digest in `BUILDER_IMAGE` (`scripts/build_packs.sh`) and in the screens/app CI so every consumer
rebuilds against the exact environment. **CI** (this repo's + screens' + the app's) pulls the
image rather than reinstalling the shaping stack each run.

The image is **currently published and public**, and `BUILDER_IMAGE` pins its digest. Re-run the
workflow and re-pin the new digest only when the toolchain changes (`tools/Dockerfile` or
`tools/requirements.txt`).

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

## Delivery

**Local dev (the common case):** this checkout builds *into the app* —
`build_packs.sh --out-dir "$SS_APP_DIR/src/lang-packs"`. Every consumer then reads the app's
`src/lang-packs`:

- **seedsigner (app):** reads `src/lang-packs` (gitignored, zero app-code change). It does **not**
  submodule or build packs — this checkout pushes into it.
- **Pi (raspi-lvgl)** and **ESP32 (micropython-builder):** their deploy scripts point only at the
  **app** (`SS_APP_DIR`) and copy `$SS_APP_DIR/src/lang-packs` to the device. They know nothing
  about this repo. Absent packs = a valid **English-only** deploy.

**Production (deferred):** once signing lands, consumers obtain **signed** packs at a release tag
and land them in the same `src/lang-packs` — signed-vs-dev is invisible downstream because the
*location* is the contract.

## Self-describing packs (policy travels in the manifest)

Each pack's `manifest.json` carries **everything the render layer needs at runtime** —
`chain`, `rtl`, `shaping`, and (via `chain`) per-role sizing — plus endonym/catalog/sha256s.
The render layer (screens) is migrating to read this per-pack instead of a vendored copy of
`locales.h`, so **adding or changing a locale needs no screens recompile** — drop the pack, the
host discovers it. Keep the manifest complete for every locale; it is the render-time contract.

## Adding / changing a locale

1. Edit `locales.h` (add an `SS_LOCALE(...)` row; add the source TTF to `fonts/` if new).
2. `scripts/build_packs.sh --locale <new>` and eyeball the built `<new>/` pack in the out-dir
   (confirm `manifest.json` carries the policy fields).
3. Re-sign + release (per cadence).
4. Downstream: **nothing** once the manifest-driven migration lands (the host discovers the new
   pack from its manifest — no screens recompile, no re-vendor). During the migration, screens
   still vendors a transitional copy of `locales.h`; re-vendor it if policy changed.

`locales.h` is the **single source of truth** for locale→font policy — this repo's C `lv_shape`
oracle `#include`s it and `tools/locales_h.py` parses it (no codegen). It replaced
`screenshot_gen --dump-locales`; the reader is verified against that dump's historical output.
The builder stamps this policy into each pack's `manifest.json`, which is what consumers read.
