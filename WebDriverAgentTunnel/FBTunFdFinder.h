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
 Locates the file descriptor of the packet tunnel's utun interface inside a
 NEPacketTunnelProvider process. There is no supported API for this; the descriptor is found
 by scanning the process' descriptors for the kernel-control socket backing NEPacketTunnelFlow
 (public POSIX calls only).

 @return the utun file descriptor, or -1 when none is found
 */
int FBTunnelFindTunFd(void);

NS_ASSUME_NONNULL_END
