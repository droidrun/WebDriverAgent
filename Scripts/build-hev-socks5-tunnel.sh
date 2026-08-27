#!/bin/bash
# Copyright (c) 2026-present, Droidrun.
# All rights reserved.
#
# This source code is licensed under the BSD-style license found in the
# LICENSE file in the root directory of this source tree.

# Build ThirdParty/HevSocks5Tunnel.xcframework from the hev-socks5-tunnel
# git submodule (ThirdParty/hev-socks5-tunnel, pinned by SHA).
#
# Trimmed from upstream build-apple.sh: only the slices WebDriverAgent needs
# (iphoneos-arm64, iphonesimulator-arm64+x86_64). The result is consumed by
# the WebDriverAgentTunnel packet-tunnel appex; see docs/socks5-tunnel.md.
#
# The output is gitignored. Skips the build when the xcframework already
# matches the current submodule SHA + script contents (stamp file).
#
# Usage: Scripts/build-hev-socks5-tunnel.sh [--force]

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUBMODULE_DIR="$ROOT_DIR/ThirdParty/hev-socks5-tunnel"
OUTPUT="$ROOT_DIR/ThirdParty/HevSocks5Tunnel.xcframework"
STAMP_FILE="$ROOT_DIR/ThirdParty/.hev-socks5-tunnel.stamp"
MIN_IOS="15.0"
JOBS="$(sysctl -n hw.ncpu)"

if [ ! -f "$SUBMODULE_DIR/src/hev-main.h" ]; then
    echo "error: hev-socks5-tunnel submodule is missing or not initialized." >&2
    echo "       run: git submodule update --init --recursive" >&2
    exit 1
fi

SCRIPT_SHA=$(shasum -a 256 "$0" | cut -d' ' -f1)

# build_static runs `make clean` in the shared submodule checkout, so two concurrent
# preparations (e.g. two WDA sessions starting at once) would delete each other's archives
# mid-compile or mid-libtool and produce nondeterministic failures or a corrupt xcframework.
# Serialize across processes, and hold the lock across the stamp check too: the loser then
# re-reads the stamp the winner just wrote and exits early instead of rebuilding.
LOCK_FILE="$ROOT_DIR/ThirdParty/.hev-socks5-tunnel.lock"
LOCK_WAIT_SECONDS="${HEV_SOCKS5_LOCK_WAIT_SECONDS:-900}"
BUILD_DIR=""

cleanup()
{
    [ -n "$BUILD_DIR" ] && rm -rf "$BUILD_DIR"
    return 0
}
trap cleanup EXIT

# Keep one inode permanently and let the kernel release its advisory lock when this process exits.
# Unlike stale-directory reclamation, a waiter can never rename or remove another builder's live
# lock between observing and acquiring it. Descriptor 9 remains open for the rest of the script.
exec 9>"$LOCK_FILE"
if ! /usr/bin/lockf -t "$LOCK_WAIT_SECONDS" 9; then
    echo "error: timed out after ${LOCK_WAIT_SECONDS}s waiting for $LOCK_FILE" >&2
    exit 1
fi

# The npm tarball ships the engine sources without Git metadata. `git -C` must not be allowed to
# walk up into the consuming application's repository, where every application commit would look
# like a new hev revision. Only trust Git when its top-level is the vendored engine itself;
# otherwise hash every shipped input while excluding the build products made by this script.
SUBMODULE_REALPATH="$(cd "$SUBMODULE_DIR" && pwd -P)"
SUBMODULE_GIT_TOPLEVEL="$(git -C "$SUBMODULE_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$SUBMODULE_GIT_TOPLEVEL" ] \
    && [ "$(cd "$SUBMODULE_GIT_TOPLEVEL" && pwd -P)" = "$SUBMODULE_REALPATH" ]; then
    SUBMODULE_SHA=$(git -C "$SUBMODULE_DIR" rev-parse HEAD)
    SOURCE_ID="$SUBMODULE_SHA"
