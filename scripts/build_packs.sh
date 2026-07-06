#!/usr/bin/env bash
# Build reproducible UNSIGNED language packs inside the pinned pack-builder image.
# ============================================================================
# The image (tools/Dockerfile, published to GHCR) pins every byte-affecting
# input, so the SAME command yields byte-identical output locally, in CI, and
# for the offline signer. Signing is a SEPARATE, offline, per-locale step — see
# README.md; nothing here ever signs or commits.
#
# Where the packs land (--out-dir), in precedence order:
#   1. an explicit --out-dir argument
#   2. $SS_APP_DIR/src/lang-packs   (when SS_APP_DIR is set) — the LOCAL-DEV
#      source-of-truth push: this checkout builds straight into the app, and the
#      app runtime + app tests + device deployers all read that one location.
#   3. <repo>/build                 (gitignored fallback)
#
# Which image is used, in precedence order:
#   1. $IMAGE                        (explicit override, verbatim)
#   2. the pinned GHCR toolchain image (pulled) — the normal path
#   3. a local `docker build` of tools/ — the fallback when the image can't be
#      pulled (not published yet / offline / air-gapped signer), or when forced.
#
# Usage:
#   scripts/build_packs.sh                          # all locales -> $SS_APP_DIR/src/lang-packs or build/
#   scripts/build_packs.sh --out-dir /tmp/packs     # custom output dir
#   scripts/build_packs.sh --locale hi --locale th  # subset (args pass to build_fontpacks.py)
#   scripts/build_packs.sh --catalogs-only          # just recompile .mo catalogs
#   scripts/build_packs.sh --skip-if-built          # no-op if the out-dir already has packs
#   REBUILD_IMAGE=1 scripts/build_packs.sh          # force a clean local `docker build --no-cache`
#   LOCAL_IMAGE=1   scripts/build_packs.sh          # build tools/ locally instead of pulling GHCR
#   IMAGE=ghcr.io/…@sha256:… scripts/build_packs.sh # use a specific (digest-pinned) image
#
# All arguments EXCEPT --skip-if-built are forwarded to tools/build_fontpacks.py
# (with the resolved --out-dir substituted). --skip-if-built is a build_packs.sh-level
# guard: it makes the whole thing a no-op when the output dir is already populated, so a
# warm checkout needs neither the submodule nor Docker on subsequent runs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# The pinned GHCR toolchain image: the build ENVIRONMENT only (ubuntu + fontTools /
# uharfbuzz / PyICU / Pillow + the pinned-LVGL lv_shape oracle). It bakes NO translations
# or pack content. Published manually from tools/Dockerfile via the publish-builder-image
# workflow; pin it by DIGEST here once published (ghcr.io/…@sha256:…) so consumers rebuild
# against an exact environment. Until then the :latest tag resolves, and the local-build
# fallback below covers a pull miss.
BUILDER_IMAGE="${BUILDER_IMAGE:-ghcr.io/kdmukai-bot/seedsigner-langpack-builder:latest}"
IMAGE="${IMAGE:-$BUILDER_IMAGE}"

# ----------------------------------------------------------------------------
# Parse args: pull our own --skip-if-built and --out-dir out of the stream (we
# re-add a resolved --out-dir at the end), forward everything else verbatim.
# ----------------------------------------------------------------------------
SKIP_IF_BUILT=0
OUT_DIR=""          # empty == the user did not pass --out-dir
FWD_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-if-built)  SKIP_IF_BUILT=1; shift ;;
    --out-dir)        OUT_DIR="$2"; shift 2 ;;
    --out-dir=*)      OUT_DIR="${1#--out-dir=}"; shift ;;
    *)                FWD_ARGS+=("$1"); shift ;;
  esac
done

# Resolve the output dir (see precedence in the header). A live pack checkout with
# SS_APP_DIR set pushes straight into the app; otherwise packs land in the gitignored
# build/ dir. Then normalize to an absolute host path for mkdir + the --skip-if-built guard.
if [ -z "$OUT_DIR" ]; then
  if [ -n "${SS_APP_DIR:-}" ]; then
    OUT_DIR="$SS_APP_DIR/src/lang-packs"
  else
    OUT_DIR="$REPO_ROOT/build"
  fi
fi
case "$OUT_DIR" in /*) : ;; *) OUT_DIR="$REPO_ROOT/$OUT_DIR" ;; esac

# --skip-if-built: idempotent bootstrap. If the output already holds packs, do nothing
# (before the submodule check + image acquisition, so a warm checkout needs neither).
if [ "$SKIP_IF_BUILT" = 1 ] && [ -n "$(ls -A "$OUT_DIR" 2>/dev/null)" ]; then
  echo "==> --skip-if-built: $OUT_DIR already populated; skipping build."
  exit 0
fi

# The .po source is a submodule; a bare checkout has an empty dir.
if [ ! -e "$REPO_ROOT/seedsigner-translations/l10n" ]; then
  echo "ERROR: seedsigner-translations submodule not checked out. Run:" >&2
  echo "  git -C \"$REPO_ROOT\" submodule update --init" >&2
  exit 1
fi

# ----------------------------------------------------------------------------
# Acquire the image: prefer the pinned GHCR image (pull); fall back to a local
# `docker build` of tools/. build_local also serves REBUILD_IMAGE (clean rebuild)
# and LOCAL_IMAGE (never touch the registry, e.g. an air-gapped signer).
# ----------------------------------------------------------------------------
build_local() {
  echo "==> Building pack-builder image locally from tools/ -> ${IMAGE}"
  local flags=()
  [ "${REBUILD_IMAGE:-0}" = "1" ] && flags+=(--no-cache)
  docker build "${flags[@]}" -t "$IMAGE" "$REPO_ROOT/tools"
}

if [ "${REBUILD_IMAGE:-0}" = "1" ] || [ "${LOCAL_IMAGE:-0}" = "1" ]; then
  build_local
elif docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "==> Using cached image ${IMAGE}"
else
  echo "==> Pulling toolchain image ${IMAGE}"
  if ! docker pull "$IMAGE"; then
    echo "==> Pull failed (image not published yet / offline); building tools/ locally instead."
    build_local
  fi
fi

echo "==> Building packs (unsigned) -> ${OUT_DIR}"
# Run as the host user so output isn't root-owned. The repo is bind-mounted read-write at
# /work (CWD); the output dir is mounted at a FIXED /work-independent path (/out) so it can
# live OUTSIDE the repo (e.g. the app's src/lang-packs) and still be writable in-container.
# Mounting at a constant /out also keeps the container-side out path identical regardless of
# the host location, which the determinism gate relies on. LVGL_ROOT + PYTHONHASHSEED are
# baked into the image ENV.
mkdir -p "$OUT_DIR"
docker run --rm \
  -v "$REPO_ROOT":/work -w /work \
  -v "$OUT_DIR":/out \
  -u "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  "$IMAGE" \
  python3 tools/build_fontpacks.py "${FWD_ARGS[@]}" --out-dir /out

echo ""
echo "==> Done. Unsigned packs are in: ${OUT_DIR}"
echo "    Sign offline before copying into signed-packs/<locale>/ (see README.md)."
