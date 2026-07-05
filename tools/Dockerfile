# Pack-builder image for seedsigner-language-packs.
# =============================================================================
# Encapsulates the ENTIRE offline pack toolchain so `scripts/build_packs.sh`
# produces BYTE-IDENTICAL unsigned packs locally, in CI, and for the offline
# signer. Reproducibility is the linchpin of the signing model (rebuild -> hash
# -> compare, keyless — independent of the signature), so every input that
# affects output bytes is pinned:
#
#   * base image   pinned by DIGEST (below) — fixes system libicu (PyICU word
#                  segmentation for Thai/…), freetype/fontconfig, and the toolchain.
#   * pip packages pinned exactly in requirements.txt. uharfbuzz bundles its own
#                  libharfbuzz (pins the shaping engine); Pillow bundles libraqm
#                  (pins endonym-image rendering) — both independent of system libs.
#   * LVGL         cloned at a pinned SHA (v9.5.0) for the lv_shape `fa` oracle —
#                  MUST match the device/screens LVGL, since lv_shape mirrors LVGL's
#                  on-device Arabic/Persian presentation-form shaping.
#
# It does NOT build screenshot_gen: locale policy comes from locales.h. Build
# context is this tools/ directory (COPY requirements.txt).

FROM ubuntu:24.04@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90

ENV DEBIAN_FRONTEND=noninteractive

# System toolchain: build-essential + cmake for the lv_shape oracle; git to clone
# LVGL; libicu-dev to build PyICU against the (base-image-pinned) system ICU;
# libraqm0 as a fallback layout engine for Pillow (the pinned Pillow wheel also
# bundles its own). python3 + pip for the Python tooling.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake git ca-certificates pkg-config \
        python3 python3-pip python3-dev \
        libicu-dev libraqm0 \
    && rm -rf /var/lib/apt/lists/*

# Pinned LVGL v9.5.0 for the lv_shape Arabic/Persian shaping oracle. Cloned INTO
# the image (not a repo submodule) and exposed via $LVGL_ROOT; build_fontpacks.py
# passes it straight through to the shaper's CMake (-DLVGL_ROOT). Matches the
# screens repo's third_party/lvgl pin so on-device shaping is mirrored exactly.
ARG LVGL_SHA=85aa60d18b3d5e5588d7b247abf90198f07c8a63
RUN git clone --filter=blob:none https://github.com/lvgl/lvgl.git /opt/lvgl \
    && git -C /opt/lvgl checkout ${LVGL_SHA} \
    && rm -rf /opt/lvgl/.git
ENV LVGL_ROOT=/opt/lvgl

# Pinned Python toolchain (fontTools / uharfbuzz / PyICU / Pillow / numpy).
COPY requirements.txt /tmp/requirements.txt
RUN pip3 install --no-cache-dir --break-system-packages -r /tmp/requirements.txt

# Reproducibility: stable hash seed for any dict/set ordering in the tooling.
ENV PYTHONHASHSEED=0

WORKDIR /work
