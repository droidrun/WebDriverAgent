/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <XCTest/XCTest.h>

#import "FBRoute.h"
#import "FBResponsePayload.h"
#import "FBRouteRequest.h"

@class RouteResponse;

extern BOOL FBSocks5ConnectTimeoutFromValue(id _Nullable value, NSTimeInterval *timeout);
extern NSArray *FBStandaloneRequestIdentity(NSString *method,
                                            NSString *pathAndQuery,
                                            NSData *body,
                                            NSString *_Nullable clientAddress);

@interface FBHandlerMock : NSObject
@property (nonatomic, assign) BOOL didCallSomeSelector;
@end

@implementation FBHandlerMock
- (id)someSelector:(id)arg
{
  self.didCallSomeSelector = YES;
  return nil;
};

@end

@interface FBRouteTests : XCTestCase
@end

@implementation FBRouteTests

- (void)testGetRoute
{
  FBRoute *route = [FBRoute GET:@"/"];
  XCTAssertEqualObjects(route.verb, @"GET");
}

- (void)testPostRoute
{
  FBRoute *route = [FBRoute POST:@"/"];
  XCTAssertEqualObjects(route.verb, @"POST");
}

- (void)testPutRoute
{
  FBRoute *route = [FBRoute PUT:@"/"];
  XCTAssertEqualObjects(route.verb, @"PUT");
}

- (void)testDeleteRoute
{
  FBRoute *route = [FBRoute DELETE:@"/"];
  XCTAssertEqualObjects(route.verb, @"DELETE");
}

- (void)testTargetAction
{
  FBHandlerMock *mock = [FBHandlerMock new];
  FBRoute *route = [[FBRoute new] respondWithTarget:mock action:@selector(someSelector:)];
  [route mountRequest:(id)NSObject.new intoResponse:(id)NSObject.new];
  XCTAssertTrue(mock.didCallSomeSelector);
}

- (void)testRespond
{
  XCTestExpectation *expectation = [self expectationWithDescription:@"Calling respond block works!"];
  FBRoute *route = [[FBRoute new] respondWithBlock:^id<FBResponsePayload>(FBRouteRequest *request) {
    [expectation fulfill];
    return nil;
  }];
  [route mountRequest:(id)NSObject.new intoResponse:(id)NSObject.new];
  [self waitForExpectationsWithTimeout:0.0 handler:nil];
}

- (void)testRouteWithSessionWithSlash
{
  FBRoute *route = [[FBRoute POST:@"/deactivateApp"] respondWithTarget:self action:@selector(dummyHandler:)];
  XCTAssertEqualObjects(route.path, @"/session/:sessionID/deactivateApp");
}

- (void)testRouteWithSession
{
  FBRoute *route = [[FBRoute POST:@"deactivateApp"] respondWithTarget:self action:@selector(dummyHandler:)];
  XCTAssertEqualObjects(route.path, @"/session/:sessionID/deactivateApp");
}

- (void)testRouteWithoutSessionWithSlash
{
  FBRoute *route = [[FBRoute POST:@"/deactivateApp"].withoutSession respondWithTarget:self action:@selector(dummyHandler:)];
  XCTAssertEqualObjects(route.path, @"/deactivateApp");
}

- (void)testRouteWithoutSession
{
  FBRoute *route = [[FBRoute POST:@"deactivateApp"].withoutSession respondWithTarget:self action:@selector(dummyHandler:)];
  XCTAssertEqualObjects(route.path, @"/deactivateApp");
}

- (void)testEmptyRouteWithSession
{
  FBRoute *route = [[FBRoute POST:@""] respondWithTarget:self action:@selector(dummyHandler:)];
  XCTAssertEqualObjects(route.path, @"/session/:sessionID");
}

- (void)testEmptyRouteWithoutSession
{
  FBRoute *route = [[FBRoute POST:@""].withoutSession respondWithTarget:self action:@selector(dummyHandler:)];
  XCTAssertEqualObjects(route.path, @"/");
}

- (void)testEmptyRouteWithSessionWithSlash
{
  FBRoute *route = [[FBRoute POST:@"/"] respondWithTarget:self action:@selector(dummyHandler:)];
  XCTAssertEqualObjects(route.path, @"/session/:sessionID");
}

- (void)testEmptyRouteWithoutSessionWithSlash
{
  FBRoute *route = [[FBRoute POST:@"/"].withoutSession respondWithTarget:self action:@selector(dummyHandler:)];
  XCTAssertEqualObjects(route.path, @"/");
}

- (void)testStandaloneFlagDefaultsToNo
{
  FBRoute *route = [[FBRoute GET:@"/status"].withoutSession respondWithTarget:self action:@selector(description)];
  XCTAssertFalse(route.isStandalone);
}

- (void)testStandaloneSurvivesRespondWithTarget
{
  FBRoute *route = [[FBRoute GET:@"/status"].withoutSession.standalone respondWithTarget:self action:@selector(description)];
  XCTAssertTrue(route.isStandalone);
}

