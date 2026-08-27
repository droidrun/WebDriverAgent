/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBWebServer.h"

#import "FBHTTPServer.h"
#import <stdatomic.h>
#import "FBMjpegServer.h"
#import "FBTCPSocket.h"
#if !TARGET_OS_WATCH
#import "FBBroadcastManager.h"
#import "FBVideoStreamManager.h"
#endif

#import "FBCommandHandler.h"
#import "FBCommandStatus.h"
#import "FBErrorBuilder.h"
#import "FBExceptionHandler.h"
#import "FBResponsePayload.h"
#import "FBRouteRequest.h"
#import "FBRuntimeUtils.h"
#import "FBSession.h"
#import "FBSessionCommands.h"
#import "FBUnknownCommands.h"
#import "FBConfiguration.h"
#import "FBLogger.h"
#import "FBXCodeCompatibility.h"

#import "XCUIDevice+FBHelpers.h"

static NSString *const FBServerURLBeginMarker = @"ServerURLHere->";
static NSString *const FBServerURLEndMarker = @"<-ServerURLHere";

/// Queue-specific marker used to detect that the caller already runs on the automation funnel.
static const void *FBAutomationFunnelKey = &FBAutomationFunnelKey;

@interface FBWebServer ()
@property (nonatomic, strong) FBExceptionHandler *exceptionHandler;
@property (nonatomic, strong) FBHTTPServer *server;
@property (nonatomic, nullable) FBTCPSocket *screenshotsBroadcaster;
@property (nonatomic, nullable, strong) FBMjpegServer *mjpegServer;
@property (atomic, assign) BOOL keepAlive;
// Serializes automation requests onto a single funnel so at most one is ever in flight on
// the main queue. See registerRouteHandlers: for why this is necessary.
@property (nonatomic, strong) dispatch_queue_t automationQueue;
@end

@implementation FBWebServer

- (void)dealloc
{
  [self stopScreenshotsBroadcaster];
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
  // Snapshot the /status device info on the main thread BEFORE the server binds: once it
  // accepts connections, an early /status request could win the dispatch_once and run the
  // formally main-thread-only UIDevice reads on its connection queue. Unlike the version
  // pre-warms below, this is a cheap local read that cannot delay binding.
  [FBSessionCommands cachedDeviceInfo];
  if (![self startHTTPServer]) {
    return;
  }
  [self initScreenshotsBroadcaster];
#if !TARGET_OS_WATCH
  // Listen permanently so broadcasts started from Control Center attach as well.
  [FBBroadcastManager.sharedInstance startListening];
#endif

  self.keepAlive = YES;
  // /status is served off the main queue (it is a standalone route), but FBSDKVersion() and
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

/**
 The funnel is process-wide rather than per-server instance so that off-main callers
 (see performAutomationBlockOnMainQueue:) serialize against the very same queue the
 route dispatch uses.
 */
+ (dispatch_queue_t)automationFunnelQueue
{
  static dispatch_queue_t queue;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    queue = dispatch_queue_create("com.facebook.WebDriverAgent.automation-funnel", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(queue, FBAutomationFunnelKey, (void *)FBAutomationFunnelKey, NULL);
  });
  return queue;
}

+ (void)performAutomationBlockOnMainQueue:(NS_NOESCAPE dispatch_block_t)block
{
  if (NSThread.isMainThread) {
    // Already inside funnel -> main, so re-entering either would deadlock.
    block();
    return;
  }
  __block NSException *blockException = nil;
  if (NULL != dispatch_get_specific(FBAutomationFunnelKey)) {
    dispatch_sync(dispatch_get_main_queue(), ^{
      @try {
        block();
      } @catch (NSException *exception) {
        blockException = exception;
      }
    });
    if (nil != blockException) {
      @throw blockException;
    }
    return;
  }
  dispatch_sync(self.automationFunnelQueue, ^{
    dispatch_sync(dispatch_get_main_queue(), ^{
      @try {
        block();
      } @catch (NSException *exception) {
        blockException = exception;
      }
    });
  });
  if (nil != blockException) {
    @throw blockException;
  }
}

