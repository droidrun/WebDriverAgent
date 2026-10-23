/**
 * Copyright (c) 2026-present, Droidrun.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <XCTest/XCTest.h>

#import "FBMobilerunA11yCommands.h"

@interface FBFakeStateApplication : NSObject <FBMobilerunStateApplication>
@property (nonatomic) int processID;
@end

@implementation FBFakeStateApplication

+ (instancetype)withProcessID:(int)processID
{
  FBFakeStateApplication *application = [self new];
  application.processID = processID;
  return application;
}

@end

@interface FBMobilerunA11yCommandsTests : XCTestCase
// Every snapshot request, as "<pid>:full" or "<pid>:shallow", in call order.
@property (nonatomic) NSMutableArray<NSString *> *snapshotRequests;
@end

@implementation FBMobilerunA11yCommandsTests

- (void)setUp
{
  [super setUp];
  self.snapshotRequests = [NSMutableArray array];
}

// Runs the state assembly against the given active applications (one per resolution, the last
// one repeating) and snapshot results keyed like 'snapshotRequests'; a missing key is a failed
// snapshot. Returns what the build block received.
- (NSDictionary *)stateWithActiveApplications:(NSArray<FBFakeStateApplication *> *)applications
                                    snapshots:(NSDictionary<NSString *, NSString *> *)snapshots
{
  __block NSUInteger resolutions = 0;
  return [FBMobilerunA11yCommands stateWithActiveApplication:^id<FBMobilerunStateApplication>{
    FBFakeStateApplication *application = applications[MIN(resolutions, applications.count - 1)];
    resolutions++;
    return application;
  } snapshot:^id(id<FBMobilerunStateApplication> application, FBMobilerunSnapshotDepth depth) {
    NSString *request = [NSString stringWithFormat:@"%d:%@", application.processID,
                         FBMobilerunSnapshotDepthFull == depth ? @"full" : @"shallow"];
    [self.snapshotRequests addObject:request];
    return snapshots[request];
  } build:^NSDictionary *(id<FBMobilerunStateApplication> application, id snapshot, BOOL truncated) {
    return @{
      @"pid": @(application.processID),
      @"snapshot": snapshot ?: [NSNull null],
      @"truncated": @(truncated),
    };
  }];
}

- (void)testCompleteSnapshotIsTakenOnce
{
  NSDictionary *state = [self stateWithActiveApplications:@[[FBFakeStateApplication withProcessID:1]]
                                                snapshots:@{@"1:full": @"tree"}];

  XCTAssertEqualObjects(state, (@{@"pid": @1, @"snapshot": @"tree", @"truncated": @NO}));
  XCTAssertEqualObjects(self.snapshotRequests, @[@"1:full"]);
}

- (void)testAppThatTookOverIsSnapshottedInFull
{
  // After a Home press the app resolved at the start of the request can be the one that is
  // leaving the foreground; its snapshot fails, and SpringBoard has taken over by then.
  NSDictionary *state = [self stateWithActiveApplications:@[[FBFakeStateApplication withProcessID:1],
                                                            [FBFakeStateApplication withProcessID:2]]
                                                snapshots:@{@"2:full": @"springboard"}];

  XCTAssertEqualObjects(state, (@{@"pid": @2, @"snapshot": @"springboard", @"truncated": @NO}));
  XCTAssertEqualObjects(self.snapshotRequests, (@[@"1:full", @"2:full"]));
}

- (void)testSameAppIsNotSnapshottedInFullTwice
{
  // A full snapshot that timed out would time out again; each attempt costs the whole budget.
  NSDictionary *state = [self stateWithActiveApplications:@[[FBFakeStateApplication withProcessID:1]]
                                                snapshots:@{@"1:shallow": @"top"}];

  XCTAssertEqualObjects(state, (@{@"pid": @1, @"snapshot": @"top", @"truncated": @YES}));
  XCTAssertEqualObjects(self.snapshotRequests, (@[@"1:full", @"1:shallow"]));
}

- (void)testAppThatTookOverFallsBackToShallowSnapshot
{
  NSDictionary *state = [self stateWithActiveApplications:@[[FBFakeStateApplication withProcessID:1],
                                                            [FBFakeStateApplication withProcessID:2]]
                                                snapshots:@{@"2:shallow": @"top"}];

  XCTAssertEqualObjects(state, (@{@"pid": @2, @"snapshot": @"top", @"truncated": @YES}));
  XCTAssertEqualObjects(self.snapshotRequests, (@[@"1:full", @"2:full", @"2:shallow"]));
}

- (void)testStateNamesTheAppWhenNoSnapshotSucceeds
{
  // The foreground app is known without any snapshot, which is what clients need most; a failed
  // request instead leaves them retrying behind the stuck app for minutes.
  NSDictionary *state = [self stateWithActiveApplications:@[[FBFakeStateApplication withProcessID:1]]
                                                snapshots:@{}];

  XCTAssertEqualObjects(state, (@{@"pid": @1, @"snapshot": [NSNull null], @"truncated": @YES}));
  XCTAssertEqualObjects(self.snapshotRequests, (@[@"1:full", @"1:shallow"]));
}

@end