- (void)testStandaloneSurvivesRespondWithBlock
{
  FBRoute *route = [[FBRoute POST:@"/probe"].standalone respondWithBlock:^ id<FBResponsePayload> (FBRouteRequest *request) {
    return nil;
  }];
  XCTAssertTrue(route.isStandalone);
}

- (void)testRequestDescriptionRedactsSocks5Credentials
{
  FBRouteRequest *request = [FBRouteRequest
    routeRequestWithURL:[NSURL URLWithString:@"/mobilerun/socks5/connect"]
    parameters:@{}
    arguments:@{
      @"uri": @"socks5://alice:secret@proxy.example.com:1080",
      @"timeout": @5,
    }];

  NSString *description = request.description;
  XCTAssertFalse([description containsString:@"alice"]);
  XCTAssertFalse([description containsString:@"secret"]);
  XCTAssertTrue([description containsString:@"proxy.example.com:1080"]);
  XCTAssertTrue([description containsString:@"timeout"]);
  XCTAssertTrue([description containsString:@"5"]);
}

- (void)testRequestDescriptionRedactsCredentialsFromMalformedProxyURIs
{
  for (NSString *uriString in @[
    @"socks5x://alice:secret@proxy.example.com:1080",
    @" socks5://alice:secret@proxy.example.com:1080",
    @"socks5:alice:secret@proxy.example.com",
  ]) {
    FBRouteRequest *request = [FBRouteRequest
      routeRequestWithURL:[NSURL URLWithString:@"/mobilerun/socks5/connect"]
      parameters:@{}
      arguments:@{@"uri": uriString}];

    NSString *description = request.description;
    XCTAssertFalse([description containsString:@"alice"], @"%@", description);
    XCTAssertFalse([description containsString:@"secret"], @"%@", description);
    XCTAssertTrue([description containsString:@"proxy.example.com"], @"%@", description);
  }
}

- (void)testRequestDescriptionAcceptsArrayArguments
{
  NSArray *arguments = @[
    @{
      @"type": @"pointerDown",
      @"uri": @"https://alice:secret@example.com/path",
    },
  ];
  FBRouteRequest *request = [FBRouteRequest
    routeRequestWithURL:[NSURL URLWithString:@"/mobilerun/actions"]
    parameters:@{}
    arguments:(NSDictionary *)(id)arguments];

  NSString *description = request.description;
  XCTAssertFalse([description containsString:@"alice"]);
  XCTAssertFalse([description containsString:@"secret"]);
  XCTAssertTrue([description containsString:@"example.com/path"]);
  XCTAssertTrue([description containsString:@"pointerDown"]);
}

- (void)testSocks5ConnectTimeoutIsFiniteAndBounded
{
  NSTimeInterval timeout = 0;
  XCTAssertTrue(FBSocks5ConnectTimeoutFromValue(nil, &timeout));
  XCTAssertEqual(timeout, 30.0);
  XCTAssertTrue(FBSocks5ConnectTimeoutFromValue(@300, &timeout));
  XCTAssertEqual(timeout, 300.0);

  for (NSNumber *invalid in @[@0, @(-1), @301, @(1e308), @(INFINITY), @(NAN), @YES]) {
    XCTAssertFalse(FBSocks5ConnectTimeoutFromValue(invalid, &timeout), @"%@ should be rejected", invalid);
  }
  XCTAssertFalse(FBSocks5ConnectTimeoutFromValue(@"30", &timeout));
}

- (void)testStandaloneRequestIdentityIncludesControllerAddress
{
  NSData *body = [@"same" dataUsingEncoding:NSUTF8StringEncoding];
  NSArray *first = FBStandaloneRequestIdentity(@"POST", @"/mobilerun/socks5/connect", body, @"192.0.2.10");
  NSArray *second = FBStandaloneRequestIdentity(@"POST", @"/mobilerun/socks5/connect", body, @"192.0.2.11");
  NSArray *sameAsFirst = FBStandaloneRequestIdentity(@"POST", @"/mobilerun/socks5/connect", body, @"192.0.2.10");

  XCTAssertNotEqualObjects(first, second);
  XCTAssertEqualObjects(first, sameAsFirst);
}

+ (id<FBResponsePayload>)dummyHandler:(FBRouteRequest *)request
{
  return nil;
}

@end

#import <stdatomic.h>
#import "FBCommandHandler.h"
#import "FBWebServer.h"
#import "FBHTTPServer.h"

static atomic_bool gControlProbeDone;
static atomic_bool gControlProbeRanOffMain;
static NSString *gControlProbeClientAddress;
static atomic_bool gAutomationProbeDone;
static atomic_bool gAutomationProbeRanOnMain;
static atomic_int gSpinningProbeDepth;
static atomic_int gSpinningProbeMaxDepth;
static atomic_int gSpinningProbeCompletions;

