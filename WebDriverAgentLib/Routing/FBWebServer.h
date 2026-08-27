/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <Foundation/Foundation.h>

@class RouteResponse, FBExceptionHandler;
@protocol FBWebServerDelegate;

NS_ASSUME_NONNULL_BEGIN

/**
 HTTP and USB service wrapper, handling requests and responses
 */
@interface FBWebServer : NSObject

/**
 Server delegate.
 */
@property (weak, nonatomic) id<FBWebServerDelegate> delegate;

/**
 Starts WebDriverAgent service by booting HTTP and USB server.
 If the HTTP server fails to bind (for example the whole configured port range
 is already occupied), the failure is reported to the delegate via
 `webServer:didFailToStartWithError:`. If the delegate does not implement that
 method the process is aborted, as before.
 */
- (void)startServing;

/**
 Stops WebDriverAgent service, shutting down HTTP and USB servers.
 */
- (void)stopServing;

/**
 Runs a block that touches XCUI/XCTest state on the main thread, serialized through the
 same automation funnel the main-queue-served routes use.

 Routes marked `standalone` are served off the main queue, so they must not call
 XCUI directly. Hopping straight to the main queue is not enough either: such a block
 could be drained inside another handler's run-loop spin, which is exactly the
 reentrancy the funnel exists to prevent. Going through the funnel first makes the
 block wait for the in-flight automation request instead.

 No-ops onto a direct call when already on the main thread (the caller is then already
 inside the funnel), and skips the funnel hop when already running on it.

 @param block The XCUI-touching work. Executed synchronously before this method returns.
 */
+ (void)performAutomationBlockOnMainQueue:(NS_NOESCAPE dispatch_block_t)block;

/**
 Runs an XCUI/XCTest block through the automation funnel only if it can begin by `deadline`.

 If the block is still queued when the deadline expires, it is cancelled and will not execute
 later. Once execution has begun, this method preserves the synchronous contract and waits for
 the block to finish.

 @param block The XCUI-touching work.
 @param deadline The latest date at which the queued block may begin executing.
 @return YES if the block began execution, otherwise NO.
 */
+ (BOOL)performAutomationBlockOnMainQueue:(dispatch_block_t)block
                                beforeDate:(NSDate *)deadline;

@end

/**
 The protocol allowing the server delegate to handle messages from the server.
 */
@protocol FBWebServerDelegate <NSObject>

/**
 The server requested WebDriverAgent service shutdown.

 @param webServer Server instance.
 */
- (void)webServerDidRequestShutdown:(FBWebServer *)webServer;

@optional
/**
 Called when the server failed to start the HTTP listener, for example because
 none of the ports in the configured binding range could be bound.
 If this method is not implemented by the delegate then the process is aborted,
 preserving the previous behavior.

 @param webServer Server instance.
 @param error The actual error, that caused the server startup to fail.
 */
- (void)webServer:(FBWebServer *)webServer didFailToStartWithError:(NSError *)error;

@end

NS_ASSUME_NONNULL_END
