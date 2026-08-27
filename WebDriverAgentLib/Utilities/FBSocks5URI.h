/**
 * Copyright (c) 2026-present, Droidrun.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 A parsed socks5:// or socks5h:// proxy URI as accepted by POST /mobilerun/socks5/connect.

 socks5h means hostnames are resolved remotely through the proxy (curl semantics); with
 plain socks5 the device resolves them itself. Only depends on Foundation so it stays
 unit-testable and compiles for tvOS.
 */
@interface FBSocks5URI : NSObject

/** Proxy host: DNS name, IPv4, or IPv6 literal (without brackets). */
@property (nonatomic, readonly, copy) NSString *host;
/** Proxy port; FBSocks5DefaultPort when the URI does not specify one. */
@property (nonatomic, readonly) NSUInteger port;
/** Percent-decoded username, or nil when the URI carries no credentials. */
@property (nonatomic, readonly, copy, nullable) NSString *user;
/** Percent-decoded password, or nil when the URI carries no credentials. */
@property (nonatomic, readonly, copy, nullable) NSString *pass;
/** YES for socks5h:// (remote DNS resolution through the proxy). */
@property (nonatomic, readonly) BOOL remoteDNS;

/**
 Parses and validates a SOCKS5 proxy URI.

 @param uriString the URI, e.g. socks5h://user:pass@proxy.example.com:1080
 @param error populated with a human-readable reason when parsing fails
 @return the parsed URI, or nil when the string is not a valid socks5(h) URI
 */
+ (nullable instancetype)parse:(nullable NSString *)uriString error:(NSError **)error;

/** The NETunnelProviderProtocol.providerConfiguration payload for this URI,
 keyed by the FBSocks5Key* constants (credentials omitted when absent). */
- (NSDictionary<NSString *, id> *)providerConfiguration;

/** Adds the active WDA controller IP to the provider configuration when available. */
- (NSDictionary<NSString *, id> *)providerConfigurationWithControlAddress:(nullable NSString *)controlAddress;

@end

NS_ASSUME_NONNULL_END