@interface FBWebServer (DispatchTests)
+ (dispatch_queue_t)automationFunnelQueue;
+ (BOOL)performAutomationBlockOnMainQueue:(dispatch_block_t)block
                                beforeDate:(NSDate *)deadline;
- (void)registerRouteHandlers:(NSArray *)commandHandlerClasses;
- (void)registerServerKeyRouteHandlers;
- (FBHTTPServer *)server;
@property (nonatomic, strong) dispatch_queue_t automationQueue;
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
    [[FBRoute GET:@"/probe/control"].withoutSession.standalone respondWithBlock:^ id<FBResponsePayload> (FBRouteRequest *request) {
      gControlProbeClientAddress = request.clientAddress;
      atomic_store(&gControlProbeRanOffMain, !NSThread.isMainThread);
      atomic_store(&gControlProbeDone, true);
      return FBResponseWithOK();
    }],
    [[FBRoute GET:@"/probe/automation"].withoutSession respondWithBlock:^ id<FBResponsePayload> (FBRouteRequest *request) {
      atomic_store(&gAutomationProbeRanOnMain, NSThread.isMainThread);
      atomic_store(&gAutomationProbeDone, true);
      return FBResponseWithOK();
    }],
    // Not control-marked: goes through the automation funnel like any other automation route.
    // Records the max nesting depth observed while it spins the main run loop, so a test can
    // pin that a second concurrent automation request never executes reentrantly inside this one.
    [[FBRoute GET:@"/probe/spinning"].withoutSession respondWithBlock:^ id<FBResponsePayload> (FBRouteRequest *request) {
      int depth = atomic_fetch_add(&gSpinningProbeDepth, 1) + 1;
      int prevMax = atomic_load(&gSpinningProbeMaxDepth);
      while (depth > prevMax && !atomic_compare_exchange_weak(&gSpinningProbeMaxDepth, &prevMax, depth)) {
        // retry until either our depth is recorded or another thread recorded a higher one
      }
      [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
      atomic_fetch_sub(&gSpinningProbeDepth, 1);
      atomic_fetch_add(&gSpinningProbeCompletions, 1);
      return FBResponseWithOK();
    }],
  ];
}

@end

@interface FBWebServerDispatchTests : XCTestCase
@property (nonatomic, strong) FBWebServer *webServer;
@property (nonatomic, strong) FBHTTPServer *httpServer;
@property (nonatomic, assign) UInt16 port;
@end

@implementation FBWebServerDispatchTests

- (void)setUp
{
  [super setUp];
  atomic_store(&gControlProbeDone, false);
  atomic_store(&gControlProbeRanOffMain, false);
  gControlProbeClientAddress = nil;
  atomic_store(&gAutomationProbeDone, false);
  atomic_store(&gAutomationProbeRanOnMain, false);
  atomic_store(&gSpinningProbeDepth, 0);
  atomic_store(&gSpinningProbeMaxDepth, 0);
  atomic_store(&gSpinningProbeCompletions, 0);

  self.webServer = [FBWebServer new];
  // startHTTPServer (unused by this test, see below) is normally what creates these; wire them
  // up manually since automation routes are invoked on the funnel (the server's routeQueue).
  self.webServer.automationQueue = dispatch_queue_create("com.facebook.WebDriverAgent.test-automation-funnel", DISPATCH_QUEUE_SERIAL);
  self.httpServer = [FBHTTPServer new];
  [self.httpServer setRouteQueue:self.webServer.automationQueue];
  // Inject the server so route registration can be exercised without booting the full agent
  [self.webServer setValue:self.httpServer forKey:@"server"];
  [self.webServer registerRouteHandlers:@[FBDispatchProbeCommands.class]];
  // Registered after the probes, so the wildcard fallbacks it also installs cannot shadow them.
  [self.webServer registerServerKeyRouteHandlers];
  self.httpServer.port = 0;
  NSError *error;
  XCTAssertTrue([self.httpServer start:&error], @"%@", error);
  // FBHTTPServer's own `port` stays 0 for an ephemeral bind; the socket knows the real one.
  self.port = [[self.httpServer valueForKeyPath:@"socket.port"] unsignedShortValue];
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

// Fires a GET and waits for the body without servicing the run loop, so the main queue - and
// therefore the automation funnel that hops onto it - stays blocked for the whole call.
- (NSString *)synchronousGetForPath:(NSString *)path timeout:(NSTimeInterval)timeout
{
  NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d%@", self.port, path]];
  __block NSString *body = nil;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  [[NSURLSession.sharedSession dataTaskWithURL:url
                              completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    if (nil != data) {
      body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }
    dispatch_semaphore_signal(sem);
  }] resume];
  dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
  return body;
}

