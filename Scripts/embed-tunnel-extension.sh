#!/bin/bash
# Embed the WebDriverAgentTunnel NetworkExtension packet tunnel extension into
# the wrapping XCTRunner host app.
#
# Apple's USES_XCTRUNNER auto-generates a Runner.app around UI-testing
# .xctest bundles after all target build phases have run, so an appex
# cannot reach Runner.app/PlugIns through a regular embed build phase.
# The extension target is built into BUILT_PRODUCTS_DIR via a target
# dependency of WebDriverAgentRunner; this scheme post-action copies it
# into Runner.app/PlugIns, validates that its bundle id matches the host app
# (extensions must be prefixed by the host's CFBundleIdentifier, which
# Xcode suffixes with '.xctrunner') and re-signs inner-first.
#
# Mirrors Scripts/embed-broadcast-extension.sh; kept separate because the
# tunnel additionally needs the NetworkExtension entitlement repaired on
# the host app (see below and docs/socks5-tunnel.md).
#
# Limitations:
#   - Touches XCTRunner internals; may need updates across Xcode versions.
#   - iOS only; the extension is not built for tvOS.
#   - Loading the tunnel on a device needs paid-team signing with the
#     packet-tunnel-provider entitlement (WDA_TUNNEL_ENTITLEMENTS /
#     WDA_RUNNER_ENTITLEMENTS build settings); see docs/socks5-tunnel.md.

set -euo pipefail

RUNNER_APP="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}-Runner.app"
APPEX_NAME="WebDriverAgentTunnel.appex"
APPEX_SRC="${BUILT_PRODUCTS_DIR}/${APPEX_NAME}"
NE_ENTITLEMENT="com.apple.developer.networking.networkextension"

if [ ! -d "$RUNNER_APP" ]; then
    echo "warning: ${PRODUCT_NAME}-Runner.app not found at $RUNNER_APP; skipping tunnel extension embed"
    exit 0
fi

if [ ! -d "$APPEX_SRC" ]; then
    echo "warning: $APPEX_NAME not found at $APPEX_SRC; skipping tunnel extension embed"
    exit 0
fi

APPEX_DST="$RUNNER_APP/PlugIns/$APPEX_NAME"
rm -rf "$APPEX_DST"
mkdir -p "$RUNNER_APP/PlugIns"
cp -R "$APPEX_SRC" "$APPEX_DST"

# Extensions must be provisioned with their final bundle id. Rewriting it after Xcode signs the
# appex cannot update the embedded provisioning profile's application identifier, so fail the
# build instead of producing a bundle that installd will reject.
HOST_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$RUNNER_APP/Info.plist")
WANT_ID="${HOST_ID}.tunnel"
CURRENT_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APPEX_DST/Info.plist")
if [ "$CURRENT_ID" != "$WANT_ID" ]; then
    echo "error: $APPEX_NAME was built as '$CURRENT_ID', expected '$WANT_ID'." >&2
    echo "error: set WDA_PRODUCT_BUNDLE_IDENTIFIER to the runner's base bundle id before building." >&2
    exit 1
fi

# Re-codesign the copied appex first, then the app so its seal covers the new nested code. In a
# scheme post-action context Xcode's CODE_SIGN_* env vars are not exposed, so discover the
# existing signing identity from the already-signed bundle.
if [ -d "$RUNNER_APP/_CodeSignature" ]; then
    # Capture the signature info once. Piping codesign straight into
    # `awk ... exit` makes awk close the pipe early, killing codesign with
    # SIGPIPE -- which `set -o pipefail` turns into a fatal error. That trips
    # only when an Authority line exists, i.e. on every real-device build.
    SIGN_INFO=$(codesign -dvv "$RUNNER_APP" 2>&1 || true)
    EXISTING_IDENT="${EXPANDED_CODE_SIGN_IDENTITY:-}"
    if [ -z "$EXISTING_IDENT" ]; then
        EXISTING_IDENT=$(awk -F'=' '/^Authority/ {print $2; exit}' <<< "$SIGN_INFO")
    fi
    # Simulator builds are ad-hoc signed: there is no Authority line, but the
    # bundle can still be re-signed ad-hoc with an identity of "-".
    if [ -z "$EXISTING_IDENT" ] && grep -q '^Signature=adhoc' <<< "$SIGN_INFO"; then
        EXISTING_IDENT="-"
    fi
    if [ -n "$EXISTING_IDENT" ]; then
        APPEX_ENTITLEMENTS_PLIST=$(mktemp -t tunnel-appex-entitlements).plist
        if ! codesign -d --entitlements - --xml "$APPEX_DST" > "$APPEX_ENTITLEMENTS_PLIST" 2>/dev/null; then
            : > "$APPEX_ENTITLEMENTS_PLIST"
        fi
        codesign --force --sign "$EXISTING_IDENT" \
                 --preserve-metadata=identifier,entitlements "$APPEX_DST"

        # Xcode is not documented to propagate the UI-test target's CODE_SIGN_ENTITLEMENTS onto
        # the generated Runner.app. The host must hold the NetworkExtension entitlement for
        # NETunnelProviderManager to accept the configuration, so when the appex carries it but
        # the host does not, inject it into the host's entitlements while re-sealing.
        RUNNER_ENTITLEMENTS_PLIST=$(mktemp -t tunnel-runner-entitlements).plist
        if ! codesign -d --entitlements - --xml "$RUNNER_APP" > "$RUNNER_ENTITLEMENTS_PLIST" 2>/dev/null; then
            : > "$RUNNER_ENTITLEMENTS_PLIST"
        fi
        APPEX_HAS_NE=$(/usr/libexec/PlistBuddy -c "Print :${NE_ENTITLEMENT}" "$APPEX_ENTITLEMENTS_PLIST" 2>/dev/null || true)
        RUNNER_HAS_NE=$(/usr/libexec/PlistBuddy -c "Print :${NE_ENTITLEMENT}" "$RUNNER_ENTITLEMENTS_PLIST" 2>/dev/null || true)
        if [ -n "$APPEX_HAS_NE" ] && [ -z "$RUNNER_HAS_NE" ] && [ -s "$RUNNER_ENTITLEMENTS_PLIST" ]; then
            /usr/libexec/PlistBuddy -c "Add :${NE_ENTITLEMENT} array" "$RUNNER_ENTITLEMENTS_PLIST"
            /usr/libexec/PlistBuddy -c "Add :${NE_ENTITLEMENT}:0 string packet-tunnel-provider" "$RUNNER_ENTITLEMENTS_PLIST"
            codesign --force --sign "$EXISTING_IDENT" \
                     --preserve-metadata=identifier \
                     --entitlements "$RUNNER_ENTITLEMENTS_PLIST" "$RUNNER_APP"
            echo "injected $NE_ENTITLEMENT into Runner.app entitlements during re-sign"
        else
            codesign --force --sign "$EXISTING_IDENT" \
                     --preserve-metadata=identifier,entitlements "$RUNNER_APP"
        fi
        rm -f "$APPEX_ENTITLEMENTS_PLIST" "$RUNNER_ENTITLEMENTS_PLIST"
    else
        echo "warning: bundle is signed but no identity discovered; signature will be invalid"
    fi
fi

echo "embedded $APPEX_NAME into $RUNNER_APP (bundle id $WANT_ID)"
