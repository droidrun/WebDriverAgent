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

/// How long the pre-flight SOCKS5 handshake may take before the proxy counts as unreachable.
static const NSTimeInterval FBTunnelProbeTimeout = 8.0;
/// Grace period for the engine to fail its own initialization before startup is declared good.
static const NSTimeInterval FBTunnelEngineSettleTimeout = 0.75;

static BOOL FBTunnelSetSocketTimeout(int fd, NSTimeInterval seconds)
{
  struct timeval tv;
  tv.tv_sec = (time_t)seconds;
  tv.tv_usec = (suseconds_t)((seconds - (NSTimeInterval)tv.tv_sec) * 1000000);
  return 0 == setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv))
      && 0 == setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
}

static BOOL FBTunnelReadFully(int fd, uint8_t *buffer, size_t length)
{
  size_t got = 0;
  while (got < length) {
    ssize_t n = recv(fd, buffer + got, length - got, 0);
    if (n <= 0) {
      return NO;
    }
    got += (size_t)n;
  }
  return YES;
}

/**
 Performs a SOCKS5 greeting (and username/password sub-negotiation when credentials are
 configured) against the proxy, then closes the connection.

 hev only dials the proxy once tunneled traffic creates a session, so without this the provider
 would report success for a proxy that is unreachable or rejects the credentials, and every
 packet routed into the tunnel would be silently blackholed. Runs before the tunnel's network
 settings are applied, so it cannot be captured by the tunnel it is validating.
 */
static NSError *_Nullable FBTunnelProbeSocks5(NSString *proxyIP, BOOL isIPv6, uint16_t port,
                                              NSString *_Nullable user, NSString *_Nullable pass)
{
  int fd = socket(isIPv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0);
  if (fd < 0) {
    return FBTunnelError(@"Cannot create a socket to probe the SOCKS5 proxy");
  }
  // A proxy that closes the connection mid-handshake makes send() raise SIGPIPE on Darwin,
  // which would terminate the extension outright. The engine installs a process-wide SIGPIPE
  // ignore, but that happens later - this probe runs before it, so opt out per socket.
  int noSigPipe = 1;
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
  FBTunnelSetSocketTimeout(fd, FBTunnelProbeTimeout);

  int connected = -1;
  if (isIPv6) {
    struct sockaddr_in6 addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin6_family = AF_INET6;
    addr.sin6_port = htons(port);
    if (1 != inet_pton(AF_INET6, proxyIP.UTF8String, &addr.sin6_addr)) {
      close(fd);
      return FBTunnelError(@"Cannot parse the resolved SOCKS5 proxy address");
    }
    connected = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
  } else {
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    if (1 != inet_pton(AF_INET, proxyIP.UTF8String, &addr.sin_addr)) {
      close(fd);
      return FBTunnelError(@"Cannot parse the resolved SOCKS5 proxy address");
    }
    connected = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
  }
  if (0 != connected) {
    int err = errno;
    close(fd);
    return FBTunnelError([NSString stringWithFormat:
                          @"Cannot reach the SOCKS5 proxy at %@:%u: %s", proxyIP, port, strerror(err)]);
  }

  // Mirror hev_socks5_client_write_auth_methods exactly: it always offers a single method -
  // username/password when BOTH fields are set, no-auth otherwise. Offering both here would let
  // a proxy pick one hev never sends, so preflight would pass while every real session is
  // rejected: a no-auth-only proxy with credentials, or a user-without-password URI, would both
  // report connected:true over a tunnel that cannot carry traffic.
  BOOL hasCredentials = user.length > 0 && pass.length > 0;
  uint8_t greeting[3];
  greeting[0] = 0x05;
  greeting[1] = 1;
  greeting[2] = hasCredentials ? 0x02 : 0x00;
  const size_t greetingLength = sizeof(greeting);
  if (send(fd, greeting, greetingLength, 0) != (ssize_t)greetingLength) {
    close(fd);
    return FBTunnelError(@"The SOCKS5 proxy closed the connection during the greeting");
  }

  uint8_t choice[2] = {0};
  if (!FBTunnelReadFully(fd, choice, sizeof(choice))) {
    close(fd);
    return FBTunnelError(@"The SOCKS5 proxy did not answer the greeting");
  }
  if (0x05 != choice[0]) {
    close(fd);
    return FBTunnelError([NSString stringWithFormat:
                          @"The server at %@:%u is not a SOCKS5 proxy", proxyIP, port]);
  }
  if (0xFF == choice[1]) {
    close(fd);
    return FBTunnelError(hasCredentials
                         ? @"The SOCKS5 proxy rejected username/password authentication"
                         : @"The SOCKS5 proxy requires authentication, but the URI has no user AND password pair");
  }
  if (0x02 == choice[1]) {
    NSData *userData = [user dataUsingEncoding:NSUTF8StringEncoding];
    NSData *passData = [(NSString *)pass dataUsingEncoding:NSUTF8StringEncoding];
    if (userData.length > 255 || passData.length > 255) {
      close(fd);
      return FBTunnelError(@"The SOCKS5 credentials exceed the 255 byte protocol limit");
    }
    NSMutableData *auth = [NSMutableData dataWithBytes:(uint8_t[]){0x01} length:1];
    uint8_t userLength = (uint8_t)userData.length;
    [auth appendBytes:&userLength length:1];
    [auth appendData:userData];
    uint8_t passLength = (uint8_t)passData.length;
    [auth appendBytes:&passLength length:1];
    [auth appendData:passData];
    if (send(fd, auth.bytes, auth.length, 0) != (ssize_t)auth.length) {
      close(fd);
      return FBTunnelError(@"The SOCKS5 proxy closed the connection during authentication");
    }
    uint8_t authReply[2] = {0};
    if (!FBTunnelReadFully(fd, authReply, sizeof(authReply))) {
      close(fd);
      return FBTunnelError(@"The SOCKS5 proxy did not answer the authentication request");
    }
    if (0x00 != authReply[1]) {
      close(fd);
      return FBTunnelError(@"The SOCKS5 proxy rejected the configured credentials");
    }
  } else if (0x00 != choice[1]) {
    close(fd);
    return FBTunnelError([NSString stringWithFormat:
                          @"The SOCKS5 proxy selected unsupported authentication method 0x%02x", choice[1]]);
  }
  close(fd);
  return nil;
}

