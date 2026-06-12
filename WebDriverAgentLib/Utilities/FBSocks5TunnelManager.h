/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <Foundation/Foundation.h>

@class FBSocks5URI;

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const FBSocks5TunnelManagerErrorDomain;

typedef NS_ERROR_ENUM(FBSocks5TunnelManagerErrorDomain, FBSocks5TunnelManagerError) {
  /** Packet tunnels are not available in this environment (Simulator/tvOS). */
  FBSocks5TunnelManagerErrorUnsupported = 1,
  /** Saving the VPN configuration was denied (consent alert rejected or not confirmable). */
  FBSocks5TunnelManagerErrorNotAuthorized = 2,
  /** The tunnel did not reach the connected state within the allotted time. */
  FBSocks5TunnelManagerErrorTimeout = 3,
  /** NetworkExtension reported an unexpected failure. */
  FBSocks5TunnelManagerErrorInternal = 4,
};

/**
 Owns the NETunnelProviderManager lifecycle for the WebDriverAgentTunnel packet tunnel
 extension embedded in the runner app: installs/updates the VPN configuration (auto-accepting
 the system consent alert via UI automation), starts/stops the tunnel, and exposes traffic
 counters queried from the extension.

 Must be called on the main thread (run-loop spinning + XCUITest interaction, like
 FBBroadcastManager).
 */
@interface FBSocks5TunnelManager : NSObject

+ (instancetype)sharedInstance;

/**
 Installs/updates the VPN configuration for the given proxy and starts the tunnel.
 An already-running tunnel is replaced. Returns once the tunnel reports connected.

 @param uri the parsed socks5/socks5h proxy URI
 @param timeout overall time budget in seconds for the tunnel to reach the connected state
 @param consentButtonLabels labels to look for on the system "Add VPN Configurations" alert
        (defaults to "Allow"); pass others when the device language is not English
 @param error If there is an error, upon return contains an NSError describing the problem
 @return NO in case of a failure
 */
- (BOOL)connectWithURI:(FBSocks5URI *)uri
               timeout:(NSTimeInterval)timeout
   consentButtonLabels:(nullable NSArray<NSString *> *)consentButtonLabels
                 error:(NSError **)error;

/**
 Stops the running tunnel (the VPN configuration stays installed). Succeeds when no tunnel
 is running.

 @param error If there is an error, upon return contains an NSError describing the problem
 @return NO in case of a failure
 */
- (BOOL)disconnectWithError:(NSError **)error;

/** @return The stats payload for GET /mobilerun/socks5/stats: connected flag, proxy
 host/port/user (omitted while disconnected) and rx/tx byte/packet counters. Never fails;
 counters fall back to zero when the extension cannot be queried. */
- (NSDictionary<NSString *, id> *)statsDictionary;

@end

NS_ASSUME_NONNULL_END
