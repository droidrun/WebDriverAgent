# Mobilerun WDA

[![Release](https://github.com/droidrun/WebDriverAgent/actions/workflows/prebuild.yml/badge.svg)](https://github.com/droidrun/WebDriverAgent/releases)

[![GitHub license](https://img.shields.io/badge/license-BSD-lightgrey.svg)](LICENSE)

Mobilerun's fork of [WebDriverAgent](https://github.com/appium/WebDriverAgent), a [WebDriver server](https://w3c.github.io/webdriver/webdriver-spec.html) implementation for iOS that can be used to remote control iOS devices. It allows you to launch & kill applications, tap & scroll views or confirm view presence on a screen. This makes it a perfect tool for application end-to-end testing or general purpose device automation. It works by linking `XCTest.framework` and calling Apple's API to execute commands directly on a device.

## Features
 * Both iOS and tvOS platforms are supported with devices & simulators
 * Implements most of [WebDriver Spec](https://w3c.github.io/webdriver/webdriver-spec.html)
 * Implements part of [Mobile JSON Wire Protocol Spec](https://github.com/SeleniumHQ/mobile-spec/blob/master/spec-draft.md)
 * USB support for devices is implemented via [appium-ios-device](https://github.com/appium/appium-ios-device) library and has zero dependencies on third-party tools.
 * Easy development cycle as it can be launched & debugged directly via Xcode

### Mobilerun extras

On top of upstream WebDriverAgent, this fork adds:

 * **Batched actions** — `POST /mobilerun/actions` executes W3C-style action batches (works without a session) with optional coordinate scaling via the `scale` parameter
 * **UI state snapshot** — `GET /mobilerun/state` returns the accessibility state of the current app, with the same coordinate scaling
 * **Screen capture streaming** — `POST /mobilerun/screencapture/start` & friends stream the screen as H.264/H.265 over TCP (`SCREEN_CAPTURE_SERVER_PORT`), with per-session control and on-demand keyframes
 * **Full-device broadcast** — a ReplayKit broadcast upload extension (`WebDriverAgentBroadcast`) captures the whole device (not just the tested app), controlled via `/mobilerun/screencapture/broadcast/*` (`BROADCAST_CONTROL_PORT`)
 * **Audio capture** — `POST /mobilerun/audiocapture/start` & friends stream device audio as Opus over TCP (`AUDIO_CAPTURE_SERVER_PORT`)
 * **Responsiveness tuning** — quiescence and animation cool-off waits are disabled by default, so commands execute without artificial delays
 * **Files app access** — the runner's `Documents` folder is exposed in the iOS Files app for file transfer
 * **Prebuilt artifacts** — runner zips for real devices and simulators are attached to every [GitHub release](https://github.com/droidrun/WebDriverAgent/releases)

## Getting Started On This Repository

You need to have Node.js installed for this project.

After it is finished you can simply open `WebDriverAgent.xcodeproj` and start `WebDriverAgentRunner` test
and start sending [requests](https://github.com/facebook/WebDriverAgent/wiki/Queries).

More about how to start WebDriverAgent [here](https://github.com/facebook/WebDriverAgent/wiki/Starting-WebDriverAgent).

## Known Issues
If you are having some issues please checkout [wiki](https://github.com/facebook/WebDriverAgent/wiki/Common-Issues) first.

## For Contributors
If you want to help us out, you are more than welcome to. However please make sure you have followed the guidelines in [CONTRIBUTING](CONTRIBUTING.md).

## Creating Bundles

`npm run bundle`

Then, you find `WebDriverAgentRunner-Runner-sim-<version>.zip`  for iOS and `WebDriverAgentRunner-Runner-tv_sim-<version>.zip` for tvOS files in the current directory.

## License

[`WebDriverAgent` is BSD-licensed](LICENSE).

## Third Party Sources

WebDriverAgent depends on the following third-party frameworks:
- [CocoaHTTPServer](https://github.com/robbiehanson/CocoaHTTPServer)
- [RoutingHTTPServer](https://github.com/mattstevens/RoutingHTTPServer)

These projects haven't been maintained in a while. That's why the source code of these
projects has been integrated directly in the WebDriverAgent source tree.

You can find the source files and their licenses in the `WebDriverAgentLib/Vendor` directory.

Have fun!
