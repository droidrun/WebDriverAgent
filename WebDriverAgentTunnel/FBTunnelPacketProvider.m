/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBTunnelPacketProvider.h"

#include <arpa/inet.h>
#include <netdb.h>

#import "FBSocks5TunnelProtocol.h"
#import "FBTunFdFinder.h"
#import "FBTunnelHevRunner.h"

static NSString *const FBTunnelErrorDomain = @"com.facebook.WebDriverAgent.WebDriverAgentTunnel";

static NSError *FBTunnelError(NSString *message)
{
  return [NSError errorWithDomain:FBTunnelErrorDomain
                             code:1
                         userInfo:@{NSLocalizedDescriptionKey: message}];
}

// Resolves a proxy host to a literal IP. The engine must not resolve it itself: once the
// tunnel's DNS settings are active, an in-provider lookup would be routed back into the
// tunnel that is not functional yet. Prefers IPv4; falls back to IPv6.
static NSString *FBTunnelResolveHost(NSString *host, BOOL *isIPv6)
{
  struct addrinfo hints;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  struct addrinfo *results = NULL;
  if (0 != getaddrinfo(host.UTF8String, NULL, &hints, &results)) {
    return nil;
  }
  NSString *ipv4 = nil;
  NSString *ipv6 = nil;
  for (struct addrinfo *entry = results; NULL != entry; entry = entry->ai_next) {
    char buffer[INET6_ADDRSTRLEN] = {0};
    if (AF_INET == entry->ai_family && nil == ipv4) {
      struct sockaddr_in *addr = (struct sockaddr_in *)entry->ai_addr;
      if (NULL != inet_ntop(AF_INET, &addr->sin_addr, buffer, sizeof(buffer))) {
        ipv4 = [NSString stringWithUTF8String:buffer];
      }
    } else if (AF_INET6 == entry->ai_family && nil == ipv6) {
      struct sockaddr_in6 *addr = (struct sockaddr_in6 *)entry->ai_addr;
      if (NULL != inet_ntop(AF_INET6, &addr->sin6_addr, buffer, sizeof(buffer))) {
        ipv6 = [NSString stringWithUTF8String:buffer];
      }
    }
  }
  freeaddrinfo(results);
  if (NULL != isIPv6) {
    *isIPv6 = (nil == ipv4 && nil != ipv6);
  }
  return ipv4 ?: ipv6;
}

@interface FBTunnelPacketProvider ()
@property (nonatomic, nullable) FBTunnelHevRunner *runner;
@end

@implementation FBTunnelPacketProvider

