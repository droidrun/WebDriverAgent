/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <XCTest/XCTest.h>

#import "FBSocks5TunnelManager.h"
#import "FBSocks5TunnelProtocol.h"
#import "FBSocks5URI.h"

@interface FBSocks5ConfigTests : XCTestCase
@property (nonatomic, nullable, copy) NSString *tempBundleRoot;
@end

@implementation FBSocks5ConfigTests

- (NSString *)yamlForURI:(NSString *)uriString
{
  FBSocks5URI *uri = [FBSocks5URI parse:uriString error:nil];
  NSDictionary *config = uri.providerConfiguration;
  return FBSocks5HevConfigFromProviderConfiguration(config);
}

- (void)testYAMLContainsSocks5Server
{
  NSString *yaml = [self yamlForURI:@"socks5://1.2.3.4:9050"];
  XCTAssertTrue([yaml containsString:@"address: '1.2.3.4'"]);
  XCTAssertTrue([yaml containsString:@"port: 9050"]);
  XCTAssertTrue([yaml containsString:@"udp: 'udp'"]);
}

- (void)testYAMLConfiguresTunnelInterfaceFromSharedConstants
{
  NSString *yaml = [self yamlForURI:@"socks5://1.2.3.4"];
  NSString *mtuLine = [NSString stringWithFormat:@"mtu: %lu", (unsigned long)FBSocks5TunnelMTU];
  NSString *ipv4Line = [NSString stringWithFormat:@"ipv4: %@", FBSocks5TunnelIPv4Address];
  XCTAssertTrue([yaml containsString:mtuLine]);
  XCTAssertTrue([yaml containsString:ipv4Line]);
}

- (void)testYAMLOmitsCredentialsWhenAbsent
{
  NSString *yaml = [self yamlForURI:@"socks5://1.2.3.4"];
  XCTAssertFalse([yaml containsString:@"username"]);
  XCTAssertFalse([yaml containsString:@"password"]);
}

- (void)testYAMLContainsCredentialsWhenProvided
{
  NSString *yaml = [self yamlForURI:@"socks5://user:pa55@1.2.3.4"];
  XCTAssertTrue([yaml containsString:@"username: 'user'"]);
  XCTAssertTrue([yaml containsString:@"password: 'pa55'"]);
}

- (void)testYAMLEscapesSingleQuotesInCredentials
{
  NSString *yaml = [self yamlForURI:@"socks5://user:p%27s@1.2.3.4"];
  XCTAssertTrue([yaml containsString:@"password: 'p''s'"]);
}

- (void)testYAMLOmitsMapDNSForLocalResolution
{
  NSString *yaml = [self yamlForURI:@"socks5://1.2.3.4"];
  XCTAssertFalse([yaml containsString:@"mapdns"]);
}

- (void)testYAMLEnablesMapDNSForRemoteResolution
{
  NSString *yaml = [self yamlForURI:@"socks5h://1.2.3.4"];
  NSString *dnsLine = [NSString stringWithFormat:@"address: %@", FBSocks5TunnelMapDNSAddress];
  XCTAssertTrue([yaml containsString:@"mapdns:"]);
  XCTAssertTrue([yaml containsString:dnsLine]);
}

#pragma mark - Tunnel extension presence

- (NSBundle *)makeFakeRunnerBundleWithTunnelAppex:(BOOL)withAppex
{
  NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
  NSString *plugIns = [root stringByAppendingPathComponent:@"PlugIns"];
  NSError *error;
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtPath:plugIns
                                        withIntermediateDirectories:YES
                                                         attributes:nil
                                                              error:&error],
                @"%@", error);
  if (withAppex) {
    NSString *appex = [plugIns stringByAppendingPathComponent:@"WebDriverAgentTunnel.appex"];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtPath:appex
                                          withIntermediateDirectories:YES
                                                           attributes:nil
                                                                error:&error],
                  @"%@", error);
  }
  self.tempBundleRoot = root;
  NSBundle *bundle = [NSBundle bundleWithPath:root];
  XCTAssertNotNil(bundle);
  return bundle;
}

- (void)tearDown
{
  if (nil != self.tempBundleRoot) {
    [NSFileManager.defaultManager removeItemAtPath:self.tempBundleRoot error:nil];
    self.tempBundleRoot = nil;
  }
  [super tearDown];
}

- (void)testTunnelExtensionDetectedWhenAppexEmbedded
{
  NSBundle *bundle = [self makeFakeRunnerBundleWithTunnelAppex:YES];
  XCTAssertTrue([FBSocks5TunnelManager isTunnelExtensionEmbeddedInBundle:bundle]);
}

- (void)testTunnelExtensionNotDetectedWithoutAppex
{
  NSBundle *bundle = [self makeFakeRunnerBundleWithTunnelAppex:NO];
  XCTAssertFalse([FBSocks5TunnelManager isTunnelExtensionEmbeddedInBundle:bundle]);
}

@end
