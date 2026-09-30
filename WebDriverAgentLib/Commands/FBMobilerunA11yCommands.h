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

@class FBCommandStatus;

@interface FBMobilerunA11yCommands : NSObject <FBCommandHandler>

/**
 Builds the GET /mobilerun/state value by running 'attempt' - one snapshot walk of the active
 application - and retrying it once when the snapshot fails (FBStaleElementException).

 Exposed for unit testing; the route handler passes a block that resolves the active application
 anew on every call.

 @param attempt returns the state dictionary; may throw
 @param failure set when both attempts failed to snapshot the application
 @return the state dictionary, or nil with 'failure' set. Exceptions other than a failed snapshot
 are rethrown unchanged.
 */
+ (nullable NSDictionary *)stateWithSnapshotAttempt:(NSDictionary *(NS_NOESCAPE ^)(void))attempt
                                            failure:(FBCommandStatus *_Nullable *_Nullable)failure;

@end

NS_ASSUME_NONNULL_END
