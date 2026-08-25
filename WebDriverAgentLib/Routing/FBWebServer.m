/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBWebServer.h"

#if TARGET_OS_WATCH
#import "FBWatchHTTPServer.h"
#else
#import "RoutingConnection.h"
#import "RoutingHTTPServer.h"
#import "FBBroadcastManager.h"
#import "FBMjpegServer.h"
#import "FBTCPSocket.h"
#import "FBVideoStreamManager.h"
#endif

#import "FBCommandHandler.h"
#import "FBErrorBuilder.h"
#import "FBExceptionHandler.h"
#import "FBRouteRequest.h"
#import "FBRuntimeUtils.h"
#import "FBSession.h"
#import "FBUnknownCommands.h"
#import "FBConfiguration.h"
#import "FBLogger.h"
#import "FBXCodeCompatibility.h"

#import "XCUIDevice+FBHelpers.h"

static NSString *const FBServerURLBeginMarker = @"ServerURLHere->";
static NSString *const FBServerURLEndMarker = @"<-ServerURLHere";

#if !TARGET_OS_WATCH
@interface FBHTTPConnection : RoutingConnection
@end

@implementation FBHTTPConnection

- (void)handleResourceNotFound
{
  [FBLogger logFmt:@"Received request for %@ which we do not handle", self.requestURI];
  [super handleResourceNotFound];
}

- (UInt64)maxRequestBodySize
{
  return FBConfiguration.sharedInstance.httpRequestBodySizeLimit;
}

@end
#endif


@interface FBWebServer ()
@property (nonatomic, strong) FBExceptionHandler *exceptionHandler;
#if TARGET_OS_WATCH
@property (nonatomic, strong) FBWatchHTTPServer *server;
#else
@property (nonatomic, strong) RoutingHTTPServer *server;
@property (nonatomic, nullable) FBTCPSocket *screenshotsBroadcaster;
@property (nonatomic, nullable, strong) FBMjpegServer *mjpegServer;
#endif
@property (atomic, assign) BOOL keepAlive;
// Serializes automation requests onto a single funnel so at most one is ever in flight on
// the main queue. See registerRouteHandlers: for why this is necessary.
@property (nonatomic, strong) dispatch_queue_t automationQueue;
@end

@implementation FBWebServer

- (void)dealloc
{
#if !TARGET_OS_WATCH
  [self stopScreenshotsBroadcaster];
#endif
}

+ (NSArray<Class<FBCommandHandler>> *)collectCommandHandlerClasses
{
  NSArray *handlersClasses = FBClassesThatConformsToProtocol(@protocol(FBCommandHandler));
  NSMutableArray *handlers = [NSMutableArray array];
  for (Class aClass in handlersClasses) {
    if ([aClass respondsToSelector:@selector(shouldRegisterAutomatically)]) {
      if (![aClass shouldRegisterAutomatically]) {
        continue;
      }
    }
    [handlers addObject:aClass];
  }
  return handlers.copy;
}

- (void)startServing
{
  [FBLogger logFmt:@"Built at %s %s", __DATE__, __TIME__];
  self.exceptionHandler = [FBExceptionHandler new];
  if (![self startHTTPServer]) {
    return;
  }
#if !TARGET_OS_WATCH
  [self initScreenshotsBroadcaster];
  // Listen permanently so broadcasts started from Control Center attach as well.
  [FBBroadcastManager.sharedInstance startListening];
#endif

  self.keepAlive = YES;
  // /status is served off the main queue (it uses onControlQueue), but FBSDKVersion() and
  // FBTestmanagerdVersion() cache their result behind a dispatch_once. Burn both once-tokens
  // here, on the main thread, warmed only after the server has bound: FBTestmanagerdVersion()'s
  // legacy branch waits (with a bounded timeout) on the daemon, and a degraded daemon must not
  // be able to prevent the server from binding. An early request that races the warm-up just
  // blocks on the dispatch_once for at most the bounded handshake. Warmed only after
  // initialization is complete and keepAlive is set, so a shutdown that arrives while the
  // bounded legacy handshake spins the run loop simply clears keepAlive via stopServing and the
  // serving loop below never starts.
  FBSDKVersion();
  FBTestmanagerdVersion();
  NSRunLoop *runLoop = [NSRunLoop mainRunLoop];
  while (self.keepAlive) {
    @try {
      if (![runLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]) {
        break;
      }
    } @catch (NSException *exception) {
      // Routed request handlers have their own exception protection. Anything caught here
      // was raised by main-queue work outside of them (XCUIAutomation internals, monitor
      // ticks, etc.) and would otherwise unwind through testRunner and end the session.
      if ([exception.name isEqualToString:@"_XCTestCaseInterruptionException"]) {
        // XCTest's own control-flow exception for legitimate test interruption
        @throw;
      }
      [FBLogger logFmt:@"The main run loop recovered from an unexpected exception: %@\n%@",
       exception.reason, exception.callStackSymbols];
    }
  }
}

