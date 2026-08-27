/**
 * Copyright (c) 2026-present, Droidrun.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <NetworkExtension/NetworkExtension.h>

NS_ASSUME_NONNULL_BEGIN

/**
 Packet tunnel provider routing the device's traffic through a SOCKS5 proxy via the
 hev-socks5-tunnel engine. Configured by FBSocks5TunnelManager through the
 providerConfiguration dictionary defined in FBSocks5TunnelProtocol.h.
 */
@interface FBTunnelPacketProvider : NEPacketTunnelProvider

@end

NS_ASSUME_NONNULL_END
