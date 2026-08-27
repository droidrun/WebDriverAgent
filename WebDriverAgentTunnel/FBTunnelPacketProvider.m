/**
 * Copyright (c) 2026-present, Droidrun.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBTunnelPacketProvider.h"

#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <unistd.h>

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

// Resolves a proxy host to its literal IPs, IPv4 first (the engine's preferred family), each
// family preserving resolver order, without duplicates. The engine must not resolve the host
// itself: once the tunnel's DNS settings are active, an in-provider lookup would be routed
// back into the tunnel that is not functional yet. Every candidate is returned rather than
// just the first per family, so the pre-flight can fail over to later A/AAAA records when the
// first one is unreachable. An entry's family is recoverable from the literal itself (IPv6
// literals contain ':').
static NSArray<NSString *> *FBTunnelResolveHostAddressesBlocking(NSString *host)
{
  struct addrinfo hints;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  struct addrinfo *results = NULL;
  if (0 != getaddrinfo(host.UTF8String, NULL, &hints, &results)) {
    return @[];
  }
  NSMutableArray<NSString *> *ipv4 = [NSMutableArray array];
  NSMutableArray<NSString *> *ipv6 = [NSMutableArray array];
  for (struct addrinfo *entry = results; NULL != entry; entry = entry->ai_next) {
    char buffer[INET6_ADDRSTRLEN] = {0};
    if (AF_INET == entry->ai_family) {
      struct sockaddr_in *addr = (struct sockaddr_in *)entry->ai_addr;
      if (NULL != inet_ntop(AF_INET, &addr->sin_addr, buffer, sizeof(buffer))) {
        NSString *literal = [NSString stringWithUTF8String:buffer];
        if (![ipv4 containsObject:literal]) {
          [ipv4 addObject:literal];
        }
      }
    } else if (AF_INET6 == entry->ai_family) {
      struct sockaddr_in6 *addr = (struct sockaddr_in6 *)entry->ai_addr;
      if (NULL != inet_ntop(AF_INET6, &addr->sin6_addr, buffer, sizeof(buffer))) {
        NSString *literal = FBSocks5IPv6AddressWithScope([NSString stringWithUTF8String:buffer],
                                                         addr->sin6_scope_id);
        if (![ipv6 containsObject:literal]) {
          [ipv6 addObject:literal];
        }
      }
    }
  }
  freeaddrinfo(results);
  return [ipv4 arrayByAddingObjectsFromArray:ipv6];
}

static dispatch_queue_t FBTunnelResolverQueue(void)
{
  static dispatch_queue_t queue;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    queue = dispatch_queue_create("com.facebook.WebDriverAgent.socks5-resolver",
                                  dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                                          QOS_CLASS_UTILITY, 0));
  });
  return queue;
}

static NSArray<NSString *> *_Nullable FBTunnelResolveHostAddresses(NSString *host,
                                                                   NSDate *deadline,
                                                                   FBSocks5TunnelStartupFence *startupFence,
                                                                   BOOL *completed)
{
  BOOL literalIsIPv6 = NO;
  NSString *literal = FBSocks5NormalizedIPAddress(host, &literalIsIPv6);
  if (nil != literal) {
    *completed = YES;
    return @[literal];
  }
  if (startupFence.isStopping || deadline.timeIntervalSinceNow <= 0) {
    *completed = NO;
    return nil;
  }
  __block NSArray<NSString *> *addresses = nil;
  __block volatile atomic_bool cancelled = false;
  dispatch_semaphore_t resolved = dispatch_semaphore_create(0);
  dispatch_async(FBTunnelResolverQueue(), ^{
    if (atomic_load_explicit(&cancelled, memory_order_acquire)) {
      return;
    }
    @autoreleasepool {
      NSArray<NSString *> *result = FBTunnelResolveHostAddressesBlocking(host);
      if (atomic_load_explicit(&cancelled, memory_order_acquire)) {
        return;
      }
      addresses = result;
      dispatch_semaphore_signal(resolved);
    }
  });
  if (![startupFence waitForSignal:resolved beforeDate:deadline]) {
    atomic_store_explicit(&cancelled, true, memory_order_release);
    *completed = NO;
    return nil;
  }
  *completed = YES;
  return addresses;
}

/// How long the pre-flight SOCKS5 handshake may take before the proxy counts as unreachable.
static const NSTimeInterval FBTunnelProbeTimeout = 8.0;
/// Poll in short slices so stop requests cancel an in-flight connect or handshake promptly.
static const NSTimeInterval FBTunnelProbePollInterval = 0.1;
/// Grace period for the engine to fail its own initialization before startup is declared good.
static const NSTimeInterval FBTunnelEngineSettleTimeout = 0.75;

typedef NS_ENUM(NSUInteger, FBTunnelProbeIOResult) {
  FBTunnelProbeIOResultSuccess,
  FBTunnelProbeIOResultTransportFailure,
  FBTunnelProbeIOResultCandidateTimeout,
  FBTunnelProbeIOResultStartupTimeout,
  FBTunnelProbeIOResultStopped,
};

static FBTunnelProbeIOResult FBTunnelWaitForSocket(int fd, short events,
                                                   NSDate *candidateDeadline,
                                                   NSDate *startupDeadline,
                                                   FBSocks5TunnelStartupFence *startupFence)
{
  while (YES) {
    if (startupFence.isStopping) {
      return FBTunnelProbeIOResultStopped;
    }
    NSDate *now = [NSDate date];
    NSTimeInterval startupRemaining = [startupDeadline timeIntervalSinceDate:now];
    if (startupRemaining <= 0) {
      return FBTunnelProbeIOResultStartupTimeout;
    }
    NSTimeInterval candidateRemaining = [candidateDeadline timeIntervalSinceDate:now];
    if (candidateRemaining <= 0) {
      return FBTunnelProbeIOResultCandidateTimeout;
    }
    NSTimeInterval wait = MIN(FBTunnelProbePollInterval,
                              MIN(startupRemaining, candidateRemaining));
    struct pollfd pfd;
    memset(&pfd, 0, sizeof(pfd));
    pfd.fd = fd;
    pfd.events = events;
    int result = poll(&pfd, 1, MAX(1, (int)(wait * 1000)));
    if (result > 0) {
      return FBTunnelProbeIOResultSuccess;
    }
    if (result < 0 && EINTR != errno) {
      return FBTunnelProbeIOResultTransportFailure;
    }
  }
}

static FBTunnelProbeIOResult FBTunnelWriteFully(int fd, const void *bytes, size_t length,
                                                NSDate *candidateDeadline,
                                                NSDate *startupDeadline,
                                                FBSocks5TunnelStartupFence *startupFence)
{
  size_t sent = 0;
  while (sent < length) {
    FBTunnelProbeIOResult waitResult = FBTunnelWaitForSocket(fd, POLLOUT, candidateDeadline,
                                                             startupDeadline, startupFence);
    if (FBTunnelProbeIOResultSuccess != waitResult) {
      return waitResult;
    }
    ssize_t count = send(fd, (const uint8_t *)bytes + sent, length - sent, 0);
    if (count > 0) {
      sent += (size_t)count;
      continue;
    }
    if (count < 0 && (EINTR == errno || EAGAIN == errno || EWOULDBLOCK == errno)) {
      continue;
    }
    return FBTunnelProbeIOResultTransportFailure;
  }
  return FBTunnelProbeIOResultSuccess;
}

static FBTunnelProbeIOResult FBTunnelReadFully(int fd, void *bytes, size_t length,
                                               NSDate *candidateDeadline,
                                               NSDate *startupDeadline,
                                               FBSocks5TunnelStartupFence *startupFence)
{
  size_t received = 0;
  while (received < length) {
    FBTunnelProbeIOResult waitResult = FBTunnelWaitForSocket(fd, POLLIN, candidateDeadline,
                                                             startupDeadline, startupFence);
    if (FBTunnelProbeIOResultSuccess != waitResult) {
      return waitResult;
    }
    ssize_t count = recv(fd, (uint8_t *)bytes + received, length - received, 0);
    if (count > 0) {
      received += (size_t)count;
      continue;
    }
    if (count < 0 && (EINTR == errno || EAGAIN == errno || EWOULDBLOCK == errno)) {
      continue;
    }
    return FBTunnelProbeIOResultTransportFailure;
  }
  return FBTunnelProbeIOResultSuccess;
}

static NSError *FBTunnelProbeError(FBTunnelProbeIOResult result, NSString *transportMessage,
                                   BOOL *outRetryable)
{
  if (FBTunnelProbeIOResultStopped == result) {
    return FBTunnelError(@"The tunnel was stopped while it was still starting up");
  }
  if (FBTunnelProbeIOResultStartupTimeout == result) {
    return FBTunnelError(@"Timed out while starting the SOCKS5 tunnel");
  }
  *outRetryable = YES;
  return FBTunnelError(transportMessage);
}

/**
 Performs a SOCKS5 greeting (and username/password sub-negotiation when credentials are
 configured) against the proxy, then closes the connection.

 hev only dials the proxy once tunneled traffic creates a session, so without this the provider
 would report success for a proxy that is unreachable or rejects the credentials, and every
 packet routed into the tunnel would be silently blackholed. Runs before the tunnel's network
 settings are applied, so it cannot be captured by the tunnel it is validating.

 `outRetryable` is set for transport failures (connect, timeout, or EOF) that may be specific to
 one resolved backend. Protocol and credential rejections are terminal because the proxy itself
 answered them and they should repeat on the other addresses for that service.
 */