- (void)testHealthRouteRespondsWhileAutomationQueueIsWedged
{
  // /health exists to answer when automation is stuck, so it must not be registered on the
  // funnel: queueing it behind the wedged request it is meant to diagnose would make it useless.
  // Same reasoning covers /wda/shutdown, which is the way out of this state.
  [self fireRequestForPath:@"/probe/automation"];
  [NSThread sleepForTimeInterval:0.3];

  NSString *body = [self synchronousGetForPath:@"/health" timeout:10.0];
  XCTAssertTrue([body containsString:@"I-AM-ALIVE"], @"/health must answer off the funnel: %@", body);
  XCTAssertFalse(atomic_load(&gAutomationProbeDone), @"the automation queue must still be wedged");

  // Drain the queued automation request so tearDown shuts down cleanly.
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15.0];
  while (!atomic_load(&gAutomationProbeDone) && deadline.timeIntervalSinceNow > 0) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  }
  XCTAssertTrue(atomic_load(&gAutomationProbeDone));
}

- (void)testControlRouteRespondsWhileMainThreadIsBusy
{
  [self fireRequestForPath:@"/probe/control"];
  // Sleeping keeps the main thread (and thus the automation queue) busy without servicing
  // the run loop — the control route must complete anyway, on another queue.
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15.0];
  while (!atomic_load(&gControlProbeDone) && deadline.timeIntervalSinceNow > 0) {
    [NSThread sleepForTimeInterval:0.05];
  }
  XCTAssertTrue(atomic_load(&gControlProbeDone));
  XCTAssertTrue(atomic_load(&gControlProbeRanOffMain));
  XCTAssertEqualObjects(gControlProbeClientAddress, @"127.0.0.1");
}

- (void)testAutomationRouteRunsOnMainQueue
{
  [self fireRequestForPath:@"/probe/automation"];
  // Automation routes hop onto the main queue, so the run loop must be serviced
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15.0];
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
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15.0];
  while (!atomic_load(&gControlProbeDone) && deadline.timeIntervalSinceNow > 0) {
    [NSThread sleepForTimeInterval:0.05];
  }
  XCTAssertTrue(atomic_load(&gControlProbeDone), @"control route must answer while automation is blocked");
  XCTAssertFalse(atomic_load(&gAutomationProbeDone));
  // Drain the queued automation request so tearDown shuts down cleanly
  deadline = [NSDate dateWithTimeIntervalSinceNow:15.0];
  while (!atomic_load(&gAutomationProbeDone) && deadline.timeIntervalSinceNow > 0) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  }
  XCTAssertTrue(atomic_load(&gAutomationProbeDone));
}

- (void)testAutomationRequestsDoNotNestInsideRunLoopSpin
{
  // Fire two automation requests close together. The first spins the main run loop inside its
  // handler; without the automation funnel a nested run loop drain would let the second
  // handler execute reentrantly inside the first (depth 2). With the funnel, the second
  // request waits on the serial funnel queue until the first finishes on main (depth 1).
  // The 0.3 s gap lets the first request get through the server and enqueued at the funnel
  // before the second fires, even on a loaded runner (the handler itself only starts once the
  // wait loop below spins the run loop), while the probe's 1.0 s spin keeps the second request
  // well inside the first's spin window.
  [self fireRequestForPath:@"/probe/spinning"];
  [NSThread sleepForTimeInterval:0.3];
  [self fireRequestForPath:@"/probe/spinning"];

  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20.0];
  while (atomic_load(&gSpinningProbeCompletions) < 2 && deadline.timeIntervalSinceNow > 0) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  }

  XCTAssertEqual(atomic_load(&gSpinningProbeCompletions), 2, @"both spinning requests must complete");
  XCTAssertEqual(atomic_load(&gSpinningProbeMaxDepth), 1, @"a second automation request must never nest inside the first");
}

- (void)testAutomationFunnelDeadlineCancelsQueuedBlock
{
  dispatch_semaphore_t funnelEntered = dispatch_semaphore_create(0);
  dispatch_semaphore_t releaseFunnel = dispatch_semaphore_create(0);
  dispatch_async(FBWebServer.automationFunnelQueue, ^{
    dispatch_semaphore_signal(funnelEntered);
    dispatch_semaphore_wait(releaseFunnel, DISPATCH_TIME_FOREVER);
  });
  XCTAssertEqual(dispatch_semaphore_wait(funnelEntered, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)), 0L);

  __block volatile atomic_bool blockRan;
  atomic_init(&blockRan, false);
  __block BOOL acquired = YES;
  __block NSTimeInterval elapsed = 0;
  XCTestExpectation *returned = [self expectationWithDescription:@"deadline-aware funnel acquisition returned"];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
    NSDate *startedAt = NSDate.date;
    acquired = [FBWebServer performAutomationBlockOnMainQueue:^{
      atomic_store(&blockRan, true);
    } beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    elapsed = -startedAt.timeIntervalSinceNow;
    [returned fulfill];
  });

  [self waitForExpectations:@[returned] timeout:1.0];
  XCTAssertFalse(acquired);
  XCTAssertLessThan(elapsed, 0.75);
  XCTAssertFalse(atomic_load(&blockRan));

  XCTestExpectation *funnelDrained = [self expectationWithDescription:@"cancelled funnel block drained"];
  dispatch_semaphore_signal(releaseFunnel);
  dispatch_async(FBWebServer.automationFunnelQueue, ^{
    [funnelDrained fulfill];
  });
  [self waitForExpectations:@[funnelDrained] timeout:1.0];
  XCTAssertFalse(atomic_load(&blockRan), @"an expired queued block must not execute later");
}

