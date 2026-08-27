/**
 * Copyright (c) 2026-present, Droidrun.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBSocks5TunnelProtocol.h"

NSString *const FBSocks5KeyHost = @"host";
NSString *const FBSocks5KeyPort = @"port";
NSString *const FBSocks5KeyUser = @"user";
NSString *const FBSocks5KeyPass = @"pass";
NSString *const FBSocks5KeyRemoteDNS = @"remoteDNS";
NSString *const FBSocks5KeyControlAddress = @"controlAddress";
NSString *const FBSocks5OptionStartupDeadline = @"startupDeadline";

const NSTimeInterval FBSocks5DefaultStartupTimeout = 30.0;

NSString *const FBSocks5MsgStats = @"stats";

NSString *const FBSocks5StatsKeyConnected = @"connected";
NSString *const FBSocks5StatsKeyHost = @"host";
NSString *const FBSocks5StatsKeyPort = @"port";
NSString *const FBSocks5StatsKeyUser = @"user";
NSString *const FBSocks5StatsKeyRxBytes = @"rxBytes";
NSString *const FBSocks5StatsKeyTxBytes = @"txBytes";
NSString *const FBSocks5StatsKeyRxPackets = @"rxPackets";
NSString *const FBSocks5StatsKeyTxPackets = @"txPackets";

const NSUInteger FBSocks5DefaultPort = 1080;

NSString *const FBSocks5TunnelIPv4Address = @"198.18.0.1";
NSString *const FBSocks5TunnelIPv4Netmask = @"255.255.255.0";
// ULA (fc00::/7) so it cannot collide with a real global address on the device.
NSString *const FBSocks5TunnelIPv6Address = @"fd6d:6f62:696c::1";
const NSUInteger FBSocks5TunnelIPv6PrefixLength = 64;
NSString *const FBSocks5TunnelMapDNSAddress = @"198.18.0.2";
const NSUInteger FBSocks5TunnelMTU = 8500;

NSDate *FBSocks5TunnelStartupDeadlineFromOptions(NSDictionary<NSString *, NSObject *> *_Nullable options,
                                                 NSDate *now)
{
  NSNumber *encodedDeadline = [options[FBSocks5OptionStartupDeadline] isKindOfClass:NSNumber.class]
    ? (NSNumber *)options[FBSocks5OptionStartupDeadline]
    : nil;
  if (nil != encodedDeadline && isfinite(encodedDeadline.doubleValue)) {
    return [NSDate dateWithTimeIntervalSinceReferenceDate:encodedDeadline.doubleValue];
  }
  return [now dateByAddingTimeInterval:FBSocks5DefaultStartupTimeout];
}

NSTimeInterval FBSocks5TunnelRemainingStartupTime(NSDate *deadline, NSDate *now, NSTimeInterval cap)
{
  return MAX(0.0, MIN(cap, [deadline timeIntervalSinceDate:now]));
}

BOOL FBSocks5TunnelUsernamePasswordAuthReplySucceeded(uint8_t version, uint8_t status)
{
  return 0x01 == version && 0x00 == status;
}

BOOL FBSocks5TunnelAuthenticationMethodWasOffered(uint8_t method, BOOL hasCredentials)
{
  return 0x00 == method || (hasCredentials && 0x02 == method);
}

@interface FBSocks5TunnelStartupFence ()
@property (nonatomic) BOOL stopping;
@property (nonatomic) BOOL startupInProgress;
@property (nonatomic) BOOL stopCleanupInProgress;
@property (nonatomic, copy, nullable) void (^startupCompletion)(NSError *_Nullable error);
@property (nonatomic, strong) NSMutableArray *stopCompletions;
@end

@implementation FBSocks5TunnelStartupFence

- (BOOL)isStopping
{
  @synchronized (self) {
    return _stopping;
  }
}

- (void)beginStartupWithCompletion:(void (^)(NSError *_Nullable))completion
{
  @synchronized (self) {
    self.startupInProgress = YES;
    self.startupCompletion = completion;
  }
}

- (BOOL)waitForSignal:(dispatch_semaphore_t)signal beforeDate:(NSDate *)deadline
{
  static const NSTimeInterval pollInterval = 0.05;
  while (YES) {
    if (self.isStopping) {
      return NO;
    }
    NSTimeInterval remaining = deadline.timeIntervalSinceNow;
    if (remaining <= 0) {
      return NO;
    }
    dispatch_time_t waitUntil = dispatch_time(DISPATCH_TIME_NOW,
                                               (int64_t)(MIN(pollInterval, remaining) * NSEC_PER_SEC));
    if (0 == dispatch_semaphore_wait(signal, waitUntil)) {
      return !self.isStopping;
    }
  }
}

- (BOOL)performStartupActionIfNotStopping:(dispatch_block_t)block
{
  @synchronized (self) {
    if (_stopping) {
      return NO;
    }
    block();
    return YES;
  }
}

- (BOOL)requestStopWithCompletion:(dispatch_block_t)completion
{
  @synchronized (self) {
    _stopping = YES;
    if (nil == self.stopCompletions) {
      self.stopCompletions = [NSMutableArray array];
    }
    [self.stopCompletions addObject:[completion copy]];
    if (self.startupInProgress || self.stopCleanupInProgress) {
      return NO;
    }
    self.stopCleanupInProgress = YES;
    return YES;
  }
}

- (BOOL)finishStartupWithError:(nullable NSError *)error stoppedError:(NSError *)stoppedError
{
  void (^completion)(NSError *_Nullable) = nil;
  NSError *completionError = nil;
  BOOL shouldStartCleanup = NO;
  @synchronized (self) {
    if (!self.startupInProgress) {
      return NO;
    }
    self.startupInProgress = NO;
    completion = self.startupCompletion;
    self.startupCompletion = nil;
    completionError = _stopping && nil == error ? stoppedError : error;
    if (_stopping && !self.stopCleanupInProgress && self.stopCompletions.count > 0) {
      self.stopCleanupInProgress = YES;
      shouldStartCleanup = YES;
    }
  }
  if (nil != completion) {
    completion(completionError);
  }
  return shouldStartCleanup;
}

- (void)finishStopCleanup
{
  NSArray *completions;
  @synchronized (self) {
    completions = self.stopCompletions.copy;
    [self.stopCompletions removeAllObjects];
    self.stopCleanupInProgress = NO;
  }
  for (dispatch_block_t completion in completions) {
    completion();
  }
}

@end

// YAML single-quoted scalar: the only escape is doubling embedded single quotes.
static NSString *FBSocks5YAMLQuote(NSString *value)
{
  return [NSString stringWithFormat:@"'%@'", [value stringByReplacingOccurrencesOfString:@"'" withString:@"''"]];
}

NSString *FBSocks5HevConfigFromProviderConfiguration(NSDictionary<NSString *, id> *providerConfiguration)
{
  NSString *host = providerConfiguration[FBSocks5KeyHost];
  NSUInteger port = [providerConfiguration[FBSocks5KeyPort] unsignedIntegerValue];
  NSString *user = providerConfiguration[FBSocks5KeyUser];
  NSString *pass = providerConfiguration[FBSocks5KeyPass];
  BOOL remoteDNS = [providerConfiguration[FBSocks5KeyRemoteDNS] boolValue];

  NSMutableString *yaml = [NSMutableString string];
  [yaml appendString:@"tunnel:\n"];
  [yaml appendFormat:@"  mtu: %lu\n", (unsigned long)FBSocks5TunnelMTU];
  [yaml appendFormat:@"  ipv4: %@\n", FBSocks5TunnelIPv4Address];
  [yaml appendString:@"socks5:\n"];
  [yaml appendFormat:@"  address: %@\n", FBSocks5YAMLQuote(host)];
  [yaml appendFormat:@"  port: %lu\n", (unsigned long)port];
  [yaml appendString:@"  udp: 'udp'\n"];
  if (user.length > 0) {
    [yaml appendFormat:@"  username: %@\n", FBSocks5YAMLQuote(user)];
  }
  if (pass.length > 0) {
    [yaml appendFormat:@"  password: %@\n", FBSocks5YAMLQuote(pass)];
  }
  if (remoteDNS) {
    // mapdns answers DNS queries with synthetic IPs from the 100.64.0.0/10 pool and
    // restores the original hostname when those IPs are connected to, so the proxy
    // receives CONNECT-by-hostname (socks5h semantics) without needing UDP support.
    [yaml appendString:@"mapdns:\n"];
    [yaml appendFormat:@"  address: %@\n", FBSocks5TunnelMapDNSAddress];
    [yaml appendString:@"  port: 53\n"];
    [yaml appendString:@"  network: 100.64.0.0\n"];
    [yaml appendString:@"  netmask: 255.192.0.0\n"];
    [yaml appendString:@"  cache-size: 10000\n"];
  }
  [yaml appendString:@"misc:\n"];
  [yaml appendString:@"  log-file: stderr\n"];
  [yaml appendString:@"  log-level: warn\n"];
  return yaml.copy;
}
