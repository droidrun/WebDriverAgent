# Runner Reliability Under Capture Load Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the WDA runner serving requests when the system drops synthesized touch events under heavy capture load: bounded synthesis waits (single request fails 5xx), control routes that bypass the automation queue, and a capture pixel cap for older devices.

**Architecture:** Three independent changes to existing files. (1) `FBRunLoopSpinner` gains a bounded completion-spin used by `FBXCTestDaemonsProxy synthesizeEventWithRecord:` with a duration-derived deadline. (2) The HTTP layer stops funneling everything through one shared connection queue + a global main route queue: each connection gets its own queue, and routes marked "control" run inline on it while all other routes `dispatch_sync` to the main queue exactly as today. (3) `/mobilerun/screencapture/start` clamps requested dimensions to a pixel budget (explicit `maxPixels` argument, or a device-class default for A12-and-older iPhones).

**Tech Stack:** Objective-C, XCTest unit tests (`UnitTests` bundle), xcodebuild against an iOS simulator.

**Spec:** `docs/superpowers/specs/2026-08-19-runner-reliability-capture-load-design.md`

## Global Constraints

- **No new source or test files.** All code goes into existing files so `project.pbxproj` is never touched (Xcode reorders it and wiring is error-prone). New unit tests join existing test-case files; a second `XCTestCase` class in an existing file is fine.
- **All platforms must compile:** CI builds iOS, tvOS, and watchOS. The watchOS path (`TARGET_OS_WATCH`) keeps today's behavior (`FBWatchHTTPServer` + main route queue); only the `RoutingHTTPServer` path changes.
- **Do not modify copyright headers** of edited files.
- **Public repo hygiene:** commit messages describe the mechanism generically. Never mention fleet hosts, device serials, internal recovery tooling, or reproduction infrastructure.
- **Env var naming:** bare uppercase style matching existing vars (e.g. `MAX_HTTP_REQUEST_BODY_SIZE`) — the new var is `EVENT_SYNTHESIS_TIMEOUT_MARGIN`.
- **Unit test command** (pick an available iPhone simulator via `xcrun simctl list devices available | grep iPhone`):
  ```bash
  xcodebuild test -project WebDriverAgent.xcodeproj -scheme WebDriverAgentRunner \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -only-testing:UnitTests/<TestClass> CODE_SIGNING_ALLOWED=NO
  ```
  Drop `/<TestClass>` to run the whole bundle. First runs are slow (build); later runs are incremental.
- The working branch is `timo/dro-2713-wda-runner-reliability-under-capture-load` (already created from origin/master).

---

### Task 1: Bounded run-loop spin (`FBRunLoopSpinner`)

**Files:**
- Modify: `WebDriverAgentLib/Utilities/FBRunLoopSpinner.h`
- Modify: `WebDriverAgentLib/Utilities/FBRunLoopSpinner.m`
- Test: `WebDriverAgentTests/UnitTests/FBRunLoopSpinnerTests.m`

**Interfaces:**
- Consumes: nothing new.
- Produces: `+ (BOOL)spinUntilCompletion:(void (^)(void(^completion)(void)))block timeout:(NSTimeInterval)timeout;` — returns `YES` when `completion` fired before the deadline, `NO` on timeout. Task 2 calls this.

- [ ] **Step 1: Write the failing tests**

Append to `WebDriverAgentTests/UnitTests/FBRunLoopSpinnerTests.m` (inside the existing `FBRunLoopSpinnerTests` implementation, before `@end`):

```objc
- (void)testBoundedSpinReturnsYesWhenCompletionFires
{
  NSDate *start = [NSDate date];
  BOOL result = [FBRunLoopSpinner spinUntilCompletion:^(void (^completion)(void)) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), completion);
  } timeout:5.0];
  XCTAssertTrue(result);
  XCTAssertLessThan([[NSDate date] timeIntervalSinceDate:start], 4.0);
}

- (void)testBoundedSpinReturnsNoOnTimeout
{
  NSDate *start = [NSDate date];
  BOOL result = [FBRunLoopSpinner spinUntilCompletion:^(void (^completion)(void)) {
    // The completion is intentionally never called
  } timeout:0.5];
  XCTAssertFalse(result);
  NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:start];
  XCTAssertGreaterThanOrEqual(elapsed, 0.5);
  XCTAssertLessThan(elapsed, 3.0);
}

- (void)testBoundedSpinToleratesLateCompletion
{
  __block void (^lateCompletion)(void) = nil;
  BOOL result = [FBRunLoopSpinner spinUntilCompletion:^(void (^completion)(void)) {
    lateCompletion = [completion copy];
  } timeout:0.2];
  XCTAssertFalse(result);
  XCTAssertNotNil(lateCompletion);
  // A completion arriving after the deadline must be a harmless no-op
  lateCompletion();
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test ... -only-testing:UnitTests/FBRunLoopSpinnerTests CODE_SIGNING_ALLOWED=NO` (full command from Global Constraints)
Expected: BUILD FAILURE — `no known class method for selector 'spinUntilCompletion:timeout:'` (a compile error is the RED state here).

- [ ] **Step 3: Implement the bounded spin**

In `FBRunLoopSpinner.h`, after the existing `spinUntilCompletion:` declaration:

```objc
/**
 Dispatches block and spins the run loop until `completion` is called or the timeout expires.

 @param block the block to wait for to finish.
 @param timeout the maximum time in seconds to wait for the completion.
 @return YES if the completion was called before the deadline, NO on timeout. A completion
         firing after the deadline is a harmless no-op.
 */
+ (BOOL)spinUntilCompletion:(void (^)(void(^completion)(void)))block timeout:(NSTimeInterval)timeout;
```

In `FBRunLoopSpinner.m`, replace the existing `+spinUntilCompletion:` implementation with a delegating pair:

```objc
+ (void)spinUntilCompletion:(void (^)(void(^completion)(void)))block
{
  [self spinUntilCompletion:block timeout:DBL_MAX];
}

+ (BOOL)spinUntilCompletion:(void (^)(void(^completion)(void)))block timeout:(NSTimeInterval)timeout
{
  // The __block flag is moved to the heap when the completion block escapes, so a completion
  // arriving after a timeout return still writes valid memory and is simply never read.
  __block volatile atomic_bool didFinish = false;
  block(^{
    atomic_fetch_or(&didFinish, true);
  });
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  while (!atomic_fetch_and(&didFinish, false)) {
    if (deadline.timeIntervalSinceNow <= 0) {
      return NO;
    }
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:FBWaitInterval]];
  }
  return YES;
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: same command as Step 2.
Expected: all `FBRunLoopSpinnerTests` PASS (including the three pre-existing tests — the no-timeout delegation must not regress them).

- [ ] **Step 5: Commit**

```bash
git add WebDriverAgentLib/Utilities/FBRunLoopSpinner.h WebDriverAgentLib/Utilities/FBRunLoopSpinner.m WebDriverAgentTests/UnitTests/FBRunLoopSpinnerTests.m
git commit -m "feat: add bounded variant of the run loop completion spinner"
```

---

### Task 2: Bounded event synthesis (`FBConfiguration` margin + `FBXCTestDaemonsProxy`)

**Files:**
- Modify: `WebDriverAgentLib/Utilities/FBConfiguration.h`
- Modify: `WebDriverAgentLib/Utilities/FBConfiguration.m`
- Modify: `WebDriverAgentLib/Utilities/FBXCTestDaemonsProxy.m` (`synthesizeEventWithRecord:error:`)
- Modify: `docs/mobilerun-actions.md`
- Test: `WebDriverAgentTests/UnitTests/FBConfigurationTests.m`

**Interfaces:**
- Consumes: `+[FBRunLoopSpinner spinUntilCompletion:timeout:]` from Task 1.
- Produces: `- (NSTimeInterval)eventSynthesisTimeoutMargin;` on `FBConfiguration` (instance method on the shared singleton, like `httpRequestBodySizeLimit`). No later task depends on this; it completes the "survive" wait-bounding.

- [ ] **Step 1: Write the failing tests**

Append inside the existing `FBConfigurationTests` implementation in `WebDriverAgentTests/UnitTests/FBConfigurationTests.m`:

```objc
- (void)testEventSynthesisTimeoutMarginDefault
{
  unsetenv("EVENT_SYNTHESIS_TIMEOUT_MARGIN");
  XCTAssertEqualWithAccuracy([FBConfiguration.sharedInstance eventSynthesisTimeoutMargin], 15.0, 0.001);
}

- (void)testEventSynthesisTimeoutMarginEnvOverride
{
  setenv("EVENT_SYNTHESIS_TIMEOUT_MARGIN", "42.5", 1);
  XCTAssertEqualWithAccuracy([FBConfiguration.sharedInstance eventSynthesisTimeoutMargin], 42.5, 0.001);
  unsetenv("EVENT_SYNTHESIS_TIMEOUT_MARGIN");
}

- (void)testEventSynthesisTimeoutMarginRejectsInvalidOverride
{
  setenv("EVENT_SYNTHESIS_TIMEOUT_MARGIN", "-3", 1);
  XCTAssertEqualWithAccuracy([FBConfiguration.sharedInstance eventSynthesisTimeoutMargin], 15.0, 0.001);
  unsetenv("EVENT_SYNTHESIS_TIMEOUT_MARGIN");
}
```

Note: `FBConfiguration.sharedInstance` is how config is accessed in this fork (singleton since the upstream v16.2 merge). If `FBConfigurationTests.m` already manipulates env vars differently, follow its local pattern for set/unset but keep the assertions.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test ... -only-testing:UnitTests/FBConfigurationTests CODE_SIGNING_ALLOWED=NO`
Expected: BUILD FAILURE — `no visible @interface for 'FBConfiguration' declares the selector 'eventSynthesisTimeoutMargin'`.

- [ ] **Step 3: Implement the margin property**

`FBConfiguration.h` — add near the other timeout-ish instance methods (e.g. next to `httpRequestBodySizeLimit`):

```objc
/**
 Extra time in seconds granted on top of a synthesized event's own scheduled duration before an
 unacknowledged synthesis is failed with an error instead of blocking the caller forever.
 Override with the EVENT_SYNTHESIS_TIMEOUT_MARGIN environment variable (a positive number of
 seconds). Defaults to 15.
 */
- (NSTimeInterval)eventSynthesisTimeoutMargin;
```

`FBConfiguration.m` — add next to `httpRequestBodySizeLimit` (uses `getenv` rather than `NSProcessInfo` so the value is not frozen at first access — `NSProcessInfo.environment` caches, which would break both env-based tests and runtime tuning):

```objc
static const NSTimeInterval DefaultEventSynthesisTimeoutMargin = 15.0;

- (NSTimeInterval)eventSynthesisTimeoutMargin
{
  const char *rawMargin = getenv("EVENT_SYNTHESIS_TIMEOUT_MARGIN");
  if (rawMargin != NULL) {
    double parsedMargin = atof(rawMargin);
    if (parsedMargin > 0) {
      return parsedMargin;
    }
  }
  return DefaultEventSynthesisTimeoutMargin;
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: same command as Step 2. Expected: PASS (all of `FBConfigurationTests`).

- [ ] **Step 5: Bound the synthesis wait**

In `WebDriverAgentLib/Utilities/FBXCTestDaemonsProxy.m`:

Add to the imports (it is not imported today; the type currently arrives via the header's forward declaration):

```objc
#import "XCSynthesizedEventRecord.h"
```

Replace the body of `+ (BOOL)synthesizeEventWithRecord:(XCSynthesizedEventRecord *)record error:(NSError *__autoreleasing*)error` with:

```objc
  __block NSError *innerError = nil;
  // maximumOffset is the record's total scheduled duration in seconds, so quick taps get a
  // short deadline while long W3C action chains still fit. A synthesis whose completion never
  // arrives (e.g. the event was shed by the system under load) must fail this one request
  // instead of blocking the automation queue forever.
  NSTimeInterval timeout = record.maximumOffset + FBConfiguration.sharedInstance.eventSynthesisTimeoutMargin;
  BOOL didComplete = [FBRunLoopSpinner spinUntilCompletion:^(void(^completion)(void)){
    void (^errorHandler)(NSError *) = ^(NSError *invokeError) {
      if (nil != invokeError) {
        innerError = invokeError;
      }
      completion();
    };

    void (^handlerBlock)(XCSynthesizedEventRecord *, NSError *) = ^(XCSynthesizedEventRecord *innerRecord, NSError *invokeError) {
      errorHandler(invokeError);
    };
    [[XCUIDevice.sharedDevice eventSynthesizer] synthesizeEvent:record completion:(id)^(BOOL result, NSError *invokeError) {
      handlerBlock(record, invokeError);
    }];
  } timeout:timeout];
  if (!didComplete) {
    return [[[FBErrorBuilder builder]
             withDescriptionFormat:@"The synthesized event was not acknowledged within %.1f seconds. The event delivery pipeline may be overloaded", timeout]
            buildError:error];
  }
  if (nil != innerError) {
    if (error) {
      *error = innerError;
    }
    return NO;
  }
  return YES;
