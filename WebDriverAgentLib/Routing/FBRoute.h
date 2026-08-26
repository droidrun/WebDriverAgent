/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <Foundation/Foundation.h>

@protocol FBResponsePayload;
@class FBRouteRequest;
@class RouteResponse;

NS_ASSUME_NONNULL_BEGIN

typedef __nonnull id<FBResponsePayload> (^FBRouteSyncHandler)(FBRouteRequest *request);

/**
 Class that represents route
 */
@interface FBRoute : NSObject

/*! Route's verb (eg. POST, GET, DELETE) */
@property (nonatomic, copy, readonly) NSString *verb;

/*! Route's path */
@property (nonatomic, copy, readonly) NSString *path;

/*! YES when the route is served directly on the HTTP connection's queue instead of the
    automation (main) queue */
@property (nonatomic, assign, readonly) BOOL usesControlQueue;

/**
 Convenience constructor for GET route with given pathPattern
 */
+ (instancetype)GET:(NSString *)pathPattern;

/**
 Convenience constructor for POST route with given pathPattern
 */
+ (instancetype)POST:(NSString *)pathPattern;

/**
 Convenience constructor for PUT route with given pathPattern
 */
+ (instancetype)PUT:(NSString *)pathPattern;

/**
 Convenience constructor for DELETE route with given pathPattern
 */
+ (instancetype)DELETE:(NSString *)pathPattern;

/**
 Convenience constructor for OPTIONS route with given pathPattern
*/
+ (instancetype)OPTIONS:(NSString *)pathPattern;

/**
 Chain-able constructor that handles response with given FBRouteSyncHandler block
 */
- (instancetype)respondWithBlock:(FBRouteSyncHandler)handler;

/**
 Chain-able constructor that handles response with given FBRouteSyncHandler block
 */
- (instancetype)respondWithTarget:(id)target action:(SEL)selector;

/**
 Chain-able constructor for route that does NOT require session
 */
- (instancetype)withoutSession;

/**
 Chain-able modifier that marks the route to be served on the HTTP connection's own queue,
 bypassing the automation (main) queue. Only routes whose handlers never call XCUI or
 testmanagerd APIs and only touch thread-safe state may opt in — such routes stay responsive
 even while an automation request is blocked.
 */
- (instancetype)onControlQueue;

/**
 Dispatches response for request
 */
- (void)mountRequest:(FBRouteRequest *)request intoResponse:(RouteResponse *)response;

@end

NS_ASSUME_NONNULL_END