+ (BOOL)performAutomationBlockOnMainQueue:(dispatch_block_t)block
                                beforeDate:(NSDate *)deadline
{
  if (NSThread.isMainThread) {
    if (deadline.timeIntervalSinceNow <= 0) {
      return NO;
    }
    block();
    return YES;
  }
  if (NULL != dispatch_get_specific(FBAutomationFunnelKey)) {
    __block BOOL executed = NO;
    __block NSException *blockException = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
      if (deadline.timeIntervalSinceNow <= 0) {
        return;
      }
      executed = YES;
      @try {
        block();
      } @catch (NSException *exception) {
        blockException = exception;
      }
    });
    if (nil != blockException) {
      @throw blockException;
    }
    return executed;
  }

  enum {
    FBAutomationBlockPending,
    FBAutomationBlockExecuting,
    FBAutomationBlockCancelled,
    FBAutomationBlockFinished,
  };
  __block volatile atomic_int state = FBAutomationBlockPending;
  __block NSException *blockException = nil;
  dispatch_semaphore_t completion = dispatch_semaphore_create(0);
  dispatch_async(self.automationFunnelQueue, ^{
    @try {
      if (atomic_load_explicit(&state, memory_order_acquire) == FBAutomationBlockCancelled) {
        return;
      }
      dispatch_sync(dispatch_get_main_queue(), ^{
        int expected = FBAutomationBlockPending;
        if (deadline.timeIntervalSinceNow > 0
            && atomic_compare_exchange_strong_explicit(&state, &expected,
                                                       FBAutomationBlockExecuting,
                                                       memory_order_acq_rel,
                                                       memory_order_acquire)) {
          @try {
            block();
          } @catch (NSException *exception) {
            blockException = exception;
          } @finally {
            atomic_store_explicit(&state, FBAutomationBlockFinished, memory_order_release);
          }
        } else {
          expected = FBAutomationBlockPending;
          atomic_compare_exchange_strong_explicit(&state, &expected,
                                                  FBAutomationBlockCancelled,
                                                  memory_order_acq_rel,
                                                  memory_order_acquire);
        }
      });
    } @finally {
      dispatch_semaphore_signal(completion);
    }
  });

  NSTimeInterval budget = deadline.timeIntervalSinceNow;
  long waitResult = budget <= 0
    ? 1
    : dispatch_semaphore_wait(completion, dispatch_time(DISPATCH_TIME_NOW,
                                                        (int64_t)(budget * NSEC_PER_SEC)));
  if (0 != waitResult) {
    int expected = FBAutomationBlockPending;
    if (atomic_compare_exchange_strong_explicit(&state, &expected,
                                                FBAutomationBlockCancelled,
                                                memory_order_acq_rel,
                                                memory_order_acquire)) {
      return NO;
    }
    if (atomic_load_explicit(&state, memory_order_acquire) == FBAutomationBlockCancelled) {
      return NO;
    }
    dispatch_semaphore_wait(completion, DISPATCH_TIME_FOREVER);
  }
  BOOL finished = atomic_load_explicit(&state, memory_order_acquire) == FBAutomationBlockFinished;
  if (finished && nil != blockException) {
    @throw blockException;
  }
  return finished;
}