```

(Only the wrapping changed: `spinUntilCompletion:` → bounded variant + the `didComplete` check. The inner blocks are byte-identical to today's.)

- [ ] **Step 6: Verify the library still compiles and the spinner/config tests still pass**

Run: `xcodebuild test ... -only-testing:UnitTests/FBRunLoopSpinnerTests -only-testing:UnitTests/FBConfigurationTests CODE_SIGNING_ALLOWED=NO`
Expected: BUILD OK, all listed tests PASS. (The synthesize path itself needs a real testmanagerd and is exercised by the existing integration suites + on-device validation, not unit tests.)

- [ ] **Step 7: Document the behavior**

In `docs/mobilerun-actions.md`, the `## Responses` section (starts line ~58) documents error responses. Append this bullet to that section:

```markdown
- `500 unknown error` is also returned when the synthesized event is not acknowledged by the
  system within the action's own duration plus a safety margin (default 15 s; tune with the
  `EVENT_SYNTHESIS_TIMEOUT_MARGIN` env var). This typically means the event delivery pipeline
  is overloaded — the request fails, but the agent keeps serving; clients should treat it as
  retryable or re-establish the runner.
```

- [ ] **Step 8: Commit**

```bash
git add WebDriverAgentLib/Utilities/FBConfiguration.h WebDriverAgentLib/Utilities/FBConfiguration.m \
  WebDriverAgentLib/Utilities/FBXCTestDaemonsProxy.m WebDriverAgentTests/UnitTests/FBConfigurationTests.m \
  docs/mobilerun-actions.md
git commit -m "feat: fail unacknowledged event synthesis with an error instead of blocking forever"
```

---

### Task 3: `FBRoute` control-queue flag

**Files:**
- Modify: `WebDriverAgentLib/Routing/FBRoute.h`
- Modify: `WebDriverAgentLib/Routing/FBRoute.m`
- Test: `WebDriverAgentTests/UnitTests/FBRouteTests.m`

**Interfaces:**
- Consumes: nothing new.
- Produces: `@property (nonatomic, assign, readonly) BOOL usesControlQueue;` and chainable `- (instancetype)onControlQueue;` on `FBRoute`. The flag must survive `withoutSession` and both `respondWithTarget:action:` / `respondWithBlock:` (those constructors create a **new** route object — the flag must be copied over, exactly like `requiresSession` is today). Task 4 reads `route.usesControlQueue`.

- [ ] **Step 1: Write the failing tests**

Append inside the existing `FBRouteTests` implementation in `WebDriverAgentTests/UnitTests/FBRouteTests.m`:

```objc
- (void)testControlQueueFlagDefaultsToNo
{
  FBRoute *route = [[FBRoute GET:@"/status"].withoutSession respondWithTarget:self action:@selector(description)];
  XCTAssertFalse(route.usesControlQueue);
}

- (void)testOnControlQueueSurvivesRespondWithTarget
{
  FBRoute *route = [[[FBRoute GET:@"/status"].withoutSession onControlQueue] respondWithTarget:self action:@selector(description)];
  XCTAssertTrue(route.usesControlQueue);
}

- (void)testOnControlQueueSurvivesRespondWithBlock
{
  FBRoute *route = [[[FBRoute POST:@"/probe"] onControlQueue] respondWithBlock:^ id<FBResponsePayload> (FBRouteRequest *request) {
    return nil;
  }];
  XCTAssertTrue(route.usesControlQueue);
}
```

If `FBRouteTests.m` does not already import `FBResponsePayload.h`, add `#import "FBResponsePayload.h"` and `#import "FBRouteRequest.h"` next to the existing imports.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test ... -only-testing:UnitTests/FBRouteTests CODE_SIGNING_ALLOWED=NO`
Expected: BUILD FAILURE — `property 'usesControlQueue' not found on object of type 'FBRoute *'`.

- [ ] **Step 3: Implement the flag**

`FBRoute.h` — add below the existing `path` property and next to the other chainable (`withoutSession` is declared further down; keep declarations adjacent to their kin):

```objc
/*! YES when the route is served directly on the HTTP connection's queue instead of the
    automation (main) queue */
@property (nonatomic, assign, readonly) BOOL usesControlQueue;
```

and next to the `withoutSession` declaration:

```objc
/**
 Chain-able modifier that marks the route to be served on the HTTP connection's own queue,
 bypassing the automation (main) queue. Only routes whose handlers never call XCUI or
 testmanagerd APIs and only touch thread-safe state may opt in — such routes stay responsive
 even while an automation request is blocked.
 */
