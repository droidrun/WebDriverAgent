/**
 * Copyright (c) 2026-present, Droidrun.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <Foundation/Foundation.h>

#import <WebDriverAgentLib/FBCommandHandler.h>

NS_ASSUME_NONNULL_BEGIN

@class FBSession;

/**
 How long one full accessibility snapshot of the active app may take, in seconds. XCTest's own
 limit is 60s per request and it retries; an app that is stuck or has a huge hierarchy (TikTok on
 older iPhones) otherwise holds the request - and every request queued behind it - for minutes.
 */
extern const NSTimeInterval FBMobilerunStateSnapshotTimeout;

/** The limit for the shallow snapshot taken when the full one did not finish. */
extern const NSTimeInterval FBMobilerunStateShallowSnapshotTimeout;

/** How far the shallow fallback snapshot descends: tree levels below the app, children per element. */
extern const int FBMobilerunStateShallowSnapshotMaxDepth;
extern const int FBMobilerunStateShallowSnapshotMaxChildren;

typedef NS_ENUM(NSUInteger, FBMobilerunSnapshotDepth) {
  FBMobilerunSnapshotDepthFull,
  FBMobilerunSnapshotDepthShallow,
};

/** What the state assembly needs to know about an application. XCUIApplication conforms. */
@protocol FBMobilerunStateApplication <NSObject>
@property (nonatomic, readonly) int processID;
@end

@interface FBMobilerunA11yCommands : NSObject <FBCommandHandler>

/**
 Builds the GET /mobilerun/state value for the active application within a bounded time:
 a full snapshot, else a shallow one, else the application root alone. 'truncated' says whether
 the tree is incomplete; 'phone_state.packageName' names the active application either way.

 @param scale the factor logical-point bounds are multiplied by
 @param session the session whose active application to use, or nil to detect it
 */
+ (NSDictionary *)stateOfActiveApplicationWithScale:(CGFloat)scale session:(nullable FBSession *)session;

/**
 The decision logic behind 'stateOfActiveApplicationWithScale:session:', exposed for unit testing.

 Snapshots the active application in full. When that fails and another application has taken over
 meanwhile (right after a Home press, say), snapshots that one in full instead; never the same
 application twice, since a timed-out snapshot would only time out again. Then falls back to a
 shallow snapshot, and finally to no snapshot at all.

 @param activeApplication resolves the active application; called at most twice
 @param snapshot takes a snapshot of the given depth, or returns nil when it failed
 @param build assembles the state from the application, its snapshot (nil when none succeeded) and
 whether the snapshot is incomplete
 */
+ (NSDictionary *)stateWithActiveApplication:(id<FBMobilerunStateApplication> (NS_NOESCAPE ^)(void))activeApplication
                                    snapshot:(id _Nullable (NS_NOESCAPE ^)(id<FBMobilerunStateApplication> application, FBMobilerunSnapshotDepth depth))snapshot
                                       build:(NSDictionary *(NS_NOESCAPE ^)(id<FBMobilerunStateApplication> application, id _Nullable snapshot, BOOL truncated))build;

@end

NS_ASSUME_NONNULL_END
