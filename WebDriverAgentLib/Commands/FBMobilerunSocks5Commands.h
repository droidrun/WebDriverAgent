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

/**
 mobilerun SOCKS5 VPN endpoints: routes device traffic through a SOCKS5 proxy via the
 WebDriverAgentTunnel packet tunnel extension.

 POST /mobilerun/socks5/connect    body: {"uri": "socks5[h]://[user:pass@]host[:port]",
                                          "timeout": seconds (optional, default 30),
                                          "consentButtonLabels": [string] (optional)}
 POST /mobilerun/socks5/disconnect
 GET  /mobilerun/socks5/stats
 */
@interface FBMobilerunSocks5Commands : NSObject <FBCommandHandler>

@end

NS_ASSUME_NONNULL_END
