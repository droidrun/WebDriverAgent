/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <Foundation/Foundation.h>

#import <WebDriverAgentLib/FBCommandHandler.h>

NS_ASSUME_NONNULL_BEGIN

@interface FBSessionCommands : NSObject <FBCommandHandler>

/**
 Device properties served by /status (OS name, OS version, device kind), snapshotted once
 behind a dispatch_once. /status runs off the main queue while UIDevice is formally
 main-thread-only UIKit API, so FBWebServer burns the once-token on the main thread at startup.
 */
+ (NSDictionary<NSString *, NSString *> *)cachedDeviceInfo;

@end

NS_ASSUME_NONNULL_END