static NSError *_Nullable FBTunnelProbeSocks5(NSString *proxyIP, BOOL isIPv6, uint16_t port,
                                              NSString *_Nullable user, NSString *_Nullable pass,
                                              NSDate *candidateDeadline, NSDate *startupDeadline,
                                              FBSocks5TunnelStartupFence *startupFence,
                                              BOOL *outRetryable)
{
  *outRetryable = NO;
  int fd = socket(isIPv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0);
  if (fd < 0) {
    *outRetryable = YES;
    return FBTunnelError(@"Cannot create a socket to probe the SOCKS5 proxy");
  }
  // A proxy that closes the connection mid-handshake makes send() raise SIGPIPE on Darwin,
  // which would terminate the extension outright. The engine installs a process-wide SIGPIPE
  // ignore, but that happens later - this probe runs before it, so opt out per socket.
  int noSigPipe = 1;
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));

  // Keep the socket non-blocking throughout connect and handshake. Short poll slices make both
  // the per-candidate budget and a concurrent stop request observable inside every I/O wait.
  int flags = fcntl(fd, F_GETFL, 0);
  if (flags < 0 || 0 != fcntl(fd, F_SETFL, flags | O_NONBLOCK)) {
    close(fd);
    *outRetryable = YES;
    return FBTunnelError(@"Cannot make the SOCKS5 probe socket non-blocking");
  }

  int connected = -1;
  if (isIPv6) {
    struct sockaddr_in6 addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin6_family = AF_INET6;
    addr.sin6_port = htons(port);
    NSString *literal = nil;
    NSUInteger scopeID = 0;
    if (!FBSocks5ParseIPv6Address(proxyIP, &literal, &scopeID)
        || 1 != inet_pton(AF_INET6, literal.UTF8String, &addr.sin6_addr)) {
      close(fd);
      return FBTunnelError(@"Cannot parse the resolved SOCKS5 proxy address");
    }
    addr.sin6_scope_id = (uint32_t)scopeID;
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
  if (0 != connected && EINPROGRESS == errno) {
    FBTunnelProbeIOResult waitResult = FBTunnelWaitForSocket(fd, POLLOUT, candidateDeadline,
                                                             startupDeadline, startupFence);
    if (FBTunnelProbeIOResultSuccess == waitResult) {
      int socketError = 0;
      socklen_t errorLength = sizeof(socketError);
      if (0 == getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &errorLength) && 0 == socketError) {
        connected = 0;
      } else {
        errno = 0 != socketError ? socketError : ETIMEDOUT;
      }
    } else {
      close(fd);
      return FBTunnelProbeError(waitResult,
                                [NSString stringWithFormat:@"Cannot reach the SOCKS5 proxy at %@:%u",
                                 proxyIP, port],
                                outRetryable);
    }
  }
  if (0 != connected) {
    int err = errno;
    close(fd);
    *outRetryable = YES;
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
  FBTunnelProbeIOResult ioResult = FBTunnelWriteFully(fd, greeting, greetingLength,
                                                      candidateDeadline, startupDeadline,
                                                      startupFence);
  if (FBTunnelProbeIOResultSuccess != ioResult) {
    close(fd);
    return FBTunnelProbeError(ioResult,
                              @"The SOCKS5 proxy closed the connection during the greeting",
                              outRetryable);
  }

  uint8_t choice[2] = {0};
  ioResult = FBTunnelReadFully(fd, choice, sizeof(choice), candidateDeadline, startupDeadline,
                               startupFence);
  if (FBTunnelProbeIOResultSuccess != ioResult) {
    close(fd);
    return FBTunnelProbeError(ioResult, @"The SOCKS5 proxy did not answer the greeting",
                              outRetryable);
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
  if (!FBSocks5TunnelAuthenticationMethodWasOffered(choice[1], hasCredentials)) {
    close(fd);
    if (0x02 == choice[1]) {
      return FBTunnelError(@"The SOCKS5 proxy selected username/password authentication that the client did not offer");
    }
    return FBTunnelError([NSString stringWithFormat:
                          @"The SOCKS5 proxy selected unsupported authentication method 0x%02x", choice[1]]);
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
    ioResult = FBTunnelWriteFully(fd, auth.bytes, auth.length, candidateDeadline, startupDeadline,
                                  startupFence);
    if (FBTunnelProbeIOResultSuccess != ioResult) {
      close(fd);
      return FBTunnelProbeError(ioResult,
                                @"The SOCKS5 proxy closed the connection during authentication",
                                outRetryable);
    }
    uint8_t authReply[2] = {0};
    ioResult = FBTunnelReadFully(fd, authReply, sizeof(authReply), candidateDeadline,
                                 startupDeadline, startupFence);
    if (FBTunnelProbeIOResultSuccess != ioResult) {
      close(fd);
      return FBTunnelProbeError(ioResult,
                                @"The SOCKS5 proxy did not answer the authentication request",
                                outRetryable);
    }
    if (!FBSocks5TunnelUsernamePasswordAuthReplySucceeded(authReply[0], authReply[1])) {
      close(fd);
      if (0x01 != authReply[0]) {
        return FBTunnelError(@"The SOCKS5 proxy returned an invalid username/password authentication reply");
      }
      return FBTunnelError(@"The SOCKS5 proxy rejected the configured credentials");
    }
  }
  close(fd);
  return nil;
}

@interface FBTunnelPacketProvider ()
@property (atomic, nullable) FBTunnelHevRunner *runner;
@property (nonatomic, strong) FBSocks5TunnelStartupFence *startupFence;
@end

@implementation FBTunnelPacketProvider

- (FBSocks5TunnelStartupFence *)startupFence
{
  @synchronized (self) {
    if (nil == _startupFence) {
      _startupFence = [[FBSocks5TunnelStartupFence alloc] init];
    }
    return _startupFence;
  }
}

- (void)finishStartupWithError:(nullable NSError *)error
{
  NSError *stoppedError = FBTunnelError(@"The tunnel was stopped while it was still starting up");
  if ([self.startupFence finishStartupWithError:error stoppedError:stoppedError]) {
    [self finishStopCleanup];
  }
}

- (void)finishStopCleanup
{
  FBTunnelHevRunner *runner;
  @synchronized (self) {
    runner = self.runner;
    self.runner = nil;
  }

  if (nil != runner && ![runner stopAndWait:5.0]) {
    NSLog(@"WebDriverAgentTunnel: HEV did not stop within five seconds; terminating the extension process");
    _exit(EXIT_FAILURE);
  }
  FBSocks5TunnelStartupFence *startupFence = self.startupFence;
  [self setTunnelNetworkSettings:nil completionHandler:^(NSError *_Nullable settingsError) {
    if (nil != settingsError) {
      NSLog(@"WebDriverAgentTunnel: failed to clear tunnel network settings during stop: %@",
            settingsError.localizedDescription);
    }
    [startupFence finishStopCleanup];
  }];
}

- (void)startTunnelWithOptions:(nullable NSDictionary<NSString *, NSObject *> *)options
             completionHandler:(void (^)(NSError *_Nullable))completionHandler
{
  FBSocks5TunnelStartupFence *startupFence = self.startupFence;
  [startupFence beginStartupWithCompletion:completionHandler];
  NSDate *startupDeadline = FBSocks5TunnelStartupDeadlineFromOptions(options, [NSDate date]);
  NETunnelProviderProtocol *protocol = (NETunnelProviderProtocol *)self.protocolConfiguration;
  NSDictionary *config = [protocol isKindOfClass:NETunnelProviderProtocol.class]
    ? protocol.providerConfiguration
    : nil;
  NSString *host = config[FBSocks5KeyHost];
  NSNumber *port = config[FBSocks5KeyPort];
  BOOL controlIsIPv6 = NO;
  NSString *controlAddress = FBSocks5NormalizedIPAddress(config[FBSocks5KeyControlAddress], &controlIsIPv6);
  BOOL remoteDNS = [config[FBSocks5KeyRemoteDNS] boolValue];
  if (0 == host.length || nil == port) {
    [self finishStartupWithError:FBTunnelError(@"The tunnel provider configuration is missing the proxy host/port")];
    return;
  }

  BOOL resolutionCompleted = NO;
  NSArray<NSString *> *candidates = FBTunnelResolveHostAddresses(host, startupDeadline,
                                                                 startupFence, &resolutionCompleted);
  if (!resolutionCompleted) {
    NSError *resolutionError = startupFence.isStopping
      ? FBTunnelError(@"The tunnel was stopped while it was still starting up")
      : FBTunnelError(@"Timed out resolving the SOCKS5 proxy host");
    [self finishStartupWithError:resolutionError];
    return;
  }
  if (0 == candidates.count) {
    [self finishStartupWithError:FBTunnelError([NSString stringWithFormat:@"Cannot resolve the SOCKS5 proxy host '%@'", host])];
    return;
  }
  if (FBSocks5TunnelRemainingStartupTime(startupDeadline, [NSDate date], FBTunnelProbeTimeout) <= 0) {
    [self finishStartupWithError:FBTunnelError(@"Timed out while starting the SOCKS5 tunnel")];
    return;
  }
  NSLog(@"WebDriverAgentTunnel: starting tunnel through %@:%@ (resolved %@, remoteDNS=%d)",
        host, port, [candidates componentsJoinedByString:@", "], remoteDNS);

  // Fail before any routes are installed, so an unreachable proxy or bad credentials surface as
  // a start error instead of a "connected" tunnel that drops every packet. Probing the resolved
  // addresses in order gives the usual DNS failover: a connect/timeout/EOF transport failure
  // moves on to the next record, while a protocol/credential rejection is answered by the proxy
  // itself and fails immediately (it would repeat on every address of the same service).
  NSString *proxyIP = nil;
  BOOL proxyIsIPv6 = NO;
  NSError *probeError = nil;
  for (NSString *candidate in candidates) {
    if (self.startupFence.isStopping) {
      probeError = FBTunnelError(@"The tunnel was stopped while it was still starting up");
      break;
    }
    NSDate *now = [NSDate date];
    NSTimeInterval candidateBudget = FBSocks5TunnelRemainingStartupTime(startupDeadline, now,
                                                                        FBTunnelProbeTimeout);
    if (candidateBudget <= 0) {
      probeError = FBTunnelError(@"Timed out while starting the SOCKS5 tunnel");
      break;
    }
    NSDate *candidateDeadline = [now dateByAddingTimeInterval:candidateBudget];
    BOOL candidateIsIPv6 = [candidate containsString:@":"];
    BOOL retryable = NO;
    probeError = FBTunnelProbeSocks5(candidate, candidateIsIPv6, (uint16_t)port.unsignedIntValue,
                                     config[FBSocks5KeyUser], config[FBSocks5KeyPass],
                                     candidateDeadline, startupDeadline, self.startupFence,
                                     &retryable);
    if (nil == probeError) {
      proxyIP = candidate;
      proxyIsIPv6 = candidateIsIPv6;
      break;
    }
    NSLog(@"WebDriverAgentTunnel: proxy pre-flight failed for %@: %@",
          candidate, probeError.localizedDescription);
    if (!retryable) {
      break;
    }
  }
  if (nil == proxyIP) {
    [self finishStartupWithError:probeError];
    return;
  }
  if (self.startupFence.isStopping) {
    [self finishStartupWithError:FBTunnelError(@"The tunnel was stopped while it was still starting up")];
    return;
  }

  if (nil != controlAddress) {
    NSLog(@"WebDriverAgentTunnel: preserving WDA control route to %@", controlAddress);
  }

  NEPacketTunnelNetworkSettings *settings =
    [[NEPacketTunnelNetworkSettings alloc] initWithTunnelRemoteAddress:proxyIP];
  NEIPv4Settings *ipv4 = [[NEIPv4Settings alloc] initWithAddresses:@[FBSocks5TunnelIPv4Address]
                                                       subnetMasks:@[FBSocks5TunnelIPv4Netmask]];
  ipv4.includedRoutes = @[NEIPv4Route.defaultRoute];
  NSMutableArray<NEIPv4Route *> *excludedIPv4Routes = [NSMutableArray array];
  if (!proxyIsIPv6) {
    // The engine's own TCP connection to the proxy must not loop back into the tunnel.
    [excludedIPv4Routes addObject:[[NEIPv4Route alloc] initWithDestinationAddress:proxyIP
                                                                         subnetMask:@"255.255.255.255"]];
  }
  if (nil != controlAddress && !controlIsIPv6 && ![controlAddress isEqualToString:proxyIP]) {
    [excludedIPv4Routes addObject:[[NEIPv4Route alloc] initWithDestinationAddress:controlAddress
                                                                         subnetMask:@"255.255.255.255"]];
  }
  if (excludedIPv4Routes.count > 0) {
    ipv4.excludedRoutes = excludedIPv4Routes.copy;
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
  NSMutableArray<NEIPv6Route *> *excludedIPv6Routes = [NSMutableArray array];
  if (proxyIsIPv6) {
    // Same reasoning as the IPv4 exclusion: keep the engine's own dial out of its own tunnel.
    [excludedIPv6Routes addObject:[[NEIPv6Route alloc] initWithDestinationAddress:proxyIP
                                                               networkPrefixLength:@128]];
  }
  if (nil != controlAddress && controlIsIPv6 && ![controlAddress isEqualToString:proxyIP]) {
    [excludedIPv6Routes addObject:[[NEIPv6Route alloc] initWithDestinationAddress:controlAddress
                                                               networkPrefixLength:@128]];
  }
  if (excludedIPv6Routes.count > 0) {
    ipv6.excludedRoutes = excludedIPv6Routes.copy;
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
      NSError *deallocatedError = FBTunnelError(@"The tunnel provider was deallocated during startup");
      NSError *stoppedError = FBTunnelError(@"The tunnel was stopped while it was still starting up");
      if ([startupFence finishStartupWithError:deallocatedError stoppedError:stoppedError]) {
        [startupFence finishStopCleanup];
      }
      return;
    }
    if (nil != settingsError) {
      [strongSelf finishStartupWithError:settingsError];
      return;
    }
    if (strongSelf.startupFence.isStopping) {
      [strongSelf finishStartupWithError:FBTunnelError(@"The tunnel was stopped while it was still starting up")];
      return;
    }
    int tunFd = FBTunnelFindTunFd();
    if (tunFd < 0) {
      [strongSelf finishStartupWithError:FBTunnelError(@"Cannot locate the utun file descriptor in the tunnel provider")];
      return;
    }
    // The engine must connect to the already probed address (see FBTunnelResolveHostAddresses).
    NSMutableDictionary *engineConfig = [config mutableCopy];
    engineConfig[FBSocks5KeyHost] = proxyIP;
    NSString *yaml = FBSocks5HevConfigFromProviderConfiguration(engineConfig);
    FBTunnelHevRunner *runner = [[FBTunnelHevRunner alloc] init];
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
    void (^exitHandler)(int) = ^(int exitCode) {
      __strong typeof(weakSelf) exitSelf = weakSelf;
      BOOL shouldCancel = NO;
      @synchronized (startupLock) {
        engineExited = YES;
        shouldCancel = startupAcknowledged;
      }
      dispatch_semaphore_signal(settled);
      if (!shouldCancel || nil == exitSelf || exitSelf.startupFence.isStopping) {
        return;
      }
      NSLog(@"WebDriverAgentTunnel: engine exited unexpectedly (code %d); cancelling the tunnel", exitCode);
      [exitSelf cancelTunnelWithError:
       FBTunnelError([NSString stringWithFormat:@"The SOCKS5 engine exited unexpectedly with code %d", exitCode])];
    };
    // Publishing and starting the runner must be atomic against stopTunnelWithReason:. The
    // startup fence either rejects this action after a stop request, or keeps stop cleanup
    // deferred until startup hands ownership of the published runner back to the fence.
    BOOL started = [strongSelf.startupFence performStartupActionIfNotStopping:^{
      @synchronized (strongSelf) {
        strongSelf.runner = runner;
        [runner startWithConfigYAML:yaml tunFd:tunFd exitHandler:exitHandler];
      }
    }];
    if (!started) {
      [strongSelf finishStartupWithError:FBTunnelError(@"The tunnel was stopped while it was still starting up")];
      return;
    }
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
      @synchronized (strongSelf) {
        if (strongSelf.runner == runner) {
          strongSelf.runner = nil;
        }
      }
      [strongSelf finishStartupWithError:FBTunnelError(@"The SOCKS5 engine failed to start; check the proxy configuration")];
      return;
    }
    [strongSelf finishStartupWithError:nil];
  }];
}

- (void)stopTunnelWithReason:(NEProviderStopReason)reason
           completionHandler:(void (^)(void))completionHandler
{
  NSLog(@"WebDriverAgentTunnel: stopping tunnel (reason %ld)", (long)reason);
  if ([self.startupFence requestStopWithCompletion:completionHandler]) {
    [self finishStopCleanup];
  }
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