- (instancetype)onControlQueue;
```

`FBRoute.m`:

1. In the class extension at the top, add:
   ```objc
   @property (nonatomic, assign, readwrite) BOOL usesControlQueue;
   ```
2. Next to `- (instancetype)withoutSession`, add:
   ```objc
   - (instancetype)onControlQueue
   {
     self.usesControlQueue = YES;
     return self;
   }
   ```
3. In `respondWithBlock:` and `respondWithTarget:action:`, copy the flag onto the newly created route (both methods build a fresh `FBRoute_Sync` / `FBRoute_TargetAction`):
   ```objc
   route.usesControlQueue = self.usesControlQueue;
   ```
   placed right after the existing property assignments in each method.

- [ ] **Step 4: Run the tests to verify they pass**

Run: same command as Step 2. Expected: all `FBRouteTests` PASS.

- [ ] **Step 5: Commit**

```bash
git add WebDriverAgentLib/Routing/FBRoute.h WebDriverAgentLib/Routing/FBRoute.m WebDriverAgentTests/UnitTests/FBRouteTests.m
git commit -m "feat: allow marking routes to be served off the automation queue"
```

---

### Task 4: HTTP layer split (per-connection queues + per-route dispatch)

**Files:**
- Modify: `WebDriverAgentLib/Vendor/CocoaHTTPServer/HTTPServer.m` (the `config` method, currently returning `[[HTTPConfig alloc] initWithServer:self documentRoot:documentRoot queue:connectionQueue]` around line 338)
- Modify: `WebDriverAgentLib/Routing/FBWebServer.m`
- Modify: `WebDriverAgentLib/Commands/FBUnknownCommands.m`
- Modify: `WebDriverAgentLib/Commands/FBSessionCommands.m` (the `/status` route registration)
- Modify: `WebDriverAgentLib/Commands/FBScreenCaptureCommands.m` (route registrations)
- Test: `WebDriverAgentTests/UnitTests/FBRouteTests.m` (add a **second test-case class** `FBWebServerDispatchTests` in the same file — no new file, to avoid pbxproj churn)

**Interfaces:**
- Consumes: `route.usesControlQueue` from Task 3.
- Produces: no new API. Behavioral contract for later tasks and the portal: control-marked routes respond while the main queue is busy; all other routes keep main-queue semantics.

- [ ] **Step 1: Write the failing dispatch tests**

Append to `WebDriverAgentTests/UnitTests/FBRouteTests.m` (after the `FBRouteTests` `@end`, as a separate test-case class):

```objc
#import <stdatomic.h>
#import "FBCommandHandler.h"
#import "FBWebServer.h"
#import "RoutingHTTPServer.h"

static atomic_bool gControlProbeDone;
static atomic_bool gControlProbeRanOffMain;
static atomic_bool gAutomationProbeDone;
static atomic_bool gAutomationProbeRanOnMain;

@interface FBWebServer (DispatchTests)
- (void)registerRouteHandlers:(NSArray *)commandHandlerClasses;
- (RoutingHTTPServer *)server;
@end

@interface FBDispatchProbeCommands : NSObject <FBCommandHandler>
@end

@implementation FBDispatchProbeCommands

+ (BOOL)shouldRegisterAutomatically
{
  return NO;
}

+ (NSArray *)routes
{
  return @[
    [[[FBRoute GET:@"/probe/control"].withoutSession onControlQueue] respondWithBlock:^ id<FBResponsePayload> (FBRouteRequest *request) {
      atomic_store(&gControlProbeRanOffMain, !NSThread.isMainThread);
      atomic_store(&gControlProbeDone, true);
      return FBResponseWithOK();
    }],
    [[FBRoute GET:@"/probe/automation"].withoutSession respondWithBlock:^ id<FBResponsePayload> (FBRouteRequest *request) {
      atomic_store(&gAutomationProbeRanOnMain, NSThread.isMainThread);
      atomic_store(&gAutomationProbeDone, true);
      return FBResponseWithOK();
    }],
  ];
}

@end

@interface FBWebServerDispatchTests : XCTestCase
@property (nonatomic, strong) FBWebServer *webServer;
@property (nonatomic, strong) RoutingHTTPServer *httpServer;
@property (nonatomic, assign) UInt16 port;
@end

@implementation FBWebServerDispatchTests

- (void)setUp
{
  [super setUp];
  atomic_store(&gControlProbeDone, false);
  atomic_store(&gControlProbeRanOffMain, false);
  atomic_store(&gAutomationProbeDone, false);
  atomic_store(&gAutomationProbeRanOnMain, false);

  self.webServer = [FBWebServer new];
  self.httpServer = [RoutingHTTPServer new];
  // Inject the server so route registration can be exercised without booting the full agent
  [self.webServer setValue:self.httpServer forKey:@"server"];
  [self.webServer registerRouteHandlers:@[FBDispatchProbeCommands.class]];
  [self.httpServer setPort:0];
  NSError *error;
  XCTAssertTrue([self.httpServer start:&error], @"%@", error);
  self.port = [self.httpServer listeningPort];
}

- (void)tearDown
{
  [self.httpServer stop:NO];
  self.httpServer = nil;
  self.webServer = nil;
  [super tearDown];
}

- (void)fireRequestForPath:(NSString *)path
{
  NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d%@", self.port, path]];
  [[[NSURLSession sharedSession] dataTaskWithURL:url] resume];
}

- (void)testControlRouteRespondsWhileMainThreadIsBusy
{
  [self fireRequestForPath:@"/probe/control"];
  // Sleeping keeps the main thread (and thus the automation queue) busy without servicing
  // the run loop — the control route must complete anyway, on another queue.
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
  while (!atomic_load(&gControlProbeDone) && deadline.timeIntervalSinceNow > 0) {
    [NSThread sleepForTimeInterval:0.05];
  }
  XCTAssertTrue(atomic_load(&gControlProbeDone));
  XCTAssertTrue(atomic_load(&gControlProbeRanOffMain));
}

- (void)testAutomationRouteRunsOnMainQueue
{
  [self fireRequestForPath:@"/probe/automation"];
  // Automation routes hop onto the main queue, so the run loop must be serviced
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
  while (!atomic_load(&gAutomationProbeDone) && deadline.timeIntervalSinceNow > 0) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  }
  XCTAssertTrue(atomic_load(&gAutomationProbeDone));
  XCTAssertTrue(atomic_load(&gAutomationProbeRanOnMain));
}