- (void)testAutomationFunnelRethrowsExceptionOnCallerQueue
{
  NSException *expectedException = [NSException exceptionWithName:@"FBExpectedAutomationException"
                                                            reason:@"synthetic XCUI failure"
                                                          userInfo:nil];
  __block NSException *caughtException = nil;
  XCTestExpectation *returned = [self expectationWithDescription:@"automation exception returned to caller queue"];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
    @try {
      [FBWebServer performAutomationBlockOnMainQueue:^{
        @throw expectedException;
      }];
    } @catch (NSException *exception) {
      caughtException = exception;
    }
    [returned fulfill];
  });

  [self waitForExpectations:@[returned] timeout:2.0];
  XCTAssertEqual(caughtException, expectedException);
}

- (void)testDeadlineAutomationFunnelRethrowsExceptionOnCallerQueue
{
  NSException *expectedException = [NSException exceptionWithName:@"FBExpectedDeadlineAutomationException"
                                                            reason:@"synthetic consent query failure"
                                                          userInfo:nil];
  __block NSException *caughtException = nil;
  XCTestExpectation *returned = [self expectationWithDescription:@"deadline automation exception returned to caller queue"];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
    @try {
      [FBWebServer performAutomationBlockOnMainQueue:^{
        @throw expectedException;
      } beforeDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
    } @catch (NSException *exception) {
      caughtException = exception;
    }
    [returned fulfill];
  });

  [self waitForExpectations:@[returned] timeout:2.0];
  XCTAssertEqual(caughtException, expectedException);
}

@end

#import <arpa/inet.h>
#import <sys/socket.h>
#import <unistd.h>

static atomic_int gFramingProbeHits;
static atomic_int gStandaloneBodyProbeHits;
static dispatch_semaphore_t gStandaloneFirstBodyEntered;
static dispatch_semaphore_t gStandaloneReleaseFirstBody;

// Exercises FBHTTPServer's HTTP framing defenses with raw socket data that URL-loading APIs
// cannot produce: malformed Content-Length values and header blocks that never terminate.
@interface FBHTTPServerFramingTests : XCTestCase
@property (nonatomic, strong) FBHTTPServer *server;
@property (nonatomic, assign) uint16_t port;
@end

@implementation FBHTTPServerFramingTests

- (void)setUp
{
  [super setUp];
  atomic_store(&gFramingProbeHits, 0);
  atomic_store(&gStandaloneBodyProbeHits, 0);
  gStandaloneFirstBodyEntered = dispatch_semaphore_create(0);
  gStandaloneReleaseFirstBody = dispatch_semaphore_create(0);
  self.server = [FBHTTPServer new];
  [self.server handleMethod:@"POST" withPath:@"/framing/probe" block:^(RouteRequest *request, RouteResponse *response) {
    atomic_fetch_add(&gFramingProbeHits, 1);
    [response respondWithString:@"probe-ok"];
  }];
  [self.server get:@"/framing/ping" withBlock:^(RouteRequest *request, RouteResponse *response) {
    [response respondWithString:@"pong"];
  }];
  [self.server get:@"/session/:sessionID/framing/probe" withBlock:^(RouteRequest *request, RouteResponse *response) {
    atomic_fetch_add(&gFramingProbeHits, 1);
    [response respondWithString:@"session-probe-ok"];
  }];
  [self.server handleMethod:@"POST" withPath:@"/standalone/body" standalone:YES block:^(RouteRequest *request, RouteResponse *response) {
    atomic_fetch_add(&gStandaloneBodyProbeHits, 1);
    NSString *body = [[NSString alloc] initWithData:request.body encoding:NSUTF8StringEncoding] ?: @"";
    if ([body isEqualToString:@"first"]) {
      dispatch_semaphore_signal(gStandaloneFirstBodyEntered);
      dispatch_semaphore_wait(gStandaloneReleaseFirstBody, DISPATCH_TIME_FOREVER);
    }
    [response respondWithString:body];
  }];
  self.server.port = 0;
  NSError *error;
  XCTAssertTrue([self.server start:&error], @"%@", error);
  self.port = [[self.server valueForKeyPath:@"socket.port"] unsignedShortValue];
}

- (void)tearDown
{
  [self.server stop:NO];
  self.server = nil;
  [super tearDown];
}

