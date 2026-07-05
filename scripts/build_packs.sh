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
#   REBUILD_IMAGE=1 scripts/build_packs.sh          # force `docker build --no-cache`
#
# All arguments are forwarded verbatim to tools/build_fontpacks.py.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE="${IMAGE:-seedsigner-langpack-builder:latest}"

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
  python3 tools/build_fontpacks.py "$@"

echo ""
echo "==> Done. Unsigned packs are in the build output dir (default: build/)."
echo "    Sign offline before copying into signed-packs/<locale>/ (see README.md)."