- (BOOL)startHTTPServer
{
#if TARGET_OS_WATCH
  self.server = [[FBWatchHTTPServer alloc] init];
#else
  self.server = [[RoutingHTTPServer alloc] init];
#endif
#if TARGET_OS_WATCH
  [self.server setRouteQueue:dispatch_get_main_queue()];
#endif
  [self.server setDefaultHeader:@"Server" value:@"WebDriverAgent/1.0"];
  [self.server setDefaultHeader:@"Access-Control-Allow-Origin" value:@"*"];
  [self.server setDefaultHeader:@"Access-Control-Allow-Headers" value:@"Content-Type, X-Requested-With"];
#if !TARGET_OS_WATCH
  [self.server setConnectionClass:[FBHTTPConnection self]];
#endif

  self.automationQueue = dispatch_queue_create("com.facebook.WebDriverAgent.automation-funnel", DISPATCH_QUEUE_SERIAL);

  [self registerRouteHandlers:[self.class collectCommandHandlerClasses]];
  [self registerServerKeyRouteHandlers];

  NSRange serverPortRange = FBConfiguration.sharedInstance.bindingPortRange;
  NSString *bindingIP = FBConfiguration.sharedInstance.bindingIPAddress;
#if !TARGET_OS_WATCH
  if (bindingIP != nil) {
    [self.server setInterface:bindingIP];
    [FBLogger logFmt:@"Using custom binding IP address: %@", bindingIP];
  }
#endif

  NSError *error;
  BOOL serverStarted = NO;

  for (NSUInteger index = 0; index < serverPortRange.length; index++) {
    NSInteger port = serverPortRange.location + index;
    [self.server setPort:(UInt16)port];

    serverStarted = [self attemptToStartServer:self.server onPort:port withError:&error];
    if (serverStarted) {
      break;
    }

    [FBLogger logFmt:@"Failed to start web server on port %ld with error %@", (long)port, [error description]];
  }

  if (!serverStarted) {
    [FBLogger logFmt:@"Last attempt to start web server failed with error %@", [error description]];
    id<FBWebServerDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(webServer:didFailToStartWithError:)]) {
      [delegate webServer:self didFailToStartWithError:(NSError * _Nonnull)error];
      return NO;
    }
    abort();
  }

  NSString *serverHost = bindingIP ?: ([XCUIDevice sharedDevice].fb_wifiIPAddress ?: @"127.0.0.1");
  [FBLogger logFmt:@"%@http://%@:%d%@", FBServerURLBeginMarker, serverHost, [self.server port], FBServerURLEndMarker];
  return YES;
}

#if !TARGET_OS_WATCH
- (void)initScreenshotsBroadcaster
{
  [self readMjpegSettingsFromEnv];
  self.mjpegServer = [[FBMjpegServer alloc] init];
  self.screenshotsBroadcaster = [[FBTCPSocket alloc]
                                 initWithPort:(uint16_t)FBConfiguration.sharedInstance.mjpegServerPort];
  self.screenshotsBroadcaster.delegate = self.mjpegServer;
  NSError *error;
  if (![self.screenshotsBroadcaster startWithError:&error]) {
    [FBLogger logFmt:@"Cannot init screenshots broadcaster service on port %@. Original error: %@", @(FBConfiguration.sharedInstance.mjpegServerPort), error.description];
    [self.mjpegServer stopStreaming];
    self.mjpegServer = nil;
    self.screenshotsBroadcaster = nil;
  }
}

- (void)stopScreenshotsBroadcaster
{
  if (nil == self.screenshotsBroadcaster) {
    self.mjpegServer = nil;
    return;
  }

  id<FBTCPSocketDelegate> delegate = self.screenshotsBroadcaster.delegate;
  if ([(NSObject *)delegate respondsToSelector:@selector(stopStreaming)]) {
    [(FBMjpegServer *)delegate stopStreaming];
  }
  self.screenshotsBroadcaster.delegate = nil;
  [self.screenshotsBroadcaster stop];
  self.screenshotsBroadcaster = nil;
  self.mjpegServer = nil;
}

- (void)readMjpegSettingsFromEnv
{
  NSDictionary *env = NSProcessInfo.processInfo.environment;
  NSString *scalingFactor = [env objectForKey:@"MJPEG_SCALING_FACTOR"];
  if (scalingFactor != nil && [scalingFactor length] > 0) {
    FBConfiguration.sharedInstance.mjpegScalingFactor = [scalingFactor floatValue];
  }
  NSString *screenshotQuality = [env objectForKey:@"MJPEG_SERVER_SCREENSHOT_QUALITY"];
  if (screenshotQuality != nil && [screenshotQuality length] > 0) {
    FBConfiguration.sharedInstance.mjpegServerScreenshotQuality = [screenshotQuality integerValue];
  }
}
#endif

