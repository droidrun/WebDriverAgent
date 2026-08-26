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
static atomic_bool gAutomationProbeDone;
static atomic_bool gAutomationProbeRanOnMain;
static atomic_int gSpinningProbeDepth;
static atomic_int gSpinningProbeMaxDepth;
static atomic_int gSpinningProbeCompletions;

@interface FBWebServer (DispatchTests)
- (void)registerRouteHandlers:(NSArray *)commandHandlerClasses;
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
      [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.4]];
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
  [self fireRequestForPath:@"/probe/spinning"];
  [NSThread sleepForTimeInterval:0.1];
  [self fireRequestForPath:@"/probe/spinning"];

  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20.0];
  while (atomic_load(&gSpinningProbeCompletions) < 2 && deadline.timeIntervalSinceNow > 0) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  }

  XCTAssertEqual(atomic_load(&gSpinningProbeCompletions), 2, @"both spinning requests must complete");
  XCTAssertEqual(atomic_load(&gSpinningProbeMaxDepth), 1, @"a second automation request must never nest inside the first");
}

@end

#import <arpa/inet.h>
#import <sys/socket.h>

static atomic_int gFramingProbeHits;

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
  self.server = [FBHTTPServer new];
  [self.server handleMethod:@"POST" withPath:@"/framing/probe" block:^(RouteRequest *request, RouteResponse *response) {
    atomic_fetch_add(&gFramingProbeHits, 1);
    [response respondWithString:@"probe-ok"];
  }];
  [self.server get:@"/framing/ping" withBlock:^(RouteRequest *request, RouteResponse *response) {
    [response respondWithString:@"pong"];
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
  // Ignore send errors: the flood test expects the server to close mid-send.
  send(fd, payload.bytes, payload.length, 0);
  NSMutableData *received = [NSMutableData data];
  char chunk[4096];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  while (deadline.timeIntervalSinceNow > 0) {
    ssize_t n = recv(fd, chunk, sizeof(chunk), 0);
    if (n > 0) {
      [received appendBytes:chunk length:(NSUInteger)n];
      // The response has started arriving; the server keeps the connection open after a
      // success, so don't wait the full timeout for an EOF that never comes.
      struct timeval drainTv = { .tv_sec = 0, .tv_usec = 200000 };
      setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &drainTv, sizeof(drainTv));
    } else {
      *didClose = (n == 0);
      break;
    }
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
}

@end