- (void)startTunnelWithOptions:(nullable NSDictionary<NSString *, NSObject *> *)options
             completionHandler:(void (^)(NSError *_Nullable))completionHandler
{
  NETunnelProviderProtocol *protocol = (NETunnelProviderProtocol *)self.protocolConfiguration;
  NSDictionary *config = [protocol isKindOfClass:NETunnelProviderProtocol.class]
    ? protocol.providerConfiguration
    : nil;
  NSString *host = config[FBSocks5KeyHost];
  NSNumber *port = config[FBSocks5KeyPort];
  BOOL remoteDNS = [config[FBSocks5KeyRemoteDNS] boolValue];
  if (0 == host.length || nil == port) {
    completionHandler(FBTunnelError(@"The tunnel provider configuration is missing the proxy host/port"));
    return;
  }

  BOOL proxyIsIPv6 = NO;
  NSString *proxyIP = FBTunnelResolveHost(host, &proxyIsIPv6);
  if (nil == proxyIP) {
    completionHandler(FBTunnelError([NSString stringWithFormat:@"Cannot resolve the SOCKS5 proxy host '%@'", host]));
    return;
  }
  NSLog(@"WebDriverAgentTunnel: starting tunnel through %@:%@ (resolved %@, remoteDNS=%d)",
        host, port, proxyIP, remoteDNS);

  NEPacketTunnelNetworkSettings *settings =
    [[NEPacketTunnelNetworkSettings alloc] initWithTunnelRemoteAddress:proxyIP];
  NEIPv4Settings *ipv4 = [[NEIPv4Settings alloc] initWithAddresses:@[FBSocks5TunnelIPv4Address]
                                                       subnetMasks:@[FBSocks5TunnelIPv4Netmask]];
  ipv4.includedRoutes = @[NEIPv4Route.defaultRoute];
  if (!proxyIsIPv6) {
    // The engine's own TCP connection to the proxy must not loop back into the tunnel.
    // (An IPv6 proxy needs no exclusion: the tunnel only captures IPv4.)
    ipv4.excludedRoutes = @[[[NEIPv4Route alloc] initWithDestinationAddress:proxyIP
                                                                 subnetMask:@"255.255.255.255"]];
  }
  settings.IPv4Settings = ipv4;
  // socks5h: point DNS at hev's mapdns so queries become hostname-preserving CONNECTs.
  // socks5: use public resolvers; the queries travel through the tunnel via the proxy's
  // UDP relay (requires a proxy with UDP ASSOCIATE support).
  NSArray<NSString *> *dnsServers = remoteDNS
    ? @[FBSocks5TunnelMapDNSAddress]
    : @[@"8.8.8.8", @"1.1.1.1"];
  NEDNSSettings *dns = [[NEDNSSettings alloc] initWithServers:dnsServers];
  dns.matchDomains = @[@""];
  settings.DNSSettings = dns;
  settings.MTU = @(FBSocks5TunnelMTU);

  __weak typeof(self) weakSelf = self;
  [self setTunnelNetworkSettings:settings completionHandler:^(NSError *_Nullable settingsError) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (nil == strongSelf) {
      completionHandler(FBTunnelError(@"The tunnel provider was deallocated during startup"));
      return;
    }
    if (nil != settingsError) {
      completionHandler(settingsError);
      return;
    }
    int tunFd = FBTunnelFindTunFd();
    if (tunFd < 0) {
      completionHandler(FBTunnelError(@"Cannot locate the utun file descriptor in the tunnel provider"));
      return;
    }
    // The engine must connect to the already resolved address (see FBTunnelResolveHost).
    NSMutableDictionary *engineConfig = [config mutableCopy];
    engineConfig[FBSocks5KeyHost] = proxyIP;
    NSString *yaml = FBSocks5HevConfigFromProviderConfiguration(engineConfig);
    strongSelf.runner = [[FBTunnelHevRunner alloc] init];
    [strongSelf.runner startWithConfigYAML:yaml tunFd:tunFd];
    completionHandler(nil);
  }];
}

- (void)stopTunnelWithReason:(NEProviderStopReason)reason
           completionHandler:(void (^)(void))completionHandler
{
  NSLog(@"WebDriverAgentTunnel: stopping tunnel (reason %ld)", (long)reason);
  [self.runner stopAndWait:5.0];
  self.runner = nil;
  completionHandler();
}

- (void)handleAppMessage:(NSData *)messageData
       completionHandler:(nullable void (^)(NSData *_Nullable))completionHandler
{
  if (nil == completionHandler) {
    return;
  }
  NSString *message = [[NSString alloc] initWithData:messageData encoding:NSUTF8StringEncoding];
  if (![message isEqualToString:FBSocks5MsgStats]) {
    completionHandler(nil);
    return;
  }
  size_t txPackets = 0;
  size_t txBytes = 0;
  size_t rxPackets = 0;
  size_t rxBytes = 0;
  FBTunnelHevRunner *runner = self.runner;
  if (nil != runner && runner.isRunning) {
    [runner getStatsTxPackets:&txPackets txBytes:&txBytes rxPackets:&rxPackets rxBytes:&rxBytes];
  }
  NSDictionary *stats = @{
    FBSocks5StatsKeyRxBytes: @(rxBytes),
    FBSocks5StatsKeyTxBytes: @(txBytes),
    FBSocks5StatsKeyRxPackets: @(rxPackets),
    FBSocks5StatsKeyTxPackets: @(txPackets),
  };
  completionHandler([NSJSONSerialization dataWithJSONObject:stats options:(NSJSONWritingOptions)0 error:nil]);
}

@end