- (void)testControlRouteRespondsWhileAutomationRouteIsBlocked
{
  // The automation request will queue onto the main queue, which this test never services
  // while asserting — simulating a busy/wedged automation queue.
  [self fireRequestForPath:@"/probe/automation"];
  [NSThread sleepForTimeInterval:0.3];
  [self fireRequestForPath:@"/probe/control"];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
  while (!atomic_load(&gControlProbeDone) && deadline.timeIntervalSinceNow > 0) {
    [NSThread sleepForTimeInterval:0.05];
  }
  XCTAssertTrue(atomic_load(&gControlProbeDone), @"control route must answer while automation is blocked");
  XCTAssertFalse(atomic_load(&gAutomationProbeDone));
  // Drain the queued automation request so tearDown shuts down cleanly
  deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
  while (!atomic_load(&gAutomationProbeDone) && deadline.timeIntervalSinceNow > 0) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  }
  XCTAssertTrue(atomic_load(&gAutomationProbeDone));
}

@end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test ... -only-testing:UnitTests/FBWebServerDispatchTests CODE_SIGNING_ALLOWED=NO`
Expected: `testControlRouteRespondsWhileMainThreadIsBusy` and `testControlRouteRespondsWhileAutomationRouteIsBlocked` FAIL (today every route is dispatched to the main queue, which the sleep-poll never services; the requests are also serialized behind the shared connection queue). `testAutomationRouteRunsOnMainQueue` may already pass — that is expected: it pins today's semantics so the refactor cannot regress them.

- [ ] **Step 3: Implement per-connection queues**

In `WebDriverAgentLib/Vendor/CocoaHTTPServer/HTTPServer.m`, find the `config` method (returns the `HTTPConfig` with `queue:connectionQueue`) and change it to pass no queue:

```objc
- (HTTPConfig *)config
{
	// Override me if you want to provide a custom config to the new connection.
	//
	// Generally this involves overriding the HTTPConfig class to include any custom settings,
	// and then having this method return an instance of 'MyHTTPConfig'.

	// Note: Think you can make the server faster by putting each connection on its own queue?
	// Then benchmark it before and after and discover for yourself the shocking truth!
	//
	// Try the apache benchmark tool (already installed on your Mac):
	// $ ab -n 1000 -c 1 http://localhost:<port_number>/some_path.html

	// Each connection gets its own dispatch queue (HTTPConnection creates one when the config
	// carries none), so a request blocked on the automation queue cannot stall request parsing
	// and responses for every other connection.
	return [[HTTPConfig alloc] initWithServer:self documentRoot:documentRoot queue:NULL];
}
```

(Keep the surrounding comments if they differ slightly — the functional change is `queue:connectionQueue` → `queue:NULL`. Everything else about `connectionQueue` in that file stays: it is still used for the server's own bookkeeping.)

- [ ] **Step 4: Implement per-route dispatch in FBWebServer**

In `WebDriverAgentLib/Routing/FBWebServer.m`:

1. In `startHTTPServer`, restrict the global route queue to watchOS (the `FBWatchHTTPServer` keeps today's behavior; `RoutingHTTPServer` now gets per-route dispatch):

   ```objc
   #if TARGET_OS_WATCH
     [self.server setRouteQueue:dispatch_get_main_queue()];
   #endif
   ```

   (replacing the unconditional `[self.server setRouteQueue:dispatch_get_main_queue()];`)

2. Replace the registered block's mount portion in `registerRouteHandlers:` — the block body after `[FBLogger verboseLog:routeParams.description];` currently is:

   ```objc
   @try {
     [route mountRequest:routeParams intoResponse:response];
   }
   @catch (NSException *exception) {
     [strongSelf handleException:exception forResponse:response];
   }
   ```

   Replace it with:

   ```objc
   #if TARGET_OS_WATCH
     [strongSelf mountRoute:route request:routeParams intoResponse:response];
   #else
     if (route.usesControlQueue) {
       // Served on this connection's own queue so it stays responsive while the automation
       // queue is busy or blocked. Only routes that never touch XCUI state opt in.
       [strongSelf mountRoute:route request:routeParams intoResponse:response];
     } else {
       dispatch_sync(dispatch_get_main_queue(), ^{
         @autoreleasepool {
           [strongSelf mountRoute:route request:routeParams intoResponse:response];
         }
       });
     }
   #endif
   ```

3. Add the extracted mount helper next to `handleException:forResponse:`:

   ```objc
   - (void)mountRoute:(FBRoute *)route request:(FBRouteRequest *)routeParams intoResponse:(RouteResponse *)response
   {
     @try {
       [route mountRequest:routeParams intoResponse:response];
     }
     @catch (NSException *exception) {
       [self handleException:exception forResponse:response];
     }
   }
   ```

   `FBRoute` is already visible via `FBCommandHandler.h`/route usage; add `#import "FBRoute.h"` to the imports if the compiler complains.

4. In `registerServerKeyRouteHandlers`, the `/wda/shutdown` block currently calls the delegate inline. With no global route queue that block now runs on a connection queue while the delegate tears down XCUI state — hop the delegate call to the main queue asynchronously so the response is not held hostage by a busy automation queue:

   ```objc
   [self.server get:@"/wda/shutdown" withBlock:^(RouteRequest *request, RouteResponse *response) {
     __strong typeof(weakSelf) strongSelf = weakSelf;
     if (nil == strongSelf) {
       return;
     }
     [response respondWithString:@"Shutting down"];
     // The delegate tears down automation state; run it on the main queue without blocking
     // this connection's queue.
     dispatch_async(dispatch_get_main_queue(), ^{
       [strongSelf.delegate webServerDidRequestShutdown:strongSelf];
     });
   }];
   ```

   (`/health` and `/calibrate` need no change — they respond with static strings and are safe on the connection queue.)

- [ ] **Step 5: Mark the control routes**