@interface FBTunnelPacketProvider ()
@property (nonatomic, nullable) FBTunnelHevRunner *runner;
/** Set once a stop was requested, so the engine's exit is not mistaken for a crash. */
@property (atomic) BOOL isStopping;
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

  // Fail before any routes are installed, so an unreachable proxy or bad credentials surface as
  // a start error instead of a "connected" tunnel that drops every packet.
  NSError *probeError = FBTunnelProbeSocks5(proxyIP, proxyIsIPv6, (uint16_t)port.unsignedIntValue,
                                            config[FBSocks5KeyUser], config[FBSocks5KeyPass]);
  if (nil != probeError) {
    NSLog(@"WebDriverAgentTunnel: proxy pre-flight failed: %@", probeError.localizedDescription);
    completionHandler(probeError);
    return;
  }

  NEPacketTunnelNetworkSettings *settings =
    [[NEPacketTunnelNetworkSettings alloc] initWithTunnelRemoteAddress:proxyIP];
  NEIPv4Settings *ipv4 = [[NEIPv4Settings alloc] initWithAddresses:@[FBSocks5TunnelIPv4Address]
                                                       subnetMasks:@[FBSocks5TunnelIPv4Netmask]];
  ipv4.includedRoutes = @[NEIPv4Route.defaultRoute];
  if (!proxyIsIPv6) {
    // The engine's own TCP connection to the proxy must not loop back into the tunnel.
    ipv4.excludedRoutes = @[[[NEIPv4Route alloc] initWithDestinationAddress:proxyIP
                                                                 subnetMask:@"255.255.255.255"]];
  }
  settings.IPv4Settings = ipv4;

  // Claim IPv6 as well, even though the engine only speaks IPv4. Leaving IPv6 unclaimed is not
  // neutral: on a dual-stack device every AAAA-reachable destination would keep using the real
  // egress while the tunnel was up, quietly defeating the point of routing through the proxy.
  // Capturing it without an IPv6 path in hev means such traffic is dropped rather than leaked -
  // deliberately failing closed. Connections then fall back to IPv4 through the tunnel; a
  // genuinely IPv6-only destination becomes unreachable while connected, which is the trade
  // this makes. Giving hev a real IPv6 interface would lift that and is the follow-up.
  NEIPv6Settings *ipv6 = [[NEIPv6Settings alloc] initWithAddresses:@[FBSocks5TunnelIPv6Address]
                                              networkPrefixLengths:@[@(FBSocks5TunnelIPv6PrefixLength)]];
  ipv6.includedRoutes = @[NEIPv6Route.defaultRoute];
  if (proxyIsIPv6) {
    // Same reasoning as the IPv4 exclusion: keep the engine's own dial out of its own tunnel.
    ipv6.excludedRoutes = @[[[NEIPv6Route alloc] initWithDestinationAddress:proxyIP
                                                       networkPrefixLength:@128]];
  }
  settings.IPv6Settings = ipv6;
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
    FBTunnelHevRunner *runner = [[FBTunnelHevRunner alloc] init];
    strongSelf.runner = runner;
    // An engine that fails to initialize returns from its main almost immediately. Report that
    // as a start failure rather than letting NetworkExtension reach NEVPNStatusConnected; once
    // startup has been acknowledged, an unexpected exit tears the tunnel down instead of leaving
    // it advertised but blackholed.
    // Acknowledgement and exit have to agree under one lock. Checking a plain flag leaves a
    // window where the engine dies after the settle wait but before the flag is set: the exit
    // callback reads NO and suppresses cancellation, and startup then reports success for a dead
    // engine. Under the lock exactly one of the two paths wins - either the exit is already
    // recorded and startup fails, or startup is acknowledged and the exit cancels the tunnel.
    dispatch_semaphore_t settled = dispatch_semaphore_create(0);
    NSObject *startupLock = [NSObject new];
    __block BOOL startupAcknowledged = NO;
    __block BOOL engineExited = NO;
    [runner startWithConfigYAML:yaml tunFd:tunFd exitHandler:^(int exitCode) {
      __strong typeof(weakSelf) exitSelf = weakSelf;
      BOOL shouldCancel = NO;
      @synchronized (startupLock) {
        engineExited = YES;
        shouldCancel = startupAcknowledged;
      }
      dispatch_semaphore_signal(settled);
      if (!shouldCancel || nil == exitSelf || exitSelf.isStopping) {
        return;
      }
      NSLog(@"WebDriverAgentTunnel: engine exited unexpectedly (code %d); cancelling the tunnel", exitCode);
      [exitSelf cancelTunnelWithError:
       FBTunnelError([NSString stringWithFormat:@"The SOCKS5 engine exited unexpectedly with code %d", exitCode])];
    }];
    dispatch_semaphore_wait(settled, dispatch_time(DISPATCH_TIME_NOW,
                                                   (int64_t)(FBTunnelEngineSettleTimeout * NSEC_PER_SEC)));
    BOOL startupFailed = NO;
    @synchronized (startupLock) {
      if (engineExited) {
        startupFailed = YES;
      } else {
        startupAcknowledged = YES;
      }
    }
    if (startupFailed) {
      strongSelf.runner = nil;
      completionHandler(FBTunnelError(@"The SOCKS5 engine failed to start; check the proxy configuration"));
      return;
    }
    completionHandler(nil);
  }];
}

- (void)stopTunnelWithReason:(NEProviderStopReason)reason
           completionHandler:(void (^)(void))completionHandler
{
  NSLog(@"WebDriverAgentTunnel: stopping tunnel (reason %ld)", (long)reason);
  self.isStopping = YES;
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
