# SOCKS5 VPN Tunnel

WebDriverAgent can embed a NetworkExtension **packet tunnel provider**
(`WebDriverAgentTunnel.appex`) into the generated `WebDriverAgentRunner-Runner.app`. When
connected, the tunnel captures the device's IPv4 traffic on a virtual interface and forwards
it through a SOCKS5 proxy using the [hev-socks5-tunnel](https://github.com/heiher/hev-socks5-tunnel)
engine (MIT) running inside the extension. WDA configures and controls the tunnel in-process
via `NETunnelProviderManager`.

The extension is **opt-in at build time**: only the `WebDriverAgentRunnerTunnel` /
`WebDriverAgentRunnerTunnel-nodebug` schemes build and embed it. The default
`WebDriverAgentRunner` / `WebDriverAgentRunner-nodebug` schemes produce a runner without the
extension — no git submodule, no engine build and no paid team needed — whose socks5
endpoints answer `unsupported operation`.

The tunnel only works on **physical iOS devices** (packet tunnel providers do not run on the
Simulator or tvOS — the endpoints answer `unsupported operation` there) and requires
**paid-team signing**: free/personal Apple developer teams cannot register App IDs with the
Network Extension capability.

## HTTP endpoints

| Endpoint | Method | Description |
|---|---|---|
| `/mobilerun/socks5/connect` | POST | Installs/updates the VPN configuration (auto-accepting the system consent alert via UI automation) and starts the tunnel. Replaces an already running tunnel. Returns once the tunnel reports connected. |
| `/mobilerun/socks5/disconnect` | POST | Stops the running tunnel. The VPN profile stays installed. Succeeds when no tunnel is running. Send `{}` as the body (WDA rejects body-less POSTs with HTTP 400). |
| `/mobilerun/socks5/stats` | GET | Connection state plus traffic counters queried from the extension. Never fails; counters fall back to zero when the extension cannot be reached. |

`connect` body:

```json
{
  "uri": "socks5h://user:pass@proxy.example.com:1080",
  "timeout": 30,
  "consentButtonLabels": ["Allow"]
}
```

- `uri` (required) — `socks5://` or `socks5h://`, optional percent-encoded `user:pass@`,
  host (DNS name, IPv4 or bracketed IPv6 literal), optional port (default 1080).
  With `socks5h` hostnames are resolved **through the proxy**: the tunnel runs hev's
  `mapdns`, which hijacks DNS queries to synthetic IPs and forwards the original hostname in
  the SOCKS5 CONNECT. With plain `socks5` the tunnel uses public resolvers (8.8.8.8/1.1.1.1)
  and relays the DNS datagrams through the proxy's UDP relay — the proxy must support UDP
  ASSOCIATE for that; prefer `socks5h` when unsure.
- `timeout` (optional, default 30, maximum 300) — seconds for the whole connect flow
  (consent + tunnel reaching connected).
- `consentButtonLabels` (optional, default `["Allow"]`) — labels to look for on the system
  "Would Like to Add VPN Configurations" alert. Pass the localized label when the device
  language is not English.

The tunnel installs full IPv4 and IPv6 routes, but excludes both the selected proxy address
and the IP address of the HTTP client that issued `connect`. The latter preserves the active
WDA response and subsequent `stats` or `disconnect` requests when the controller reaches the
device through its physical default route.

`stats` response value (also returned by successful `connect`/`disconnect` calls):

```json
{
  "connected": true,
  "host": "proxy.example.com",
  "port": 1080,
  "user": "user",
  "rxBytes": 123456,
  "txBytes": 7890,
  "rxPackets": 321,
  "txPackets": 123
}
```

`host`/`port`/`user` are omitted while disconnected (`user` also when the proxy needs no
auth). Counters are cumulative since the tunnel start and reset on reconnect.

## Build (opt-in)

The default runner schemes do not reference the appex at all; `connect` on such a build
fails fast with `unsupported operation: this build does not embed the WebDriverAgentTunnel
extension` (`disconnect` and `stats` keep answering as disconnected). To include the tunnel,
build a `WebDriverAgentRunnerTunnel*` scheme — it builds the `WebDriverAgentTunnel` appex
alongside the runner and carries the embed post-action.

The engine is vendored as a git submodule and compiled into a static-library xcframework
that only the appex links:

```bash
git submodule update --init --recursive
Scripts/build-hev-socks5-tunnel.sh   # -> ThirdParty/HevSocks5Tunnel.xcframework (gitignored)
```

`Scripts/build.sh` runs the engine build automatically for `TARGET=tunnel_runner`, and it is
a no-op while the stamp file matches the submodule SHA (`--force` rebuilds). Plain
`xcodebuild` invocations of the tunnel schemes need the script run once beforehand.

Like the broadcast extension, the appex cannot reach the Xcode-generated `Runner.app` through
a regular embed phase; the tunnel schemes' post-action `Scripts/embed-tunnel-extension.sh`
copies it into `Runner.app/PlugIns`, verifies its build-time bundle id is `<host id>.tunnel`,
and re-signs inner-first (post-actions run on scheme-based CLI builds, including
`build-for-testing`). Set `WDA_PRODUCT_BUNDLE_IDENTIFIER` to the runner's base identifier so
the runner and extension are provisioned with their final identifiers.

## Signing (device)

Both the host app and the appex must carry the
`com.apple.developer.networking.networkextension` entitlement with the
`packet-tunnel-provider` value, and the team's App IDs for the runner and
`<runner id>.xctrunner.tunnel` need the Network Extension capability — **paid teams only**.

The entitlements are wired through build variables that default to empty, so regular
(free-team / CI / Simulator) builds keep working unchanged. For a paid-team device build pass
them explicitly:

```bash
xcodebuild build-for-testing -project WebDriverAgent.xcodeproj -scheme WebDriverAgentRunnerTunnel \
  -destination 'id=<UDID>' -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=<PAID_TEAM_ID> \
  WDA_RUNNER_ENTITLEMENTS=WebDriverAgentRunner/WebDriverAgentRunner.entitlements \
  WDA_TUNNEL_ENTITLEMENTS=WebDriverAgentTunnel/WebDriverAgentTunnel.entitlements
```

`Scripts/embed-tunnel-extension.sh` additionally injects the NE entitlement into
`Runner.app`'s signature when the appex carries it but the host does not (Xcode does not
document whether a UI-test target's `CODE_SIGN_ENTITLEMENTS` propagates to the generated
runner). Cloud device farms that re-sign WDA must re-sign the nested appex with the same
team first and preserve the NE entitlement on both bundles.

