#!/bin/bash
# Copyright (c) 2026-present, Droidrun.
# All rights reserved.
#
# This source code is licensed under the BSD-style license found in the
# LICENSE file in the root directory of this source tree.

# Remove tunnel-only artifacts from the generated XCTRunner host app. Xcode reuses the Runner.app
# directory across schemes, but the tunnel appex is copied by a scheme post-action and is therefore
# not tracked or removed by the default target build.

set -euo pipefail

RUNNER_APP="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}-Runner.app"
APPEX_NAME="WebDriverAgentTunnel.appex"
APPEX_DST="$RUNNER_APP/PlugIns/$APPEX_NAME"
NE_ENTITLEMENT="com.apple.developer.networking.networkextension"

if [ ! -d "$RUNNER_APP" ]; then
    echo "warning: ${PRODUCT_NAME}-Runner.app not found at $RUNNER_APP; skipping tunnel extension cleanup"
    exit 0
fi

SIGNED=0
SIGN_INFO=""
EXISTING_IDENT=""
RUNNER_ENTITLEMENTS_PLIST=""
if [ -d "$RUNNER_APP/_CodeSignature" ]; then
    SIGNED=1
    SIGN_INFO=$(codesign -dvv "$RUNNER_APP" 2>&1 || true)
    EXISTING_IDENT="${EXPANDED_CODE_SIGN_IDENTITY:-}"
    if [ -z "$EXISTING_IDENT" ]; then
        EXISTING_IDENT=$(awk -F'=' '/^Authority/ {print $2; exit}' <<< "$SIGN_INFO")
    fi
    if [ -z "$EXISTING_IDENT" ] && grep -q '^Signature=adhoc' <<< "$SIGN_INFO"; then
        EXISTING_IDENT="-"
    fi
    RUNNER_ENTITLEMENTS_PLIST=$(mktemp -t default-runner-entitlements)
    if ! codesign -d --entitlements - --xml "$RUNNER_APP" > "$RUNNER_ENTITLEMENTS_PLIST" 2>/dev/null; then
        : > "$RUNNER_ENTITLEMENTS_PLIST"
    fi
fi

REMOVED_APPEX=0
if [ -e "$APPEX_DST" ]; then
    rm -rf "$APPEX_DST"
    rmdir "$RUNNER_APP/PlugIns" 2>/dev/null || true
    REMOVED_APPEX=1
fi

REMOVED_ENTITLEMENT=0
if [ -n "$RUNNER_ENTITLEMENTS_PLIST" ] && [ -s "$RUNNER_ENTITLEMENTS_PLIST" ]; then
    if /usr/libexec/PlistBuddy -c "Print :${NE_ENTITLEMENT}" "$RUNNER_ENTITLEMENTS_PLIST" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Delete :${NE_ENTITLEMENT}" "$RUNNER_ENTITLEMENTS_PLIST"
        REMOVED_ENTITLEMENT=1
    fi
fi

if [ "$SIGNED" = "1" ] && { [ "$REMOVED_APPEX" = "1" ] || [ "$REMOVED_ENTITLEMENT" = "1" ]; }; then
    if [ -z "$EXISTING_IDENT" ]; then
        echo "warning: Runner.app is signed but no identity was discovered; signature is invalid after tunnel cleanup"
    elif [ "$REMOVED_ENTITLEMENT" = "1" ]; then
        codesign --force --sign "$EXISTING_IDENT" \
                 --preserve-metadata=identifier \
                 --entitlements "$RUNNER_ENTITLEMENTS_PLIST" "$RUNNER_APP"
    else
        codesign --force --sign "$EXISTING_IDENT" \
                 --preserve-metadata=identifier,entitlements "$RUNNER_APP"
    fi
fi

if [ -n "$RUNNER_ENTITLEMENTS_PLIST" ]; then
    rm -f "$RUNNER_ENTITLEMENTS_PLIST"
fi

if [ "$REMOVED_APPEX" = "1" ] || [ "$REMOVED_ENTITLEMENT" = "1" ]; then
    echo "removed stale tunnel artifacts from $RUNNER_APP"
fi
