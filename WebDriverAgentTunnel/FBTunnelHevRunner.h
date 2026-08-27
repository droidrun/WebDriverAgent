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
 Runs the hev-socks5-tunnel engine on a dedicated thread.
 hev_socks5_tunnel_main_from_str blocks for the tunnel's whole lifetime, so start spawns a
 thread and stop unblocks it via hev_socks5_tunnel_quit.
 */
@interface FBTunnelHevRunner : NSObject

/** YES while the engine thread is running. */
@property (atomic, readonly) BOOL isRunning;

/**
 Starts the engine thread. No-op while the engine is already running.

 @param configYAML the hev-socks5-tunnel YAML config
 @param tunFd the utun file descriptor the engine reads/writes packets on
 */
- (void)startWithConfigYAML:(NSString *)configYAML
                      tunFd:(int)tunFd
                exitHandler:(nullable void (^)(int exitCode))exitHandler;

/**
 Asks the engine to quit and waits for the engine thread to exit.

 A timed-out quit request may still be blocked inside hev's process-global state. The caller must
 terminate the extension process before starting another engine generation when this returns NO.

 @param timeout maximum time in seconds to wait for the engine thread
 @return YES when the engine stopped within the timeout
 */
- (BOOL)stopAndWait:(NSTimeInterval)timeout;

/**
 Snapshots the engine's cumulative traffic counters (safe to call cross-thread while running).
 */
- (void)getStatsTxPackets:(size_t *)txPackets
                  txBytes:(size_t *)txBytes
                rxPackets:(size_t *)rxPackets
                  rxBytes:(size_t *)rxBytes;

@end

NS_ASSUME_NONNULL_END
