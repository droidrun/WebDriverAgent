/**
 * Copyright (c) 2015-present, Facebook, Inc.
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
NSString *const FBSocks5TunnelMapDNSAddress = @"198.18.0.2";
const NSUInteger FBSocks5TunnelMTU = 8500;

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
