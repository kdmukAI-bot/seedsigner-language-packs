#!/usr/bin/env bash
# Build reproducible UNSIGNED language packs inside the pinned pack-builder image.
# ============================================================================
# The image (tools/Dockerfile) pins every byte-affecting input, so the SAME
# command yields byte-identical output locally, in CI, and for the offline signer.
# Output lands in build/ (gitignored). Signing is a SEPARATE, offline, per-locale
# step — see README.md; nothing here ever signs or commits.
#
# Usage:
#   scripts/build_packs.sh                          # all locales -> build/
#   scripts/build_packs.sh --out-dir /tmp/packs     # custom output dir
#   scripts/build_packs.sh --locale hi --locale th  # subset (args pass to build_fontpacks.py)
#   scripts/build_packs.sh --catalogs-only          # just recompile .mo catalogs
#   scripts/build_packs.sh --skip-if-built           # no-op if the out-dir already has packs
#   REBUILD_IMAGE=1 scripts/build_packs.sh          # force `docker build --no-cache`
#
# All arguments EXCEPT --skip-if-built are forwarded verbatim to tools/build_fontpacks.py.
# --skip-if-built is a build_packs.sh-level guard: it makes the whole thing a no-op when the
# output dir is already populated, so consumers can safely "build-on-first-use, else skip"
# (bootstrap the packs once, then this is free on subsequent runs — no Docker needed).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE="${IMAGE:-seedsigner-langpack-builder:latest}"

# Split our own --skip-if-built out of the args forwarded to build_fontpacks.py, and track
# the effective --out-dir so the guard knows what to check (mirrors build_fontpacks.py's
# default of <repo>/build; a relative --out-dir resolves under the repo root == the /work mount).
SKIP_IF_BUILT=0
OUT_DIR="$REPO_ROOT/build"
FWD_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-if-built)  SKIP_IF_BUILT=1; shift ;;
    --out-dir)        OUT_DIR="$2"; FWD_ARGS+=("$1" "$2"); shift 2 ;;
    --out-dir=*)      OUT_DIR="${1#--out-dir=}"; FWD_ARGS+=("$1"); shift ;;
    *)                FWD_ARGS+=("$1"); shift ;;
  esac
done
case "$OUT_DIR" in /*) : ;; *) OUT_DIR="$REPO_ROOT/$OUT_DIR" ;; esac

# --skip-if-built: idempotent bootstrap. If the output already holds packs, do nothing
# (before the submodule check + Docker build, so a warm checkout needs neither).
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

echo "==> Ensuring pack-builder image ${IMAGE}"
BUILD_FLAGS=()
[ "${REBUILD_IMAGE:-0}" = "1" ] && BUILD_FLAGS+=(--no-cache)
docker build "${BUILD_FLAGS[@]}" -t "$IMAGE" "$REPO_ROOT/tools"

echo "==> Building packs (unsigned)"
# Run as the host user so output isn't root-owned. The repo is bind-mounted at
# /work; LVGL_ROOT + PYTHONHASHSEED are baked into the image ENV.
docker run --rm \
  -v "$REPO_ROOT":/work -w /work \
  -u "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  "$IMAGE" \
  python3 tools/build_fontpacks.py "${FWD_ARGS[@]}"

echo ""
echo "==> Done. Unsigned packs are in the build output dir (default: build/)."
echo "    Sign offline before copying into signed-packs/<locale>/ (see README.md)."
