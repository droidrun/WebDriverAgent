/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBTunnelHevRunner.h"

#import <HevSocks5Tunnel/hev-main.h>

@interface FBTunnelHevRunner ()
@property (atomic, readwrite) BOOL isRunning;
@property (nonatomic, nullable) dispatch_semaphore_t exitSemaphore;
@end

@implementation FBTunnelHevRunner

- (void)startWithConfigYAML:(NSString *)configYAML tunFd:(int)tunFd
{
  if (self.isRunning) {
    return;
  }
  self.isRunning = YES;
  dispatch_semaphore_t exitSemaphore = dispatch_semaphore_create(0);
  self.exitSemaphore = exitSemaphore;
  NSData *config = [configYAML dataUsingEncoding:NSUTF8StringEncoding];
  __weak typeof(self) weakSelf = self;
  NSThread *thread = [[NSThread alloc] initWithBlock:^{
    int code = hev_socks5_tunnel_main_from_str((const unsigned char *)config.bytes,
                                               (unsigned int)config.length, tunFd);
    NSLog(@"WebDriverAgentTunnel: hev-socks5-tunnel exited with code %d", code);
    weakSelf.isRunning = NO;
    dispatch_semaphore_signal(exitSemaphore);
  }];
  thread.name = @"hev-socks5-tunnel";
  thread.qualityOfService = NSQualityOfServiceUserInitiated;
  [thread start];
}

- (BOOL)stopAndWait:(NSTimeInterval)timeout
{
  dispatch_semaphore_t exitSemaphore = self.exitSemaphore;
  if (!self.isRunning || nil == exitSemaphore) {
    return YES;
  }
  hev_socks5_tunnel_quit();
  return 0 == dispatch_semaphore_wait(exitSemaphore,
                                      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
}

- (void)getStatsTxPackets:(size_t *)txPackets
                  txBytes:(size_t *)txBytes
                rxPackets:(size_t *)rxPackets
                  rxBytes:(size_t *)rxBytes
{
  hev_socks5_tunnel_stats(txPackets, txBytes, rxPackets, rxBytes);
}

@end
