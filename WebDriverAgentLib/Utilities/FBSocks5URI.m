/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBSocks5URI.h"

#import "FBSocks5TunnelProtocol.h"

static NSString *const FBSocks5URIErrorDomain = @"com.facebook.WebDriverAgent.socks5";

static BOOL FBSocks5URISetError(NSError **error, NSString *message)
{
  if (nil != error) {
    *error = [NSError errorWithDomain:FBSocks5URIErrorDomain
                                 code:1
                             userInfo:@{NSLocalizedDescriptionKey: message}];
  }
  return NO;
}

@interface FBSocks5URI ()
@property (nonatomic, copy) NSString *host;
@property (nonatomic) NSUInteger port;
@property (nonatomic, copy, nullable) NSString *user;
@property (nonatomic, copy, nullable) NSString *pass;
@property (nonatomic) BOOL remoteDNS;
@end

@implementation FBSocks5URI

+ (nullable instancetype)parse:(nullable NSString *)uriString error:(NSError **)error
{
  if (0 == uriString.length) {
    FBSocks5URISetError(error, @"The socks5 URI must not be empty");
    return nil;
  }
  NSURLComponents *components = [NSURLComponents componentsWithString:(NSString *)uriString];
  NSString *scheme = components.scheme.lowercaseString;
  BOOL remoteDNS = [scheme isEqualToString:@"socks5h"];
  if (!remoteDNS && ![scheme isEqualToString:@"socks5"]) {
    FBSocks5URISetError(error, [NSString stringWithFormat:
        @"'%@' is not a valid SOCKS5 proxy URI. Expected socks5://[user:pass@]host[:port] or socks5h://… for remote DNS resolution", uriString]);
    return nil;
  }
  NSString *host = components.host;
  // Depending on the OS version, -[NSURLComponents host] may keep the brackets around
  // IPv6 literals; the bare address is wanted everywhere downstream.
  if (host.length >= 2 && [host hasPrefix:@"["] && [host hasSuffix:@"]"]) {
    host = [host substringWithRange:NSMakeRange(1, host.length - 2)];
  }
  if (0 == host.length) {
    FBSocks5URISetError(error, [NSString stringWithFormat:@"The socks5 URI '%@' must include a proxy host", uriString]);
    return nil;
  }
  NSUInteger port = FBSocks5DefaultPort;
  if (nil != components.port) {
    NSInteger rawPort = components.port.integerValue;
    if (rawPort <= 0 || rawPort > UINT16_MAX) {
      FBSocks5URISetError(error, [NSString stringWithFormat:@"The socks5 proxy port %@ is out of range (1-65535)", components.port]);
      return nil;
    }
    port = (NSUInteger)rawPort;
  }

  FBSocks5URI *uri = [[self alloc] init];
  uri.host = host;
  uri.port = port;
  uri.user = components.user.length > 0 ? components.user : nil;
  uri.pass = components.password.length > 0 ? components.password : nil;
  uri.remoteDNS = remoteDNS;
  return uri;
}

- (NSDictionary<NSString *, id> *)providerConfiguration
{
  NSMutableDictionary<NSString *, id> *config = [NSMutableDictionary dictionary];
  config[FBSocks5KeyHost] = self.host;
  config[FBSocks5KeyPort] = @(self.port);
  config[FBSocks5KeyRemoteDNS] = @(self.remoteDNS);
  config[FBSocks5KeyUser] = self.user;
  config[FBSocks5KeyPass] = self.pass;
  return config.copy;
}

@end