- (void)testStandaloneRequestsWithDifferentBodiesAreNotCoalesced
{
  NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d/standalone/body", self.port]];
  NSMutableURLRequest *firstRequest = [NSMutableURLRequest requestWithURL:url];
  firstRequest.HTTPMethod = @"POST";
  firstRequest.HTTPBody = [@"first" dataUsingEncoding:NSUTF8StringEncoding];
  NSMutableURLRequest *secondRequest = [NSMutableURLRequest requestWithURL:url];
  secondRequest.HTTPMethod = @"POST";
  secondRequest.HTTPBody = [@"second" dataUsingEncoding:NSUTF8StringEncoding];

  XCTestExpectation *firstResponse = [self expectationWithDescription:@"first standalone response"];
  XCTestExpectation *secondResponse = [self expectationWithDescription:@"second standalone response"];
  __block NSString *firstBody = nil;
  __block NSString *secondBody = nil;
  [[NSURLSession.sharedSession dataTaskWithRequest:firstRequest completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    firstBody = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    [firstResponse fulfill];
  }] resume];
  XCTAssertEqual(0, dispatch_semaphore_wait(gStandaloneFirstBodyEntered,
                                             dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)));

  [[NSURLSession.sharedSession dataTaskWithRequest:secondRequest completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    secondBody = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    [secondResponse fulfill];
  }] resume];
  NSDate *secondHandlerDeadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
  while (atomic_load(&gStandaloneBodyProbeHits) < 2 && secondHandlerDeadline.timeIntervalSinceNow > 0) {
    [NSThread sleepForTimeInterval:0.01];
  }
  dispatch_semaphore_signal(gStandaloneReleaseFirstBody);

  [self waitForExpectations:@[firstResponse, secondResponse] timeout:5.0];
  XCTAssertEqual(atomic_load(&gStandaloneBodyProbeHits), 2);
  XCTAssertEqualObjects(firstBody, @"first");
  XCTAssertEqualObjects(secondBody, @"second");
}

// Sends `payload` as-is and reads until the server closes the connection or `timeout` elapses.
// Returns everything received (nil on connect failure); *didClose reports whether EOF was seen.
- (NSString *)responseForRawPayload:(NSData *)payload timeout:(NSTimeInterval)timeout didClose:(BOOL *)didClose
{
  *didClose = NO;
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) {
    return nil;
  }
  int noSigpipe = 1;
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, sizeof(noSigpipe));
  struct timeval tv = { .tv_sec = (long)timeout, .tv_usec = 0 };
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
  struct sockaddr_in addr = { .sin_family = AF_INET, .sin_port = htons(self.port) };
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (0 != connect(fd, (struct sockaddr *)&addr, sizeof(addr))) {
    close(fd);
    return nil;
  }
  // send(2) may write only part of the payload, which would truncate the multi-KiB flood
  // payloads into something the server answers differently. Errors stay ignored on purpose:
  // those same tests expect the server to close the connection mid-send.
  const uint8_t *bytes = payload.bytes;
  size_t remaining = payload.length;
  while (remaining > 0) {
    ssize_t sent = send(fd, bytes, remaining, 0);
    if (sent <= 0) {
      break;
    }
    bytes += sent;
    remaining -= (size_t)sent;
  }
  NSMutableData *received = [NSMutableData data];
  char chunk[4096];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  while (deadline.timeIntervalSinceNow > 0) {
    ssize_t n = recv(fd, chunk, sizeof(chunk), 0);
    if (n == 0) {
      *didClose = YES;
      break;
    }
    if (n < 0) {
      // A read timeout. Only stop waiting once the response is a keep-alive success, where no
      // EOF is ever coming; every other response precedes a close, and giving up here would
      // report didClose = NO for a connection the server is about to drop.
      NSString *soFar = [[NSString alloc] initWithData:received encoding:NSUTF8StringEncoding] ?: @"";
      if ([soFar containsString:@"HTTP/1.1 200"]) {
        break;
      }
      continue;
    }
    [received appendBytes:chunk length:(NSUInteger)n];
    // The response has started arriving; poll in short slices from here so a keep-alive success
    // doesn't sit out the whole timeout waiting for an EOF that never comes.
    struct timeval drainTv = { .tv_sec = 0, .tv_usec = 200000 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &drainTv, sizeof(drainTv));
  }
  close(fd);
  return [[NSString alloc] initWithData:received encoding:NSUTF8StringEncoding] ?: @"";
}

