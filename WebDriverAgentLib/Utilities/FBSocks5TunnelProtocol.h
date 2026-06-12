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

NS_ASSUME_NONNULL_END