1. `WebDriverAgentLib/Commands/FBUnknownCommands.m` — the fallback handler only builds an error payload; keep it responsive during a wedge. All four routes become:

   ```objc
   [[[FBRoute GET:@"/*"].withoutSession onControlQueue] respondWithTarget:self action:@selector(unhandledHandler:)],
   [[[FBRoute POST:@"/*"].withoutSession onControlQueue] respondWithTarget:self action:@selector(unhandledHandler:)],
   [[[FBRoute PUT:@"/*"].withoutSession onControlQueue] respondWithTarget:self action:@selector(unhandledHandler:)],
   [[[FBRoute DELETE:@"/*"].withoutSession onControlQueue] respondWithTarget:self action:@selector(unhandledHandler:)]
   ```

2. `WebDriverAgentLib/Commands/FBSessionCommands.m` — `/status` reads only bundle/env/UIDevice info and socket interfaces; mark it:

   ```objc
   [[[FBRoute GET:@"/status"].withoutSession onControlQueue] respondWithTarget:self action:@selector(handleGetStatus:)],
   ```

3. `WebDriverAgentLib/Commands/FBScreenCaptureCommands.m` — mark the pure video-manager routes (both the session and sessionless variants): `POST .../broadcast/stop` and `POST .../broadcast/start` **stay unmarked** (they drive the system broadcast picker via XCUI), and `POST /mobilerun/screencapture/start` **stays unmarked** (it touches `XCUIScreen`). Mark these with `onControlQueue` (wrap each existing registration as `[[[FBRoute ...] ...] onControlQueue]` keeping `withoutSession` where present):
   - `GET /mobilerun/screencapture/broadcast` (status read)
   - `POST /mobilerun/screencapture/stop`
   - `GET /mobilerun/screencapture`
   - `GET /mobilerun/screencapture/:id`
   - `POST /mobilerun/screencapture/:id/stop`
   - `POST /mobilerun/screencapture/:id/keyframe`

   Example for one line:

   ```objc
   [[[FBRoute POST:@"/mobilerun/screencapture/:id/keyframe"] onControlQueue] respondWithTarget:self action:@selector(handleRequestKeyFrame:)],
   ```

   Rationale to keep in mind (not as comments on every line): these handlers only touch `FBVideoStreamManager` / `FBBroadcastManager`, which are `@synchronized`- and serial-queue-protected and already run capture work off-main in production.

- [ ] **Step 6: Run the dispatch tests to verify they pass**

Run: `xcodebuild test ... -only-testing:UnitTests/FBWebServerDispatchTests -only-testing:UnitTests/FBRouteTests CODE_SIGNING_ALLOWED=NO`
Expected: all PASS — control probes answer with the main thread busy; the automation probe still runs on the main queue.

- [ ] **Step 7: Verify all platforms still build**

Run (fast sanity, generic destinations, no signing):

```bash
xcodebuild build -project WebDriverAgent.xcodeproj -scheme WebDriverAgentRunner -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project WebDriverAgent.xcodeproj -scheme WebDriverAgentRunner_tvOS -destination 'generic/platform=tvOS' CODE_SIGNING_ALLOWED=NO ARCHS=arm64
xcodebuild build -project WebDriverAgent.xcodeproj -scheme WebDriverAgentRunner_watchOS -destination 'generic/platform=watchOS' CODE_SIGNING_ALLOWED=NO ARCHS=arm64
```

Expected: all three BUILD SUCCEEDED (watchOS exercises the `TARGET_OS_WATCH` branches).

- [ ] **Step 8: Commit**

```bash
git add WebDriverAgentLib/Vendor/CocoaHTTPServer/HTTPServer.m WebDriverAgentLib/Routing/FBWebServer.m \
  WebDriverAgentLib/Commands/FBUnknownCommands.m WebDriverAgentLib/Commands/FBSessionCommands.m \
  WebDriverAgentLib/Commands/FBScreenCaptureCommands.m WebDriverAgentTests/UnitTests/FBRouteTests.m
git commit -m "feat: serve status and capture control routes off the automation queue"
```

---

### Task 5: Capture pixel cap (`maxPixels` + device-class default)

**Files:**
- Modify: `WebDriverAgentLib/Utilities/FBVideoStreamSession.h` (`FBScreenCaptureConfiguration` interface)
- Modify: `WebDriverAgentLib/Utilities/FBVideoStreamSession.m`
- Modify: `WebDriverAgentLib/Commands/FBScreenCaptureCommands.m` (`handleStartScreenCapture:`)
- Modify: `docs/mobilerun-screencapture.md`
- Test: `WebDriverAgentTests/UnitTests/FBVideoStreamSessionTests.m`

**Interfaces:**
- Consumes: nothing from other tasks (independent of Tasks 1–4).
- Produces (class methods on `FBScreenCaptureConfiguration`):
  - `+ (NSString *)fb_machineModel;` — raw device model identifier (e.g. `iPhone11,2`), sysctl-backed with a simulator fallback.
  - `+ (NSUInteger)fb_defaultPixelBudgetForMachineModel:(NSString *)machineModel;` — `370944` for iPhone majors ≤ 11, else `0` (no cap).
  - `+ (CGSize)fb_sizeForWidth:(NSUInteger)width height:(NSUInteger)height pixelBudget:(NSUInteger)budget;` — aspect-preserving, even-aligned clamp; returns the input unchanged when `budget == 0` or already within budget.

- [ ] **Step 1: Write the failing tests**

Append inside the existing test-case implementation in `WebDriverAgentTests/UnitTests/FBVideoStreamSessionTests.m` (add `#import "FBVideoStreamSession.h"` to its imports if not present):