- (void)stopServing
{
  [FBSession.activeSession kill];
#if !TARGET_OS_WATCH
  [FBVideoStreamManager.sharedInstance stopAllSessions];
  [FBBroadcastManager.sharedInstance stopListening];
  [self stopScreenshotsBroadcaster];
#endif
  if (self.server.isRunning) {
    [self.server stop:NO];
  }
  self.server = nil;
  self.exceptionHandler = nil;
  self.keepAlive = NO;
}

#if TARGET_OS_WATCH
- (BOOL)attemptToStartServer:(FBWatchHTTPServer *)server onPort:(NSInteger)port withError:(NSError **)error
#else
- (BOOL)attemptToStartServer:(RoutingHTTPServer *)server onPort:(NSInteger)port withError:(NSError **)error
#endif
{
  server.port = (UInt16)port;
  NSError *innerError = nil;
  BOOL started = [server start:&innerError];
  if (!started) {
    if (!error) {
      return NO;
    }

    NSString *description = @"Unknown Error when Starting server";
    if ([innerError.domain isEqualToString:NSPOSIXErrorDomain] && innerError.code == EADDRINUSE) {
      description = [NSString stringWithFormat:@"Unable to start web server on port %ld", (long)port];
    }
    return
    [[[[FBErrorBuilder builder]
       withDescription:description]
      withInnerError:innerError]
     buildError:error];
  }
  return YES;
}

- (void)registerRouteHandlers:(NSArray *)commandHandlerClasses
{
  __weak typeof(self) weakSelf = self;
  for (Class<FBCommandHandler> commandHandler in commandHandlerClasses) {
    NSArray *routes = [commandHandler routes];
    for (FBRoute *route in routes) {
      [self.server handleMethod:route.verb withPath:route.path block:^(RouteRequest *request, RouteResponse *response) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (nil == strongSelf) {
          return;
        }
        NSDictionary *arguments = [NSJSONSerialization JSONObjectWithData:request.body options:NSJSONReadingMutableContainers error:NULL];
        FBRouteRequest *routeParams = [FBRouteRequest
          routeRequestWithURL:request.url
          parameters:request.params
          arguments:arguments ?: @{}
        ];

        [FBLogger verboseLog:routeParams.description];

#if TARGET_OS_WATCH
        [strongSelf mountRoute:route request:routeParams intoResponse:response];
#else
        if (route.usesControlQueue) {
          // Served on this connection's own queue so it stays responsive while the automation
          // queue is busy or blocked. Only routes that never touch XCUI state opt in.
          [strongSelf mountRoute:route request:routeParams intoResponse:response];
        } else {
          // Serialize automation requests: while one is on the main queue (possibly spinning the
          // run loop), the next waits here instead of being enqueued to main, where a nested run
          // loop drain would otherwise execute it reentrantly inside the first handler.
          dispatch_sync(strongSelf.automationQueue, ^{
            dispatch_sync(dispatch_get_main_queue(), ^{
              @autoreleasepool {
                [strongSelf mountRoute:route request:routeParams intoResponse:response];
              }
            });
          });
        }
#endif
      }];
    }
  }
}

- (void)mountRoute:(FBRoute *)route request:(FBRouteRequest *)routeParams intoResponse:(RouteResponse *)response
{
  @try {
    [route mountRequest:routeParams intoResponse:response];
  }
  @catch (NSException *exception) {
    [self handleException:exception forResponse:response];
  }
}

- (void)handleException:(NSException *)exception forResponse:(RouteResponse *)response
{
  [self.exceptionHandler handleException:exception forResponse:response];
}

- (void)registerServerKeyRouteHandlers
{
  [self.server get:@"/health" withBlock:^(RouteRequest *request, RouteResponse *response) {
    [response respondWithString:@"<!DOCTYPE html><html><title>Health Check</title><body><p>I-AM-ALIVE</p></body></html>"];
  }];

  NSString *calibrationPage = @"<html>"
  "<title>{\"x\":null,\"y\":null}</title>"
  "<header>"
  "<script>document.addEventListener(\"click\",function(e){document.title=JSON.stringify({x:e.clientX,y:e.clientY})})</script>"
  "</header>"
  "</html>";
  [self.server get:@"/calibrate" withBlock:^(RouteRequest *request, RouteResponse *response) {
    [response respondWithString:calibrationPage];
  }];

  __weak typeof(self) weakSelf = self;
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

  [self registerRouteHandlers:@[FBUnknownCommands.class]];
}

@end
