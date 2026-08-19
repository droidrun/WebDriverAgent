# Runner reliability under capture load — design

Date: 2026-08-19

## Problem

On lower-end devices (A12 and older), heavy screen-capture load (ReplayKit broadcast +
high-resolution hardware encoding) can make backboardd shed synthesized HID events
(`kIOReturnNoMemory` enqueue drops). When a synthesized touch event is dropped,
testmanagerd never delivers the `TouchEventsCompleted` confirmation, and the runner-side
wait blocks forever:

- `FBXCTestDaemonsProxy synthesizeEventWithRecord:` waits via
  `+[FBRunLoopSpinner spinUntilCompletion:]`, which has **no timeout** and spins the main
  run loop indefinitely.
- Every WDA route is `dispatch_sync`ed onto the **main queue**
  (`[FBWebServer startHTTPServer]` sets `routeQueue` to the main queue), so one lost
  completion permanently blocks all automation endpoints.
- All HTTP connections share **one serial socket queue** (`HTTPServer.m` creates a single
  `connectionQueue` passed to every `HTTPConnection`), so the blocked `dispatch_sync`
  also prevents parsing of any further request on any connection — even `/status` and
  keyframe requests wedge. The runner never self-recovers.

The fix has three independent parts: keep the HTTP layer responsive (queue split), make
lost waits fail a single request instead of the whole agent (bounded waits), and reduce
the capture load that triggers event shedding in the first place (capture pixel cap).

## Goals

- A lost/wedged XCUI synthesis wait fails that one request with a 5xx; `/status`,
  keyframe, and subsequent requests keep working.
- Control endpoints stay responsive even while an automation request is blocked.
- Capture requests are capped to a safe pixel budget on older chips by default, with an
  explicit API override.

## Non-goals

- Portal-side recovery orchestration (separate component).
- Bounding native `XCUIElement` gesture waits (element tap/swipe/pinch go through
  XCTest-internal wait machinery, not our spinner; unchanged).
- MJPEG server changes (already runs on its own socket/queues).

## Part 1 — HTTP layer: per-connection queues + control-route split

### Per-connection socket queues

`HTTPServer` currently creates one serial `connectionQueue` and hands it to every
connection via `HTTPConfig`. Change the vendored `HTTPServer` to pass a nil queue so each
`HTTPConnection` creates its own queue (this is stock CocoaHTTPServer behavior when no
queue is provided). One blocked request then only stalls its own TCP connection.

### Route dispatch split

Remove the global `setRouteQueue(main)`. Dispatch per route inside
`-[FBWebServer registerRouteHandlers:]`:

- **Automation routes** (default): `dispatch_sync` onto the main queue — semantics
  identical to today for everything that touches XCUI / testmanagerd.
- **Control routes**: run inline on the connection's own queue. Marked with a new
  chainable `FBRoute` flag (`.onControlQueue`). Only routes whose handlers never touch
  XCUI and whose backing state is thread-safe qualify:
  - `/status` (reads bundle/env/UIDevice info only)
  - `/health`, `/calibrate`, `/wda/shutdown` (registered directly on the server; run on
    the connection queue automatically once no global route queue is set — the shutdown
    delegate hop must be audited for thread safety)
  - `/mobilerun/screencapture` family: stop / stop-all / list / get / keyframe
    (`FBVideoStreamManager` is `@synchronized`-guarded and does its work on its own
    background queue). **start** stays on the automation queue — it reads
    `XCUIScreen.mainScreen`, which violates the never-touches-XCUI rule.
  - The unknown-endpoint fallback (`FBUnknownCommands`) — it only builds an error
    payload, and a wedged agent should still say "no such route" instead of hanging.
  - `GET /mobilerun/screencapture/broadcast` (status read; `FBBroadcastManager` state
    reads must be audited/made atomic)

Broadcast **start/stop** stay on the main queue: they drive the system broadcast picker
through XCUI. `/mobilerun/state` also stays on the main queue **deliberately**: it is the
liveness probe that must reflect a wedged automation queue by timing out or erroring.

## Part 2 — Bounded synthesis waits

- Add `+[FBRunLoopSpinner spinUntilCompletion:timeout:]` returning `BOOL` (`NO` when the
  deadline passes before the completion fires). The existing no-timeout variant remains
  for callers not yet migrated.