```objc
- (void)testDefaultPixelBudgetForLegacyIPhones
{
  XCTAssertEqual([FBScreenCaptureConfiguration fb_defaultPixelBudgetForMachineModel:@"iPhone11,2"], (NSUInteger)370944);
  XCTAssertEqual([FBScreenCaptureConfiguration fb_defaultPixelBudgetForMachineModel:@"iPhone11,8"], (NSUInteger)370944);
  XCTAssertEqual([FBScreenCaptureConfiguration fb_defaultPixelBudgetForMachineModel:@"iPhone9,1"], (NSUInteger)370944);
}

- (void)testDefaultPixelBudgetForModernOrUnknownModels
{
  XCTAssertEqual([FBScreenCaptureConfiguration fb_defaultPixelBudgetForMachineModel:@"iPhone12,1"], (NSUInteger)0);
  XCTAssertEqual([FBScreenCaptureConfiguration fb_defaultPixelBudgetForMachineModel:@"iPhone17,3"], (NSUInteger)0);
  XCTAssertEqual([FBScreenCaptureConfiguration fb_defaultPixelBudgetForMachineModel:@"iPad8,1"], (NSUInteger)0);
  XCTAssertEqual([FBScreenCaptureConfiguration fb_defaultPixelBudgetForMachineModel:@"AppleTV11,1"], (NSUInteger)0);
  XCTAssertEqual([FBScreenCaptureConfiguration fb_defaultPixelBudgetForMachineModel:@""], (NSUInteger)0);
  XCTAssertEqual([FBScreenCaptureConfiguration fb_defaultPixelBudgetForMachineModel:@"iPhoneX"], (NSUInteger)0);
}

- (void)testPixelBudgetClampPreservesAspectAndAlignment
{
  CGSize capped = [FBScreenCaptureConfiguration fb_sizeForWidth:562 height:1218 pixelBudget:370944];
  XCTAssertLessThanOrEqual(capped.width * capped.height, 370944.0);
  XCTAssertEqualWithAccuracy(capped.width / capped.height, 562.0 / 1218.0, 0.02);
  XCTAssertEqual(((NSUInteger)capped.width) % 2, (NSUInteger)0);
  XCTAssertEqual(((NSUInteger)capped.height) % 2, (NSUInteger)0);
  XCTAssertGreaterThan(capped.width, 0.0);
}

- (void)testPixelBudgetLeavesSizesWithinBudgetAlone
{
  CGSize size = [FBScreenCaptureConfiguration fb_sizeForWidth:414 height:896 pixelBudget:370944];
  XCTAssertEqual(size.width, 414.0);
  XCTAssertEqual(size.height, 896.0);
}

- (void)testZeroPixelBudgetDisablesClamp
{
  CGSize size = [FBScreenCaptureConfiguration fb_sizeForWidth:5000 height:5000 pixelBudget:0];
  XCTAssertEqual(size.width, 5000.0);
  XCTAssertEqual(size.height, 5000.0);
}

- (void)testMachineModelIsNonNil
{
  XCTAssertNotNil([FBScreenCaptureConfiguration fb_machineModel]);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test ... -only-testing:UnitTests/FBVideoStreamSessionTests CODE_SIGNING_ALLOWED=NO`
Expected: BUILD FAILURE — `no known class method for selector 'fb_defaultPixelBudgetForMachineModel:'`.

- [ ] **Step 3: Implement the helpers**

`WebDriverAgentLib/Utilities/FBVideoStreamSession.h` — add to the `FBScreenCaptureConfiguration` interface (after the `port` property):

```objc
/**
 The raw device model identifier (e.g. 'iPhone11,2'), resolved via sysctl. On the simulator the
 simulated device's identifier is returned instead of the host architecture.
 */
+ (NSString *)fb_machineModel;

/**
 The pixel budget (maximum width*height) that is safe for sustained capture on the given device
 model, or 0 when the model has no default cap.
 */
+ (NSUInteger)fb_defaultPixelBudgetForMachineModel:(NSString *)machineModel;

/**
 Scales width/height down (aspect-preserving, rounded down to even values) until
 width*height <= budget. A budget of 0, a size already within budget, or a degenerate size is
 returned unchanged.
 */
+ (CGSize)fb_sizeForWidth:(NSUInteger)width height:(NSUInteger)height pixelBudget:(NSUInteger)budget;
```

`WebDriverAgentLib/Utilities/FBVideoStreamSession.m` — add `#import <sys/sysctl.h>` to the imports and implement inside the `FBScreenCaptureConfiguration` implementation block:

```objc
// 414x896 - the largest per-frame capture load verified safe for sustained 60 fps encoding on
// the oldest supported hardware class; larger frames make the system shed input events under
// load, which starves automation.
static const NSUInteger FBLegacyDevicePixelBudget = 370944;
// iPhone11,x is the A12 generation; every major version at or below it gets the budget.
static const NSInteger FBMaxLegacyIPhoneMajorVersion = 11;

+ (NSString *)fb_machineModel
{
#if TARGET_OS_SIMULATOR
  // On the simulator hw.machine reports the host architecture; the simulated device model is
  // exposed via the environment instead.
  NSString *simulatorModel = NSProcessInfo.processInfo.environment[@"SIMULATOR_MODEL_IDENTIFIER"];
  if (simulatorModel.length > 0) {
    return simulatorModel;
  }
#endif
  char machine[64] = {0};
  size_t size = sizeof(machine) - 1;
  if (0 == sysctlbyname("hw.machine", machine, &size, NULL, 0) && machine[0] != '\0') {
    return [NSString stringWithUTF8String:machine] ?: @"";
  }
  return @"";
}

+ (NSUInteger)fb_defaultPixelBudgetForMachineModel:(NSString *)machineModel
{
  static NSString *const prefix = @"iPhone";
  if (![machineModel hasPrefix:prefix]) {
    return 0;
  }
  NSScanner *scanner = [NSScanner scannerWithString:[machineModel substringFromIndex:prefix.length]];
  NSInteger major = 0;
  if (![scanner scanInteger:&major] || major <= 0) {
    return 0;
  }
  return major <= FBMaxLegacyIPhoneMajorVersion ? FBLegacyDevicePixelBudget : 0;
}

+ (CGSize)fb_sizeForWidth:(NSUInteger)width height:(NSUInteger)height pixelBudget:(NSUInteger)budget
{
  if (0 == budget || 0 == width || 0 == height || width * height <= budget) {
    return CGSizeMake(width, height);
  }
  double scale = sqrt((double)budget / (double)(width * height));
  // floor + even-align only ever shrink, so the scaled product stays within the budget
  NSUInteger scaledWidth = ((NSUInteger)floor((double)width * scale)) & ~(NSUInteger)1;
  NSUInteger scaledHeight = ((NSUInteger)floor((double)height * scale)) & ~(NSUInteger)1;
  return CGSizeMake(MAX(scaledWidth, (NSUInteger)2), MAX(scaledHeight, (NSUInteger)2));
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: same command as Step 2. Expected: all `FBVideoStreamSessionTests` PASS.

- [ ] **Step 5: Wire the cap into the start endpoint**

In `WebDriverAgentLib/Commands/FBScreenCaptureCommands.m`, `handleStartScreenCapture:` — after the existing `width`/`height` positive validation and **before** `FBScreenCaptureConfiguration *configuration = ...`, insert:

```objc
  NSUInteger pixelBudget = 0;
  id maxPixels = request.arguments[@"maxPixels"];
  if (nil == maxPixels) {
    pixelBudget = [FBScreenCaptureConfiguration fb_defaultPixelBudgetForMachineModel:[FBScreenCaptureConfiguration fb_machineModel]];
  } else if (![maxPixels isKindOfClass:NSNumber.class] || ((NSNumber *)maxPixels).integerValue < 0) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"'maxPixels' must be a non-negative integer (0 disables the capture size cap)" traceback:nil]);
  } else {
    pixelBudget = ((NSNumber *)maxPixels).unsignedIntegerValue;
  }
  CGSize cappedSize = [FBScreenCaptureConfiguration fb_sizeForWidth:(NSUInteger)width height:(NSUInteger)height pixelBudget:pixelBudget];
  if ((NSInteger)cappedSize.width < width || (NSInteger)cappedSize.height < height) {
    [FBLogger logFmt:@"Capping the requested capture size %ldx%ld to %ldx%ld (pixel budget %lu)",
     (long)width, (long)height, (long)cappedSize.width, (long)cappedSize.height, (unsigned long)pixelBudget];
    width = (NSInteger)cappedSize.width;
    height = (NSInteger)cappedSize.height;
  }
```

The existing even-alignment lines (`configuration.width = (NSUInteger)(width - (width % 2));` etc.) stay as they are and now operate on the capped values. Add `#import "FBLogger.h"` to the file's imports if it is not already there.

- [ ] **Step 6: Run the full unit bundle as a regression check**

Run: `xcodebuild test ... -only-testing:UnitTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS (entire `UnitTests` bundle).

- [ ] **Step 7: Document the argument**

`docs/mobilerun-screencapture.md`:

1. In the `## Start arguments (JSON body)` table, add a row after the `fps` row:

   ```markdown
   | `maxPixels` | int | no | device-dependent | Upper bound on `width×height`. Larger requests are scaled down aspect-preserving (rounded down to even). `0` disables the cap. When omitted, devices with an A12 chip or older default to `370944` (≈414×896); newer devices are uncapped. |
   ```

2. In `## Notes / gotchas`, add a bullet:

   ```markdown
   - When the cap shrinks the request, the session object and the stream's `VIDEO_PARAMS` carry
     the actual (capped) dimensions — consumers should always read those instead of assuming the
     requested size.
   ```

- [ ] **Step 8: Commit**

```bash
git add WebDriverAgentLib/Utilities/FBVideoStreamSession.h WebDriverAgentLib/Utilities/FBVideoStreamSession.m \
  WebDriverAgentLib/Commands/FBScreenCaptureCommands.m WebDriverAgentTests/UnitTests/FBVideoStreamSessionTests.m \
  docs/mobilerun-screencapture.md
git commit -m "feat: cap screen capture size via maxPixels with a safe default on older devices"
```

---

### Task 6: Full verification

**Files:** none new — verification only.

**Interfaces:** n/a.

- [ ] **Step 1: Run the complete unit test bundle**

Run: `xcodebuild test -project WebDriverAgent.xcodeproj -scheme WebDriverAgentRunner -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:UnitTests CODE_SIGNING_ALLOWED=NO`
Expected: all tests PASS.

- [ ] **Step 2: Build all three platforms**

```bash
xcodebuild build -project WebDriverAgent.xcodeproj -scheme WebDriverAgentRunner -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project WebDriverAgent.xcodeproj -scheme WebDriverAgentRunner_tvOS -destination 'generic/platform=tvOS' CODE_SIGNING_ALLOWED=NO ARCHS=arm64
xcodebuild build -project WebDriverAgent.xcodeproj -scheme WebDriverAgentRunner_watchOS -destination 'generic/platform=watchOS' CODE_SIGNING_ALLOWED=NO ARCHS=arm64
```

Expected: three times BUILD SUCCEEDED.

- [ ] **Step 3: Smoke the mobilerun actions integration suite on the simulator**

This exercises the real `/mobilerun/actions` → synthesize path (now running through the bounded wait) end to end:

```bash
xcodebuild test -project WebDriverAgent.xcodeproj -scheme IntegrationTests_3 \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:IntegrationTests_3/FBMobilerunActionsIntegrationTests CODE_SIGNING_ALLOWED=NO
```

Expected: PASS. (Known environment caveat: some unrelated tap-to-alert tests in this scheme fail on current simulators regardless of changes — only the mobilerun actions class is in scope here.)

- [ ] **Step 4: Verify the working tree is clean and every change is committed**

Run: `git status --short` → empty; `git log --oneline origin/master..HEAD` → the spec commit plus one commit per task.

- [ ] **Step 5: Hand off**

Implementation done. Next: superpowers:finishing-a-development-branch (PR against `droidrun/WebDriverAgent` master — always pass `--repo droidrun/WebDriverAgent` to `gh`, since bare `gh` targets the appium upstream). Keep the PR description generic: what changed and why at the mechanism level, no fleet/infra details. On-device fleet validation (sustained capture + hammer, portal-side probes) happens after merge and is tracked on the ticket, not in the PR.
