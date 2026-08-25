# Request dispatch, queues, and timeouts

How WebDriverAgent executes HTTP requests, and the guarantees that keep the agent
responsive when the system is under heavy load. Applies to iOS and tvOS; watchOS keeps the
older single-queue model (see the end of this document).

## Why this design

Automation commands ultimately wait on out-of-process confirmations (testmanagerd
acknowledging a synthesized touch, an accessibility snapshot completing). Under heavy load
— most notably sustained high-resolution screen capture on older hardware — the system can
shed a synthesized HID event, and the confirmation for it never arrives. Historically that
single lost confirmation blocked the agent's main queue forever, and because every route
and every HTTP connection funneled through shared serial queues, it took down all
endpoints, including `/status`, until the agent was relaunched.

The dispatch model below contains that failure to the single affected request:

- every HTTP connection is independent,
- routes that never touch automation state stay responsive no matter what the automation
  queue is doing,
- every event-synthesis wait has a deadline and fails with a `500` instead of hanging.

## Connection model

Each accepted HTTP connection gets its **own serial GCD queue** (the vendored
`HTTPServer` passes no shared queue in its `HTTPConfig`, so `HTTPConnection` creates one
per connection). Request parsing and response writing for one connection never block
another connection.

## Route dispatch: control vs automation

Routes are registered in `FBWebServer registerRouteHandlers:` and dispatched per route:

- **Automation routes** (the default): the handler is executed on the **main queue** via
  `dispatch_sync`, preserving the threading model XCUI code expects. Additionally, all
  automation requests pass through a serial **funnel queue** first
  (`dispatch_sync(automationQueue) { dispatch_sync(main) { … } }`). The funnel guarantees
  at most one automation request is in flight: while one handler runs (possibly spinning
  the main run loop while waiting on the system), the next request waits at the funnel
  instead of being enqueued to the main queue, where a nested run-loop drain would
  otherwise execute it reentrantly inside the first handler.
- **Control routes**: marked with the chainable `.onControlQueue` modifier on `FBRoute`.
  Their handlers run **inline on the connection's own queue** and therefore keep working
  even while an automation request is blocked or wedged.

### What qualifies as a control route

A route may opt into `.onControlQueue` only if its handler:

1. never calls XCUI / testmanagerd APIs, and
2. only touches state that is safe to read off the main queue (lock-protected, atomic, or
   immutable), and
3. does not require a WebDriver session — session lookup/decoration is main-queue state,
   so only `.withoutSession` variants qualify.

Currently marked: `GET /status`, the sessionless screen-capture control endpoints
(`POST /mobilerun/screencapture/stop`, `GET /mobilerun/screencapture`,
`GET /mobilerun/screencapture/:id`, `POST /mobilerun/screencapture/:id/stop`,
`POST /mobilerun/screencapture/:id/keyframe`, `GET /mobilerun/screencapture/broadcast`),
and the unknown-endpoint fallback. `/health`, `/calibrate`, and `/wda/shutdown` are
registered directly on the server and likewise run on the connection queue
(`/wda/shutdown` responds first and hops to the main queue asynchronously for the actual
teardown).

Deliberately **not** control routes:

- `POST /mobilerun/screencapture/start` (reads `XCUIScreen`),
- the broadcast start/stop endpoints (drive the system broadcast picker through XCUI),
- `/mobilerun/state` — it is the intended **liveness probe**: because it runs on the
  automation queue and does real accessibility work, it reflects a wedged automation queue
  by timing out, while `/status` stays green as a process-liveness signal.

### Thread-safety notes for control handlers

State read by control handlers is protected accordingly: the active-session singleton is
accessed through synchronized accessors (response envelopes read it for `sessionId`), the
video stream manager guards its session table with a lock and makes capture *stop-all* a
lifecycle barrier (a capture start in flight across a stop-all aborts instead of
resurrecting a session afterwards), and the broadcast manager's state, including its
control-server reference, is atomic.

## Bounded event synthesis

All touch/typing synthesis funnels through
`FBXCTestDaemonsProxy synthesizeEventWithRecord:error:` (used by `/mobilerun/actions`,
W3C `/actions`, and typing). The wait for the system's acknowledgement is bounded:

```
timeout = event record duration (maximumOffset) + margin
```

The margin defaults to **15 seconds** and can be tuned with the
`EVENT_SYNTHESIS_TIMEOUT_MARGIN` environment variable (a positive number of seconds; see
`FBConfiguration eventSynthesisTimeoutMargin`). Quick taps therefore fail fast while long
W3C action chains still fit their own duration.

On timeout the request fails with a `500` ("The synthesized event was not acknowledged
within N seconds…"), the agent keeps serving, and a confirmation that arrives late is
ignored. Clients should treat the error as retryable or recycle the agent. Native
`XCUIElement` gesture endpoints (element tap/swipe/pinch) use XCTest-internal waits and
are not covered by this bound.

## Startup and shutdown ordering

`FBWebServer startServing` binds the HTTP server first, then initializes the capture
broadcasters, arms the keep-alive flag, and only then warms the `dispatch_once`-backed
`/status` values (`FBSDKVersion()`, `FBTestmanagerdVersion()`) on the main thread — the
legacy testmanagerd protocol exchange inside that warm-up is itself bounded (30 s), and
late replies are discarded rather than published. Consequences:

- a degraded daemon cannot prevent the server from binding — `/health` and control routes
  come up regardless;
- a `/wda/shutdown` that arrives while the warm-up is still waiting is honored: the
  serving loop checks the keep-alive flag after the warm-up and exits instead of starting.

## Capture pixel budget

As a load-prevention measure, `POST /mobilerun/screencapture/start` clamps the requested
capture size to a pixel budget (explicit `maxPixels` argument, or a device-class default
on older hardware). See [mobilerun-screencapture.md](mobilerun-screencapture.md) for the
API details.

## watchOS

`FBWatchHTTPServer` keeps the pre-existing model: a single global route queue (the main
queue), no per-route split, no funnel.