- `+[FBXCTestDaemonsProxy synthesizeEventWithRecord:error:]` computes
  `timeout = record.maximumOffset + margin`:
  - `maximumOffset` is the total scheduled duration of the synthesized event record, so
    quick taps get a short deadline while long W3C action chains still fit.
  - `margin` is a new `FBConfiguration` property (default **15 s**), overridable via env
    var so it can be tuned without rebuilding.
- On timeout the method fails with a descriptive `NSError`; command handlers already map
  that to a 5xx (`FBResponseWithUnknownError`). The portal treats 5xx as
  relaunch-worthy, which is the desired escalation.
- A late completion after the deadline is harmless: the completion block only flips a
  heap-allocated atomic flag that nobody reads anymore.
- No attempt is made to "clean up" a possibly stuck touch (e.g. down without up); after
  a synthesis failure the client is expected to recover the session.
- Covered call sites (all funnel through this one proxy method): `/mobilerun/actions`,
  W3C `/actions`, and typing (`XCUIElement+FBTyping` / `FBKeyboard`).

## Part 3 — Capture pixel cap

- `POST /mobilerun/screencapture/start` gains an optional integer argument
  `maxPixels` (`0` = explicitly uncapped).
- When `width × height > maxPixels`, WDA scales the requested dimensions down
  aspect-preserving (`scale = sqrt(maxPixels / (w·h))`), rounding to even values (HW
  encoder requirement).
- When `maxPixels` is absent, a device-class default applies:
  - A12-and-older chips → **370 944 px** (equivalent to 414×896, a budget verified safe
    for sustained 60 fps HEVC capture on that hardware class).
  - Newer chips → uncapped.
  - Detection via `hw.machine` sysctl: iPhone models with a major version of 11 or
    lower (`iPhone11,*` = A12) are classified A12-and-older. Non-iPhone and unknown
    models are treated as uncapped — only this hardware class has shown HID event
    shedding, and mis-capping newer devices would silently degrade capture quality.
- fps is not touched: the pixel budget alone is what distinguishes the safe from the
  wedging configuration on the affected hardware class.
- The clamped dimensions flow through the existing config → session → `SESSION_ADD`
  path, and the actual size is already reported back via the session dictionary and the
  stream's `VIDEO_PARAMS`, so consumers adapt without changes.

## Files touched (expected)

- `WebDriverAgentLib/Vendor/CocoaHTTPServer/HTTPServer.m` — per-connection queues
- `WebDriverAgentLib/Routing/FBWebServer.m` — remove global route queue, per-route dispatch
- `WebDriverAgentLib/Routing/FBRoute.{h,m}` — `.onControlQueue` chainable flag
- `WebDriverAgentLib/Utilities/FBRunLoopSpinner.{h,m}` — timeout variant
- `WebDriverAgentLib/Utilities/FBXCTestDaemonsProxy.m` — bounded synthesis wait
- `WebDriverAgentLib/Utilities/FBConfiguration.{h,m}` — synthesis margin property
- `WebDriverAgentLib/Commands/FBScreenCaptureCommands.m` — `maxPixels` argument
- `WebDriverAgentLib/Utilities/FBVideoStreamSession.{h,m}` — device-class detection + clamp
  math as class methods on `FBScreenCaptureConfiguration` (unit-testable pure functions; no
  new files so the Xcode project file stays untouched)
- `docs/mobilerun-screencapture.md`, `docs/mobilerun-actions.md` — API docs

## Error handling

- Synthesis timeout → `NSError` → 5xx on the single request; agent keeps serving.
- Capture clamp never fails a request: it only shrinks dimensions (invalid `maxPixels`
  values, e.g. negative or non-numeric, are rejected as `invalid argument`).
- Queue split changes no response semantics; control handlers must not throw XCUI-related
  exceptions since they never call XCUI.

## Testing

- **Unit** (`UnitTests` target): spinner timeout (fires/expires), clamp math (aspect
  ratio, even alignment, no-op when under budget), device-model→budget mapping with
  injected model strings.
- **Integration** (simulator): with the server running, saturate the main queue with a
  long-running block and assert control routes (`/status`, screencapture list) still
  answer while an automation route blocks; assert a synthesis wait that never completes
  returns a 5xx within its deadline.
- **On-device validation** (manual, fleet): sustained broadcast capture + continuous
  automation on an A12 device without a wedge; wedge injection recovers per request
  instead of killing the runner.
