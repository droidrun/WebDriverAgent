# ThirdParty

## hev-socks5-tunnel

- `hev-socks5-tunnel/` is a git submodule of
  [heiher/hev-socks5-tunnel](https://github.com/heiher/hev-socks5-tunnel)
  (MIT license), pinned at a release tag. It carries four nested submodules
  (hev-task-system, yaml, lwip, hev-socks5-core), so clone/update with
  `git submodule update --init --recursive`.
- `HevSocks5Tunnel.xcframework` (gitignored) is built from that source by
  `Scripts/build-hev-socks5-tunnel.sh` — a trimmed variant of upstream's
  `build-apple.sh` producing only the iphoneos-arm64 and
  iphonesimulator-arm64/x86_64 static-library slices. The script skips the
  build when a stamp file matches the current submodule SHA; pass `--force`
  to rebuild.
- The xcframework is linked only by the `WebDriverAgentTunnel` packet-tunnel
  app extension; see `docs/socks5-tunnel.md`.

To bump the engine: check out a new tag inside the submodule, update the
nested submodules, commit the new SHA, and rerun the build script.