- (void)testWellFormedRequestStillSucceeds
{
  BOOL didClose;
  NSString *response = [self responseForRawPayload:(NSData * _Nonnull)[@"GET /framing/ping HTTP/1.1\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]
                                            timeout:5.0
                                           didClose:&didClose];
  XCTAssertTrue([response containsString:@"200"], @"%@", response);
  XCTAssertTrue([response containsString:@"pong"], @"%@", response);
}

- (void)testNonNumericContentLengthIsRejected
{
  // Under -integerValue's lenient parsing "bogus" became 0: the probe route would run with an
  // empty body and the smuggled GET below would be answered as a second pipelined request.
  NSString *payload = @"POST /framing/probe HTTP/1.1\r\nContent-Length: bogus\r\n\r\nGET /framing/ping HTTP/1.1\r\n\r\n";
  BOOL didClose;
  NSString *response = [self responseForRawPayload:(NSData * _Nonnull)[payload dataUsingEncoding:NSUTF8StringEncoding]
                                            timeout:5.0
                                           didClose:&didClose];
  XCTAssertTrue([response containsString:@"400"], @"%@", response);
  XCTAssertFalse([response containsString:@"pong"], @"the smuggled request must not be answered: %@", response);
  XCTAssertTrue(didClose, @"the connection must be closed after unparseable framing");
  XCTAssertEqual(atomic_load(&gFramingProbeHits), 0, @"the route must not be dispatched with unknown body extent");
}

- (void)testWhitespaceBeforeHeaderColonIsRejected
{
  // RFC 7230 (3.2.4): whitespace between a field name and its colon MUST be rejected with a 400.
  // Tolerating it stores "content-length " as a distinct key, dispatches the request with a
  // zero-length body, and re-parses the declared body as a smuggled pipelined request.
  NSString *payload = @"POST /framing/probe HTTP/1.1\r\nContent-Length : 5\r\n\r\nhello";
  BOOL didClose;
  NSString *response = [self responseForRawPayload:(NSData * _Nonnull)[payload dataUsingEncoding:NSUTF8StringEncoding]
                                            timeout:5.0
                                           didClose:&didClose];
  XCTAssertTrue([response containsString:@"400"], @"%@", response);
  XCTAssertTrue(didClose);
  XCTAssertEqual(atomic_load(&gFramingProbeHits), 0);
}

- (void)testHeaderLineWithoutColonIsRejected
{
  // Silently skipping the malformed line made this dispatch with an empty body while "hello"
  // stayed in the buffer to be parsed as the next request.
  NSString *payload = @"POST /framing/probe HTTP/1.1\r\nContent-Length 5\r\n\r\nhello";
  BOOL didClose;
  NSString *response = [self responseForRawPayload:(NSData * _Nonnull)[payload dataUsingEncoding:NSUTF8StringEncoding]
                                            timeout:5.0
                                           didClose:&didClose];
  XCTAssertTrue([response containsString:@"400"], @"%@", response);
  XCTAssertTrue(didClose);
  XCTAssertEqual(atomic_load(&gFramingProbeHits), 0);
}

- (void)testDuplicateContentLengthIsRejected
{
  // RFC 7230 (3.3.3): repeated framing fields are unrecoverable. Last-wins assignment would let
  // the second value drive parsing while an intermediary used the first - a smuggling primitive.
  NSString *payload = @"POST /framing/probe HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 0\r\n\r\nhello";
  BOOL didClose;
  NSString *response = [self responseForRawPayload:(NSData * _Nonnull)[payload dataUsingEncoding:NSUTF8StringEncoding]
                                            timeout:5.0
                                           didClose:&didClose];
  XCTAssertTrue([response containsString:@"400"], @"%@", response);
  XCTAssertTrue(didClose);
  XCTAssertEqual(atomic_load(&gFramingProbeHits), 0);
}

- (void)testEmptyTransferEncodingIsRejected
{
  // "chunked" followed by an empty value: with last-wins assignment plus a non-empty presence
  // check, the empty value used to make the header look absent, so the chunked body was parsed
  // as a zero-length body and its bytes re-read as smuggled requests.
  NSString *payload = @"POST /framing/probe HTTP/1.1\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: \r\n\r\n0\r\n\r\n";
  BOOL didClose;
  NSString *response = [self responseForRawPayload:(NSData * _Nonnull)[payload dataUsingEncoding:NSUTF8StringEncoding]
                                            timeout:5.0
                                           didClose:&didClose];
  XCTAssertTrue([response containsString:@"400"] || [response containsString:@"501"], @"%@", response);
  XCTAssertTrue(didClose);
  XCTAssertEqual(atomic_load(&gFramingProbeHits), 0);
}

- (void)testRequestForAlreadyAbandonedSessionIsRejectedImmediately
{
  // A request parsed *after* DELETE /session tore the session down would never receive an
  // abandonment notification of its own, so before this was tracked it queued on the route
  // queue - potentially forever, if that queue is wedged behind the stuck request that made
  // the client delete the session in the first place.
  RouteResponse *abandonedResponse = [RouteResponse new];
  [abandonedResponse respondWithString:@"session-was-deleted"];
  [self.server abandonPendingRequestsForSessionID:@"dead-session" withResponse:abandonedResponse];

  BOOL didClose;
  NSString *response = [self responseForRawPayload:(NSData * _Nonnull)[@"GET /session/dead-session/framing/probe HTTP/1.1\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]
                                            timeout:5.0
                                           didClose:&didClose];
  XCTAssertTrue([response containsString:@"session-was-deleted"], @"%@", response);
  XCTAssertEqual(atomic_load(&gFramingProbeHits), 0, @"the route must not run for a deleted session");
}

- (void)testRequestForLiveSessionIsStillServed
{
  // The rejection above must be scoped to the abandoned identifier only.
  RouteResponse *abandonedResponse = [RouteResponse new];
  [abandonedResponse respondWithString:@"session-was-deleted"];
  [self.server abandonPendingRequestsForSessionID:@"dead-session" withResponse:abandonedResponse];

  BOOL didClose;
  NSString *response = [self responseForRawPayload:(NSData * _Nonnull)[@"GET /session/live-session/framing/probe HTTP/1.1\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]
                                            timeout:5.0
                                           didClose:&didClose];
  XCTAssertTrue([response containsString:@"session-probe-ok"], @"%@", response);
  XCTAssertEqual(atomic_load(&gFramingProbeHits), 1);
}

- (void)testPipelinedRequestsAreServedInOrder
{
  // Two requests in one payload: both must be answered on the same connection. Guards the
  // response backpressure logic - the next pipelined request is only processed once the
  // previous response's send completed, which must not stall or reorder the pipeline.
  NSString *payload = @"GET /framing/ping HTTP/1.1\r\n\r\nGET /framing/ping HTTP/1.1\r\n\r\n";
  BOOL didClose;
  NSString *response = [self responseForRawPayload:(NSData * _Nonnull)[payload dataUsingEncoding:NSUTF8StringEncoding]
                                            timeout:5.0
                                           didClose:&didClose];
  NSUInteger pongCount = [response componentsSeparatedByString:@"pong"].count - 1;
  XCTAssertEqual(pongCount, 2, @"both pipelined requests must be answered: %@", response);
}

- (void)testPartiallyNumericContentLengthIsRejected
{
  NSString *payload = @"POST /framing/probe HTTP/1.1\r\nContent-Length: 5abc\r\n\r\nhello";
  BOOL didClose;
  NSString *response = [self responseForRawPayload:(NSData * _Nonnull)[payload dataUsingEncoding:NSUTF8StringEncoding]
                                            timeout:5.0
                                           didClose:&didClose];
  XCTAssertTrue([response containsString:@"400"], @"%@", response);
  XCTAssertTrue(didClose);
  XCTAssertEqual(atomic_load(&gFramingProbeHits), 0);
}

- (void)testOversizedHeaderBlockIsRejected
{
  // A header block that never terminates: 96 KiB of header lines with no \r\n\r\n. The server
  // must stop buffering and close the connection instead of growing the buffer indefinitely.
  NSMutableString *payload = [NSMutableString stringWithString:@"GET /framing/ping HTTP/1.1\r\n"];
  NSString *filler = [@"X-Filler: " stringByAppendingString:[@"" stringByPaddingToLength:1013 withString:@"a" startingAtIndex:0]];
  while (payload.length < 96 * 1024) {
    [payload appendString:filler];
    [payload appendString:@"\r\n"];
  }
  BOOL didClose;
  NSString *response = [self responseForRawPayload:(NSData * _Nonnull)[payload dataUsingEncoding:NSUTF8StringEncoding]
                                            timeout:10.0
                                           didClose:&didClose];
  XCTAssertTrue([response containsString:@"400"], @"%@", response);
  XCTAssertTrue(didClose, @"the connection must be closed rather than left buffering");
}

- (void)testOversizedCompletedHeaderBlockIsRejected
{
  // Same flood, but properly terminated with \r\n\r\n. Depending on how the bytes coalesce, the
  // terminator can arrive in the same receive callback as the bulk of the block, in which case
  // the incomplete-header cap never fires - the completed block must be rejected too instead of
  // being copied and parsed.
  NSMutableString *payload = [NSMutableString stringWithString:@"GET /framing/ping HTTP/1.1\r\n"];
  NSString *filler = [@"X-Filler: " stringByAppendingString:[@"" stringByPaddingToLength:1013 withString:@"a" startingAtIndex:0]];
  while (payload.length < 96 * 1024) {
    [payload appendString:filler];
    [payload appendString:@"\r\n"];
  }
  [payload appendString:@"\r\n"];
  BOOL didClose;
  NSString *response = [self responseForRawPayload:(NSData * _Nonnull)[payload dataUsingEncoding:NSUTF8StringEncoding]
                                            timeout:10.0
                                           didClose:&didClose];
  XCTAssertTrue([response containsString:@"400"], @"%@", response);
  XCTAssertFalse([response containsString:@"pong"], @"the oversized request must not be served: %@", response);
  XCTAssertTrue(didClose, @"the connection must be closed rather than left buffering");
}

@end
