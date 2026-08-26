#!/bin/bash
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

# The npm tarball ships the engine sources without any Git metadata, so the submodule SHA is
# only available in a Git checkout. Fall back to hashing the source tree there, which keys the
# stamp on exactly what is about to be compiled either way.
if SUBMODULE_SHA=$(git -C "$SUBMODULE_DIR" rev-parse HEAD 2>/dev/null); then
    SOURCE_ID="$SUBMODULE_SHA"
else
    SOURCE_ID=$(find "$SUBMODULE_DIR/src" -type f -exec shasum -a 256 {} + \
                | sort | shasum -a 256 | cut -d' ' -f1)
    SUBMODULE_SHA="tree-$SOURCE_ID"
fi
SCRIPT_SHA=$(shasum -a 256 "$0" | cut -d' ' -f1)
STAMP="${SOURCE_ID}-${SCRIPT_SHA}-${MIN_IOS}"

# build_static runs `make clean` in the shared submodule checkout, so two concurrent
# preparations (e.g. two WDA sessions starting at once) would delete each other's archives
# mid-compile or mid-libtool and produce nondeterministic failures or a corrupt xcframework.
# Serialize across processes, and hold the lock across the stamp check too: the loser then
# re-reads the stamp the winner just wrote and exits early instead of rebuilding.
LOCK_DIR="$ROOT_DIR/ThirdParty/.hev-socks5-tunnel.lock"
LOCK_WAIT_SECONDS=900
LOCK_HELD=0
BUILD_DIR=""

cleanup()
{
    [ -n "$BUILD_DIR" ] && rm -rf "$BUILD_DIR"
    [ "$LOCK_HELD" = "1" ] && rm -rf "$LOCK_DIR"
    return 0
}
trap cleanup EXIT

# mkdir is atomic on every filesystem this runs on, which `[ -e ] && touch` is not.
waited=0
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    owner=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
        echo "removing a stale hev-socks5-tunnel build lock left by pid $owner" >&2
        rm -rf "$LOCK_DIR"
        continue
    fi
    if [ "$waited" -ge "$LOCK_WAIT_SECONDS" ]; then
        echo "error: timed out after ${LOCK_WAIT_SECONDS}s waiting for $LOCK_DIR" >&2
        echo "       remove it by hand if no other build is running" >&2
        exit 1
    fi
    [ "$waited" = "0" ] && echo "another hev-socks5-tunnel build is running; waiting for it"
    sleep 1
    waited=$((waited + 1))
done
LOCK_HELD=1
echo $$ > "$LOCK_DIR/pid"

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