- (BOOL)startHTTPServer
{
  self.server = [[FBHTTPServer alloc] init];
  // Serializes automation requests so at most one is ever in flight on the main queue; handlers
  // are invoked here and hop to main via dispatch_sync. See registerRouteHandlers:.
  self.automationQueue = self.class.automationFunnelQueue;
  [self.server setRouteQueue:self.automationQueue];
  [self.server setDefaultHeader:@"Server" value:@"WebDriverAgent/1.0"];
  [self.server setDefaultHeader:@"Access-Control-Allow-Origin" value:@"*"];
  [self.server setDefaultHeader:@"Access-Control-Allow-Headers" value:@"Content-Type, X-Requested-With"];

  [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(sessionWasKilled:)
                                              name:FBSessionWasKilledNotification
                                            object:nil];

  [self registerRouteHandlers:[self.class collectCommandHandlerClasses]];
  [self registerServerKeyRouteHandlers];

  NSRange serverPortRange = FBConfiguration.sharedInstance.bindingPortRange;
  NSString *bindingIP = FBConfiguration.sharedInstance.bindingIPAddress;
  if (bindingIP != nil) {
    [self.server setInterface:bindingIP];
    [FBLogger logFmt:@"Using custom binding IP address: %@", bindingIP];
  }

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

- (void)initScreenshotsBroadcaster
{
  [self readMjpegSettingsFromEnv];
  self.mjpegServer = [[FBMjpegServer alloc] init];
  self.screenshotsBroadcaster = [[FBTCPSocket alloc]
                                 initWithPort:(uint16_t)FBConfiguration.sharedInstance.mjpegServerPort];
  self.mjpegServer.socket = self.screenshotsBroadcaster;
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

- (void)sessionWasKilled:(NSNotification *)notification
{
  FBSession *session = notification.object;
  if (![session isKindOfClass:FBSession.class]) {
    return;
  }
  // Same "invalid session id" shape a still-queued request would eventually get anyway, once
  // -routeQueue drains and FBRoute.decorateRequest: finds the session gone - just delivered now
  // instead of after however long the request would otherwise have been stuck waiting.
  NSString *message = [NSString stringWithFormat:@"Session %@ was deleted while this request was still pending", session.identifier];
  id<FBResponsePayload> payload = FBResponseWithStatus([FBCommandStatus noSuchDriverErrorWithMessage:message
                                                                                            traceback:nil]);
  RouteResponse *response = [RouteResponse new];
  [payload dispatchWithResponse:response];
  [self.server abandonPendingRequestsForSessionID:session.identifier withResponse:response];
}

- (void)stopServing
{
  [NSNotificationCenter.defaultCenter removeObserver:self name:FBSessionWasKilledNotification object:nil];
  [FBSession.activeSession kill];
#if !TARGET_OS_WATCH
  [FBVideoStreamManager.sharedInstance stopAllSessions];
  [FBBroadcastManager.sharedInstance stopListening];
#endif
  [self stopScreenshotsBroadcaster];
  if (self.server.isRunning) {
    [self.server stop:NO];
  }
  self.server = nil;
  self.exceptionHandler = nil;
  self.keepAlive = NO;
}

- (BOOL)attemptToStartServer:(FBHTTPServer *)server onPort:(NSInteger)port withError:(NSError **)error
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
      [self.server handleMethod:route.verb withPath:route.path standalone:route.isStandalone block:^(RouteRequest *request, RouteResponse *response) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (nil == strongSelf) {
          return;
        }
        NSDictionary *arguments = [NSJSONSerialization JSONObjectWithData:request.body options:NSJSONReadingMutableContainers error:NULL];
        FBRouteRequest *routeParams = [FBRouteRequest
          routeRequestWithURL:request.url
          parameters:request.params
          arguments:arguments ?: @{}
          clientAddress:request.clientAddress
        ];

        [FBLogger verboseLog:routeParams.description];

        if (route.isStandalone) {
          // Standalone handlers are invoked by FBHTTPServer on their own queues so they stay
          // responsive while the main queue is busy or blocked. Only routes that never touch
          // XCUI state opt in.
          [strongSelf mountRoute:route request:routeParams intoResponse:response];
        } else {
          // Invoked on the automation funnel (the server's routeQueue). Hopping to main from
          // there - instead of using the main queue as the routeQueue directly - serializes
          // automation requests: while one is on the main queue (possibly spinning the run
          // loop), the next waits on the funnel instead of being enqueued to main, where a
          // nested run loop drain would otherwise execute it reentrantly inside the first
          // handler.
          dispatch_sync(dispatch_get_main_queue(), ^{
            @autoreleasepool {
              [strongSelf mountRoute:route request:routeParams intoResponse:response];
            }
          });
        }
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
  // Standalone, i.e. off -routeQueue: these must stay answerable while the funnel is wedged -
  // /health as a liveness signal, /wda/shutdown as the way out. (/mobilerun/state is deliberately
  // the opposite; see docs/request-dispatch.md.)
  [self.server handleMethod:@"GET" withPath:@"/health" standalone:YES block:^(RouteRequest *request, RouteResponse *response) {
    [response respondWithString:@"<!DOCTYPE html><html><title>Health Check</title><body><p>I-AM-ALIVE</p></body></html>"];
  }];

  // Deprecated: no longer needed since appium-xcuitest-driver handles calibration
  // itself (https://github.com/appium/appium-xcuitest-driver/pull/2948). Kept for
  // backward compatibility; will be removed in a future major release.
  NSString *calibrationPage = @"<html>"
  "<title>{\"x\":null,\"y\":null}</title>"
  "<header>"
  "<script>document.addEventListener(\"click\",function(e){document.title=JSON.stringify({x:e.clientX,y:e.clientY})})</script>"
  "</header>"
  "</html>";
  [self.server handleMethod:@"GET" withPath:@"/calibrate" standalone:YES block:^(RouteRequest *request, RouteResponse *response) {
    [FBLogger logFmt:@"The /calibrate endpoint is deprecated and will be removed in a future release"];
    [response respondWithString:calibrationPage];
  }];

  __weak typeof(self) weakSelf = self;
  [self.server handleMethod:@"GET" withPath:@"/wda/shutdown" standalone:YES block:^(RouteRequest *request, RouteResponse *response) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (nil == strongSelf) {
      return;
    }
    [response respondWithString:@"Shutting down"];
    // Deferred so the "Shutting down" response is written to the client before
    // webServerDidRequestShutdown: tears down the server's socket out from under it.
    dispatch_async(dispatch_get_main_queue(), ^{
      [strongSelf.delegate webServerDidRequestShutdown:strongSelf];
    });
  }];

  [self registerRouteHandlers:@[FBUnknownCommands.class]];
}

@end
