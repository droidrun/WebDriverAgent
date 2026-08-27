/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 Contract shared between WebDriverAgent and the WebDriverAgentTunnel packet tunnel extension.

 This file is compiled into both WebDriverAgentLib and the WebDriverAgentTunnel extension
 target, so it must only depend on Foundation.

 The host configures the tunnel by storing a dictionary keyed by the FBSocks5Key* constants
 in NETunnelProviderProtocol.providerConfiguration; the extension turns that dictionary into
 a hev-socks5-tunnel YAML config via FBSocks5HevConfigFromProviderConfiguration. Runtime
 traffic counters are queried through sendProviderMessage with the FBSocks5MsgStats verb;
 the extension answers with UTF-8 JSON keyed by the FBSocks5StatsKey* constants.
 */

/** providerConfiguration keys */
extern NSString *const FBSocks5KeyHost;
extern NSString *const FBSocks5KeyPort;
extern NSString *const FBSocks5KeyUser;
extern NSString *const FBSocks5KeyPass;
/** @YES when DNS must be resolved through the proxy (socks5h://). */
extern NSString *const FBSocks5KeyRemoteDNS;
/** Remote WDA controller IP to exclude from the full-tunnel routes. */
extern NSString *const FBSocks5KeyControlAddress;

/** startVPNTunnelWithOptions key carrying the host's absolute whole-flow deadline. */
extern NSString *const FBSocks5OptionStartupDeadline;
/** Startup budget used when the tunnel is launched outside the WDA connect route. */
extern const NSTimeInterval FBSocks5DefaultStartupTimeout;

/**
 Resolves the provider's absolute startup deadline from host-supplied options, or applies the
 default startup timeout when no valid deadline was supplied.
 */
NSDate *FBSocks5TunnelStartupDeadlineFromOptions(NSDictionary<NSString *, NSObject *> *_Nullable options,
                                                 NSDate *now);
/** Returns the nonnegative time remaining before `deadline`, capped to one operation's limit. */
NSTimeInterval FBSocks5TunnelRemainingStartupTime(NSDate *deadline, NSDate *now, NSTimeInterval cap);
/** Validates the RFC 1929 username/password sub-negotiation reply. */
BOOL FBSocks5TunnelUsernamePasswordAuthReplySucceeded(uint8_t version, uint8_t status);
/** Returns whether a proxy-selected authentication method was present in the client greeting. */
BOOL FBSocks5TunnelAuthenticationMethodWasOffered(uint8_t method, BOOL hasCredentials);

/** sendProviderMessage verb (UTF-8 encoded) asking the extension for traffic counters. */
extern NSString *const FBSocks5MsgStats;

/** Keys of the JSON stats reply (also used in the /mobilerun/socks5/stats response). */
extern NSString *const FBSocks5StatsKeyConnected;
extern NSString *const FBSocks5StatsKeyHost;
extern NSString *const FBSocks5StatsKeyPort;
extern NSString *const FBSocks5StatsKeyUser;
extern NSString *const FBSocks5StatsKeyRxBytes;
extern NSString *const FBSocks5StatsKeyTxBytes;
extern NSString *const FBSocks5StatsKeyRxPackets;
extern NSString *const FBSocks5StatsKeyTxPackets;

/** Default SOCKS5 port when the URI does not specify one. */
extern const NSUInteger FBSocks5DefaultPort;

/** The utun interface address; must match between NEPacketTunnelNetworkSettings and the
 hev config, so both come from these constants. */
extern NSString *const FBSocks5TunnelIPv4Address;
extern NSString *const FBSocks5TunnelIPv4Netmask;
/** Link-local-ish ULA the tunnel claims so IPv6 cannot bypass it; see FBTunnelPacketProvider. */
extern NSString *const FBSocks5TunnelIPv6Address;
extern const NSUInteger FBSocks5TunnelIPv6PrefixLength;
/** Synthetic resolver address hev's mapdns listens on (socks5h mode); used as the tunnel's
 DNS server so queries are hijacked into hostname-preserving CONNECTs. */
extern NSString *const FBSocks5TunnelMapDNSAddress;
/** Interface MTU shared by NEPacketTunnelNetworkSettings and the hev config. */
extern const NSUInteger FBSocks5TunnelMTU;

/**
 Renders the hev-socks5-tunnel YAML config for a providerConfiguration dictionary.

 @param providerConfiguration dictionary keyed by the FBSocks5Key* constants
 @return the YAML config string consumed by hev_socks5_tunnel_main_from_str
 */
NSString *FBSocks5HevConfigFromProviderConfiguration(NSDictionary<NSString *, id> *providerConfiguration);

/**
 Coordinates packet-tunnel startup with stop requests so a stop cannot complete while startup
 or network-settings cleanup is still pending.
 */
@interface FBSocks5TunnelStartupFence : NSObject

@property (nonatomic, readonly, getter=isStopping) BOOL stopping;

- (void)beginStartupWithCompletion:(void (^)(NSError *_Nullable error))completion;
- (BOOL)waitForSignal:(dispatch_semaphore_t)signal beforeDate:(NSDate *)deadline;
- (BOOL)performStartupActionIfNotStopping:(dispatch_block_t)block;
- (BOOL)requestStopWithCompletion:(dispatch_block_t)completion;
- (BOOL)finishStartupWithError:(nullable NSError *)error stoppedError:(NSError *)stoppedError;
- (void)finishStopCleanup;

@end

NS_ASSUME_NONNULL_END
