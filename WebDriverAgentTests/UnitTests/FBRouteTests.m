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

+ (id<FBResponsePayload>)dummyHandler:(FBRouteRequest *)request
{
  return nil;
}

@end

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
