/**
 * Copyright (c) 2026-present, Droidrun.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <XCTest/XCTest.h>

#import "FBMobilerunSocks5Commands.h"
#import "FBRoute.h"
#import "FBSocks5TunnelManager.h"
#import "FBSocks5TunnelProtocol.h"
#import "FBSocks5URI.h"

/**
 NetworkExtension packet tunnels cannot run on the Simulator, so these tests pin down the
 contract the endpoints must keep there: connect/disconnect surface the unsupported error and
 stats always returns the well-formed disconnected payload. The actual tunnel path needs a
 real device with paid-team signing (see docs/socks5-tunnel.md).
 */
@interface FBMobilerunSocks5IntegrationTests : XCTestCase
@end

@implementation FBMobilerunSocks5IntegrationTests

#if TARGET_OS_SIMULATOR

- (void)testConnectIsUnsupportedOnSimulator
{
  FBSocks5URI *uri = [FBSocks5URI parse:@"socks5h://user:pass@1.2.3.4:1080" error:nil];
  XCTAssertNotNil(uri);
  NSError *error;
  BOOL connected = [FBSocks5TunnelManager.sharedInstance connectWithURI:(FBSocks5URI *)uri
                                                                timeout:5
                                                    consentButtonLabels:nil
                                                                  error:&error];
  XCTAssertFalse(connected);
  XCTAssertEqualObjects(error.domain, FBSocks5TunnelManagerErrorDomain);
  XCTAssertEqual(error.code, FBSocks5TunnelManagerErrorUnsupported);
}

- (void)testDisconnectIsUnsupportedOnSimulator
{
  NSError *error;
  XCTAssertFalse([FBSocks5TunnelManager.sharedInstance disconnectWithError:&error]);
  XCTAssertEqualObjects(error.domain, FBSocks5TunnelManagerErrorDomain);
  XCTAssertEqual(error.code, FBSocks5TunnelManagerErrorUnsupported);
}

#endif

- (void)testStatsReportDisconnectedShape
{
  NSDictionary *stats = [FBSocks5TunnelManager.sharedInstance statsDictionary];
  XCTAssertEqualObjects(stats[FBSocks5StatsKeyConnected], @NO);
  for (NSString *key in @[FBSocks5StatsKeyRxBytes, FBSocks5StatsKeyTxBytes,
                          FBSocks5StatsKeyRxPackets, FBSocks5StatsKeyTxPackets]) {
    XCTAssertEqualObjects(stats[key], @0, @"missing zero counter for %@", key);
  }
  XCTAssertNil(stats[FBSocks5StatsKeyHost]);
  XCTAssertNil(stats[FBSocks5StatsKeyPort]);
  XCTAssertNil(stats[FBSocks5StatsKeyUser]);
}

- (void)testRoutesAreRegistered
{
  NSArray<FBRoute *> *routes = [FBMobilerunSocks5Commands routes];
  XCTAssertEqual(routes.count, 6);
  NSMutableSet<NSString *> *seen = [NSMutableSet set];
  for (FBRoute *route in routes) {
    if ([route.path hasSuffix:@"/mobilerun/socks5/connect"] || [route.path hasSuffix:@"/mobilerun/socks5/disconnect"]) {
      XCTAssertEqualObjects(route.verb, @"POST");
    } else if ([route.path hasSuffix:@"/mobilerun/socks5/stats"]) {
      XCTAssertEqualObjects(route.verb, @"GET");
    } else {
      XCTFail(@"unexpected route %@ %@", route.verb, route.path);
    }
    [seen addObject:route.path];
  }
  // Each endpoint must be reachable both with and without a session prefix.
  XCTAssertEqual(seen.count, 6);
}

@end
