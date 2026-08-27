/**
 * Copyright (c) 2026-present, Droidrun.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <XCTest/XCTest.h>

#import "FBSocks5TunnelProtocol.h"
#import "FBSocks5URI.h"

@interface FBSocks5URITests : XCTestCase
@end

@implementation FBSocks5URITests

- (void)testParsesPlainSocks5URI
{
  NSError *error;
  FBSocks5URI *uri = [FBSocks5URI parse:@"socks5://1.2.3.4:9050" error:&error];
  XCTAssertNotNil(uri);
  XCTAssertNil(error);
  XCTAssertEqualObjects(uri.host, @"1.2.3.4");
  XCTAssertEqual(uri.port, 9050);
  XCTAssertNil(uri.user);
  XCTAssertNil(uri.pass);
  XCTAssertFalse(uri.remoteDNS);
}

- (void)testSocks5hSetsRemoteDNSAndDefaultsPort
{
  NSError *error;
  FBSocks5URI *uri = [FBSocks5URI parse:@"socks5h://proxy.example.com" error:&error];
  XCTAssertNotNil(uri);
  XCTAssertEqualObjects(uri.host, @"proxy.example.com");
  XCTAssertEqual(uri.port, 1080);
  XCTAssertTrue(uri.remoteDNS);
}

- (void)testSchemeIsCaseInsensitive
{
  FBSocks5URI *uri = [FBSocks5URI parse:@"SOCKS5H://proxy.example.com" error:nil];
  XCTAssertNotNil(uri);
  XCTAssertTrue(uri.remoteDNS);
}

- (void)testParsesPercentEncodedCredentials
{
  NSError *error;
  FBSocks5URI *uri = [FBSocks5URI parse:@"socks5://u%40ser:p%3As%27s@host.example:1081" error:&error];
  XCTAssertNotNil(uri);
  XCTAssertEqualObjects(uri.user, @"u@ser");
  XCTAssertEqualObjects(uri.pass, @"p:s's");
  XCTAssertEqualObjects(uri.host, @"host.example");
  XCTAssertEqual(uri.port, 1081);
}

- (void)testParsesIPv6LiteralHost
{
  NSError *error;
  FBSocks5URI *uri = [FBSocks5URI parse:@"socks5://[fc00::1]:1080" error:&error];
  XCTAssertNotNil(uri);
  XCTAssertEqualObjects(uri.host, @"fc00::1");
  XCTAssertEqual(uri.port, 1080);
}

- (void)testRejectsUnsupportedScheme
{
  for (NSString *bad in @[@"http://host", @"socks4://host", @"socks://host"]) {
    NSError *error;
    XCTAssertNil([FBSocks5URI parse:bad error:&error], @"%@ should be rejected", bad);
    XCTAssertNotNil(error, @"%@ should produce an error", bad);
  }
}

- (void)testRejectsMissingHost
{
  for (NSString *bad in @[@"socks5://", @"socks5://:1080", @"socks5h://user:pass@"]) {
    NSError *error;
    XCTAssertNil([FBSocks5URI parse:bad error:&error], @"%@ should be rejected", bad);
    XCTAssertNotNil(error, @"%@ should produce an error", bad);
  }
}

- (void)testRejectsInvalidInput
{
  for (NSString *bad in @[@"", @"not a uri at all", @"socks5://h:port", @"socks5://h:70000",
                            @"socks5://proxy:", @"socks5://proxy:18446744073709551616"]) {
    NSError *error;
    XCTAssertNil([FBSocks5URI parse:bad error:&error], @"'%@' should be rejected", bad);
    XCTAssertNotNil(error, @"'%@' should produce an error", bad);
  }
  NSError *error;
  XCTAssertNil([FBSocks5URI parse:nil error:&error]);
  XCTAssertNotNil(error);
}

- (void)testRejectsIncompleteCredentials
{
  for (NSString *bad in @[@"socks5://user@proxy", @"socks5://:pass@proxy"]) {
    NSError *error;
    XCTAssertNil([FBSocks5URI parse:bad error:&error], @"'%@' should be rejected", bad);
    XCTAssertNotNil(error, @"'%@' should produce an error", bad);
  }
}

- (void)testParseErrorsDoNotExposeCredentials
{
  NSDictionary<NSString *, NSString *> *invalidURIs = @{
    @"http://alice:secret@proxy": @"not a valid SOCKS5 proxy URI",
    @"socks5://alice:secret@": @"must include a proxy host",
    @"socks5://alice:secret@proxy:": @"invalid proxy port",
  };
  [invalidURIs enumerateKeysAndObjectsUsingBlock:^(NSString *uriString, NSString *reason, BOOL *stop) {
    NSError *error;
    XCTAssertNil([FBSocks5URI parse:uriString error:&error]);
    XCTAssertNotNil(error);
    XCTAssertTrue([error.localizedDescription containsString:reason], @"%@", error);
    XCTAssertFalse([error.localizedDescription containsString:@"alice"], @"%@", error);
    XCTAssertFalse([error.localizedDescription containsString:@"secret"], @"%@", error);
  }];
}

- (void)testProviderConfigurationContainsConnectionDetails
{
  FBSocks5URI *uri = [FBSocks5URI parse:@"socks5h://user:pass@1.2.3.4:9050" error:nil];
  NSDictionary *config = uri.providerConfiguration;
  XCTAssertEqualObjects(config[FBSocks5KeyHost], @"1.2.3.4");
  XCTAssertEqualObjects(config[FBSocks5KeyPort], @9050);
  XCTAssertEqualObjects(config[FBSocks5KeyUser], @"user");
  XCTAssertEqualObjects(config[FBSocks5KeyPass], @"pass");
  XCTAssertEqualObjects(config[FBSocks5KeyRemoteDNS], @YES);
}

- (void)testProviderConfigurationOmitsAbsentCredentials
{
  FBSocks5URI *uri = [FBSocks5URI parse:@"socks5://1.2.3.4" error:nil];
  NSDictionary *config = uri.providerConfiguration;
  XCTAssertNil(config[FBSocks5KeyUser]);
  XCTAssertNil(config[FBSocks5KeyPass]);
  XCTAssertEqualObjects(config[FBSocks5KeyPort], @1080);
  XCTAssertEqualObjects(config[FBSocks5KeyRemoteDNS], @NO);
}

@end