else
    SOURCE_ID=$(
        cd "$SUBMODULE_DIR"
        find . -name .git -prune -o -type f \
            ! -path './bin/*' ! -path './build/*' \
            ! -path './third-part/hev-task-system/bin/*' \
            ! -path './third-part/hev-task-system/build/*' \
            ! -path './third-part/lwip/bin/*' ! -path './third-part/lwip/build/*' \
            ! -path './third-part/yaml/bin/*' ! -path './third-part/yaml/build/*' \
            -print0 \
          | LC_ALL=C sort -z \
          | xargs -0 shasum -a 256 \
          | shasum -a 256 | cut -d' ' -f1
    )
    SUBMODULE_SHA="tree-$SOURCE_ID"
fi
STAMP="${SOURCE_ID}-${SCRIPT_SHA}-${MIN_IOS}"

if [ "${1:-}" != "--force" ] && [ -d "$OUTPUT" ] && [ -f "$STAMP_FILE" ] \
    && [ "$(cat "$STAMP_FILE")" = "$STAMP" ]; then
    echo "HevSocks5Tunnel.xcframework is up to date ($SUBMODULE_SHA); skipping build"
    exit 0
fi

BUILD_DIR=$(mktemp -d -t hev-socks5-tunnel-build)

# Other-platform sources (linux/windows/jni/...) compile to empty objects on
# iOS, producing harmless 'has no symbols' archive warnings; drop just those.
filter_no_symbols()
{
    grep -v 'has no symbols' >&2 || true
}

# build_static <sdk> <arch> <version-min-flag>
build_static()
{
    local SDK="$1" ARCH="$2" MIN_FLAG="$3"
    echo "building libhev-socks5-tunnel for $SDK/$ARCH"
    make -C "$SUBMODULE_DIR" clean >/dev/null
    make -C "$SUBMODULE_DIR" -j"$JOBS" \
         PP="xcrun --sdk $SDK --toolchain $SDK clang" \
         CC="xcrun --sdk $SDK --toolchain $SDK clang" \
         CFLAGS="-arch $ARCH $MIN_FLAG" \
         LFLAGS="-arch $ARCH $MIN_FLAG -Wl,-Bsymbolic-functions" static \
         >/dev/null 2> >(filter_no_symbols)
    mkdir -p "$BUILD_DIR/$SDK-$ARCH"
    # The 'static' target leaves one archive per component; merge them.
    libtool -static -o "$BUILD_DIR/$SDK-$ARCH/libhev-socks5-tunnel.a" \
            "$SUBMODULE_DIR/bin/libhev-socks5-tunnel.a" \
            "$SUBMODULE_DIR/third-part/lwip/bin/liblwip.a" \
            "$SUBMODULE_DIR/third-part/yaml/bin/libyaml.a" \
            "$SUBMODULE_DIR/third-part/hev-task-system/bin/libhev-task-system.a" \
            2> >(filter_no_symbols)
    make -C "$SUBMODULE_DIR" clean >/dev/null
}

build_static iphoneos arm64 "-miphoneos-version-min=$MIN_IOS"
build_static iphonesimulator arm64 "-mios-simulator-version-min=$MIN_IOS"
build_static iphonesimulator x86_64 "-mios-simulator-version-min=$MIN_IOS"

mkdir -p "$BUILD_DIR/iphonesimulator-universal"
lipo -create \
     "$BUILD_DIR/iphonesimulator-arm64/libhev-socks5-tunnel.a" \
     "$BUILD_DIR/iphonesimulator-x86_64/libhev-socks5-tunnel.a" \
     -output "$BUILD_DIR/iphonesimulator-universal/libhev-socks5-tunnel.a"

INCLUDE_DIR="$BUILD_DIR/include"
mkdir -p "$INCLUDE_DIR/HevSocks5Tunnel"
cp "$SUBMODULE_DIR/src/hev-main.h" "$INCLUDE_DIR/HevSocks5Tunnel/"
cp "$SUBMODULE_DIR/module.modulemap" "$INCLUDE_DIR/HevSocks5Tunnel/"

rm -rf "$OUTPUT"
xcodebuild -create-xcframework \
    -library "$BUILD_DIR/iphoneos-arm64/libhev-socks5-tunnel.a" -headers "$INCLUDE_DIR" \
    -library "$BUILD_DIR/iphonesimulator-universal/libhev-socks5-tunnel.a" -headers "$INCLUDE_DIR" \
    -output "$OUTPUT"

echo "$STAMP" > "$STAMP_FILE"
echo "built $OUTPUT from hev-socks5-tunnel $SUBMODULE_SHA"
