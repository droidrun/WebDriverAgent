/**
 * Copyright (c) 2026-present, Droidrun.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <XCTest/XCTest.h>

#import "FBSocks5TunnelManager.h"
#import "FBSocks5TunnelProtocol.h"
#import "FBSocks5URI.h"

@interface FBSocks5LifecycleGuard : NSObject
@property (atomic, strong, nullable) dispatch_semaphore_t pendingSaveSignal;
- (BOOL)performLockedWithDeadline:(nullable NSDate *)deadline
                            block:(NS_NOESCAPE dispatch_block_t)block;
- (BOOL)fencePendingSaveWithDeadline:(nullable NSDate *)deadline error:(NSError **)error;
@end

extern FBSocks5TunnelManagerError FBSocks5TunnelManagerSaveFailureCode(BOOL completed);
extern NSDictionary<NSString *, id> *_Nullable FBSocks5TunnelManagerDisconnectedStatsIfExtensionUnavailable(NSBundle *bundle);

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

- (void)testProviderConfigurationCarriesControlAddress
{
  NSError *error;
  FBSocks5URI *uri = [FBSocks5URI parse:@"socks5://proxy.example.com:1080" error:&error];
  XCTAssertNotNil(uri, @"%@", error);

  NSDictionary<NSString *, id> *config = [uri providerConfigurationWithControlAddress:@"192.0.2.20"];
  XCTAssertEqualObjects(config[FBSocks5KeyControlAddress], @"192.0.2.20");
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

- (void)testMissingTunnelExtensionProducesDisconnectedNoOpSnapshot
{
  NSBundle *bundleWithoutExtension = [self makeFakeRunnerBundleWithTunnelAppex:NO];
  NSDictionary<NSString *, id> *snapshot =
    FBSocks5TunnelManagerDisconnectedStatsIfExtensionUnavailable(bundleWithoutExtension);

  XCTAssertEqualObjects(snapshot[FBSocks5StatsKeyConnected], @NO);
  XCTAssertEqualObjects(snapshot[FBSocks5StatsKeyRxBytes], @0);
  XCTAssertEqualObjects(snapshot[FBSocks5StatsKeyTxBytes], @0);
}

- (void)testEmbeddedTunnelExtensionDoesNotShortCircuitDisconnect
{
  NSBundle *bundleWithExtension = [self makeFakeRunnerBundleWithTunnelAppex:YES];
  XCTAssertNil(FBSocks5TunnelManagerDisconnectedStatsIfExtensionUnavailable(bundleWithExtension));
}

#pragma mark - Lifecycle serialization

- (void)testLifecycleLockAcquisitionExpiresWithoutRunningQueuedBlockLater
{
  FBSocks5LifecycleGuard *guard = [[FBSocks5LifecycleGuard alloc] init];
  dispatch_semaphore_t lockHeld = dispatch_semaphore_create(0);
  dispatch_semaphore_t releaseLock = dispatch_semaphore_create(0);
  dispatch_semaphore_t holderDone = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
    [guard performLockedWithDeadline:nil block:^{
      dispatch_semaphore_signal(lockHeld);
      dispatch_semaphore_wait(releaseLock, DISPATCH_TIME_FOREVER);
    }];
    dispatch_semaphore_signal(holderDone);
  });
  XCTAssertEqual(0, dispatch_semaphore_wait(lockHeld, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)));

  __block BOOL queuedBlockRan = NO;
  NSDate *startedAt = [NSDate date];
  BOOL acquired = [guard performLockedWithDeadline:[NSDate dateWithTimeIntervalSinceNow:0.05]
                                             block:^{
    queuedBlockRan = YES;
  }];
  NSTimeInterval elapsed = -startedAt.timeIntervalSinceNow;

  XCTAssertFalse(acquired);
  XCTAssertFalse(queuedBlockRan);
  XCTAssertLessThan(elapsed, 0.2);
  dispatch_semaphore_signal(releaseLock);
  XCTAssertEqual(0, dispatch_semaphore_wait(holderDone, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)));
  XCTAssertFalse(queuedBlockRan);
}

- (void)testTimedOutPendingSaveFenceRemainsArmedUntilSaveCompletes
{
  FBSocks5LifecycleGuard *guard = [[FBSocks5LifecycleGuard alloc] init];
  dispatch_semaphore_t saveSignal = dispatch_semaphore_create(0);
  guard.pendingSaveSignal = saveSignal;

  NSError *error;
  XCTAssertFalse([guard fencePendingSaveWithDeadline:[NSDate dateWithTimeIntervalSinceNow:0.03]
                                               error:&error]);
  XCTAssertEqual(error.code, FBSocks5TunnelManagerErrorTimeout);
  XCTAssertEqual(guard.pendingSaveSignal, saveSignal);

  dispatch_semaphore_signal(saveSignal);
  error = nil;
  XCTAssertTrue([guard fencePendingSaveWithDeadline:[NSDate dateWithTimeIntervalSinceNow:0.1]
                                              error:&error]);
  XCTAssertNil(error);
  XCTAssertNil(guard.pendingSaveSignal);
}

- (void)testTunnelStopWaitsForPendingStartupAndSettingsCleanup
{
  FBSocks5TunnelStartupFence *fence = [[FBSocks5TunnelStartupFence alloc] init];
  __block NSError *startupError = nil;
  __block BOOL stopCompleted = NO;
  [fence beginStartupWithCompletion:^(NSError *error) {
    startupError = error;
  }];

  XCTAssertFalse([fence requestStopWithCompletion:^{
    stopCompleted = YES;
  }]);
  __block BOOL lateStartupActionRan = NO;
  XCTAssertFalse([fence performStartupActionIfNotStopping:^{
    lateStartupActionRan = YES;
  }]);

  NSError *stoppedError = [NSError errorWithDomain:@"test" code:1 userInfo:nil];
  XCTAssertTrue([fence finishStartupWithError:nil stoppedError:stoppedError]);
  XCTAssertEqual(startupError, stoppedError);
  XCTAssertFalse(lateStartupActionRan);
  XCTAssertFalse(stopCompleted, @"stop must wait until network settings have been cleared");

  [fence finishStopCleanup];
  XCTAssertTrue(stopCompleted);
}

- (void)testTunnelStartupDeadlineUsesOneHostSuppliedBudget
{
  NSDate *now = [NSDate dateWithTimeIntervalSinceReferenceDate:1000];
  NSDate *hostDeadline = [NSDate dateWithTimeIntervalSinceReferenceDate:1005];
  NSDictionary<NSString *, NSObject *> *options = @{
    FBSocks5OptionStartupDeadline: @(hostDeadline.timeIntervalSinceReferenceDate),
  };

  NSDate *deadline = FBSocks5TunnelStartupDeadlineFromOptions(options, now);

  XCTAssertEqualObjects(deadline, hostDeadline);
  XCTAssertEqualWithAccuracy(FBSocks5TunnelRemainingStartupTime(deadline,
                                                                [now dateByAddingTimeInterval:3],
                                                                8.0),
                             2.0, 0.001);
  XCTAssertEqual(FBSocks5TunnelRemainingStartupTime(deadline,
                                                    [now dateByAddingTimeInterval:6],
                                                    8.0),
                 0.0);
}

- (void)testTunnelStartupDeadlineDefaultsWhenHostOptionIsAbsent
{
  NSDate *now = [NSDate dateWithTimeIntervalSinceReferenceDate:1000];

  NSDate *deadline = FBSocks5TunnelStartupDeadlineFromOptions(nil, now);

  XCTAssertEqualWithAccuracy([deadline timeIntervalSinceDate:now],
                             FBSocks5DefaultStartupTimeout,
                             0.001);
}

- (void)testTunnelStartupSignalWaitStopsAtDeadline
{
  FBSocks5TunnelStartupFence *fence = [[FBSocks5TunnelStartupFence alloc] init];
  dispatch_semaphore_t lateSignal = dispatch_semaphore_create(0);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                 dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
    dispatch_semaphore_signal(lateSignal);
  });

  NSDate *startedAt = [NSDate date];
  XCTAssertFalse([fence waitForSignal:lateSignal
                          beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.03]]);
  XCTAssertLessThan(-startedAt.timeIntervalSinceNow, 0.25);
}

- (void)testTunnelStartupSignalWaitCancelsForStop
{
  FBSocks5TunnelStartupFence *fence = [[FBSocks5TunnelStartupFence alloc] init];
  dispatch_semaphore_t neverSignal = dispatch_semaphore_create(0);
  __block BOOL stopCompleted = NO;
  [fence beginStartupWithCompletion:^(NSError *error) {}];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)),
                 dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
    [fence requestStopWithCompletion:^{
      stopCompleted = YES;
    }];
  });

  NSDate *startedAt = [NSDate date];
  XCTAssertFalse([fence waitForSignal:neverSignal
                          beforeDate:[NSDate dateWithTimeIntervalSinceNow:1.0]]);
  XCTAssertLessThan(-startedAt.timeIntervalSinceNow, 0.3);
  NSError *stoppedError = [NSError errorWithDomain:@"test" code:1 userInfo:nil];
  XCTAssertTrue([fence finishStartupWithError:nil stoppedError:stoppedError]);
  XCTAssertFalse(stopCompleted);
  [fence finishStopCleanup];
  XCTAssertTrue(stopCompleted);
}

- (void)testUsernamePasswordAuthReplyRequiresExpectedVersionAndSuccessStatus
{
  XCTAssertTrue(FBSocks5TunnelUsernamePasswordAuthReplySucceeded(0x01, 0x00));
  XCTAssertFalse(FBSocks5TunnelUsernamePasswordAuthReplySucceeded(0x00, 0x00));
  XCTAssertFalse(FBSocks5TunnelUsernamePasswordAuthReplySucceeded(0x02, 0x00));
  XCTAssertFalse(FBSocks5TunnelUsernamePasswordAuthReplySucceeded(0x01, 0x01));
}

- (void)testProxyMayOnlySelectAnAuthenticationMethodOfferedByTheClient
{
  XCTAssertTrue(FBSocks5TunnelAuthenticationMethodWasOffered(0x00, NO));
  XCTAssertFalse(FBSocks5TunnelAuthenticationMethodWasOffered(0x02, NO));
  XCTAssertTrue(FBSocks5TunnelAuthenticationMethodWasOffered(0x00, YES));
  XCTAssertTrue(FBSocks5TunnelAuthenticationMethodWasOffered(0x02, YES));
  XCTAssertFalse(FBSocks5TunnelAuthenticationMethodWasOffered(0x01, YES));
}

- (void)testUnfinishedPreferencesSaveIsClassifiedAsTimeout
{
  XCTAssertEqual(FBSocks5TunnelManagerSaveFailureCode(NO), FBSocks5TunnelManagerErrorTimeout);
  XCTAssertEqual(FBSocks5TunnelManagerSaveFailureCode(YES), FBSocks5TunnelManagerErrorNotAuthorized);
}

@end