Without the entitlements the build still succeeds and the appex is embedded, but
`saveToPreferences` is rejected on device and `connect` answers
`unsupported operation: The VPN configuration was not authorized`.

## Consent alert

The first `saveToPreferences` per install triggers the system "Would Like to Add VPN
Configurations" alert. The connect handler auto-confirms it by tapping the consent button on
Springboard while the save is pending. **Devices with a passcode additionally prompt for the
passcode, which cannot be automated** — confirm once manually; the profile then persists
until the app is uninstalled. Reinstalling WDA (new install, not upgrade) removes the
profile, so the next connect repeats the consent flow.

## Device verification checklist (deferred until a paid team is available)

1. Run a local SOCKS5 server on the Mac: `microsocks -p 1080` (or `ssh -D 0.0.0.0:1080 -N localhost`).
2. Build + install with the paid-team invocation above; start WDA.
3. `GET /mobilerun/socks5/stats` → `connected: false`.
4. `POST /mobilerun/socks5/connect` with `socks5h://<mac-ip>:1080` → `connected: true`;
   check `codesign -d --entitlements -` on both `Runner.app` and the appex if it fails.
5. Egress check: fetch `https://api.ipify.org` on the device → the Mac's egress IP.
6. Download a known-size file, re-poll `stats`: `rxBytes` must grow by roughly that size
   (confirms the rx/tx direction mapping of the engine counters; swap the mapping in
   `FBSocks5TunnelManager.statsDictionary`/`FBTunnelPacketProvider.handleAppMessage` if
   inverted).
7. `POST /mobilerun/socks5/disconnect` → `connected: false`, egress IP reverts.
