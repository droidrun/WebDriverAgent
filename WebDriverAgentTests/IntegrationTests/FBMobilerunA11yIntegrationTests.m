/**
 * Copyright (c) 2026-present, Droidrun.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <XCTest/XCTest.h>

#import "FBIntegrationTestCase.h"
#import "FBMobilerunA11yCommands.h"
#import "FBTestMacros.h"
#import "FBXCAXClientProxy.h"
#import "XCTestPrivateSymbols.h"
#import "XCUIApplication.h"
#import "XCUIApplication+FBHelpers.h"
#import "XCUIElement.h"
#import "XCUIElement+FBIsVisible.h"

@interface FBMobilerunA11yIntegrationTests : FBIntegrationTestCase
@end

@implementation FBMobilerunA11yIntegrationTests

- (void)setUp
{
  [super setUp];
  [self launchApplication];
}

- (void)tearDown
{
  [self.testedApplication terminate];
  [super tearDown];
}

- (void)testStateOfResponsiveAppIsComplete
{
  NSDate *start = [NSDate date];
  NSDictionary *state = [FBMobilerunA11yCommands stateOfActiveApplicationWithScale:1 session:nil];
  NSLog(@"Responsive app state took %.2fs", -start.timeIntervalSinceNow);

  XCTAssertEqualObjects(state[@"truncated"], @NO);
  XCTAssertEqualObjects(state[@"phone_state"][@"packageName"], self.testedApplication.bundleID);
  XCTAssertEqualObjects(state[@"a11y_tree"][@"className"], @"XCUIElementTypeApplication");
  XCTAssertGreaterThan([state[@"a11y_tree"][@"children"] count], 0u);
  NSDictionary *button = [self nodeIn:state[@"a11y_tree"] withContentDescription:@"Deadlock app"];
  XCTAssertEqualObjects(button[@"className"], @"XCUIElementTypeButton");
  XCTAssertEqualObjects(button[@"isClickable"], @YES);
  XCTAssertGreaterThan([button[@"boundsInScreen"][@"right"] integerValue],
                       [button[@"boundsInScreen"][@"left"] integerValue]);
}

- (void)testSnapshotTimeoutDoesNotOutliveTheSnapshot
{
  if (nil != NSProcessInfo.processInfo.environment[@"CI"]) {
    XCTSkip(@"Deliberately freezes the app for several seconds, too slow/flaky for CI");
  }

  // The accessibility timeout applies to every request of the runner; left lowered, it would cut
  // short the snapshots of all other commands.
  NSError *error;
  XCTAssertNotNil([self.testedApplication fb_snapshotWithTimeout:1 parameters:@{} error:&error], @"%@", error);

  XCUIElement *deadlockButton = self.testedApplication.buttons[@"Deadlock app"];
  FBAssertWaitTillBecomesTrue(deadlockButton.fb_isVisible);
  [deadlockButton tap];

  NSDate *start = [NSDate date];
  [FBXCAXClientProxy.sharedClient snapshotForElement:self.testedApplication.accessibilityElement
                                          attributes:FBStandardAttributeNames()
                                             inDepth:YES
                                               error:&error];
  NSTimeInterval elapsed = -start.timeIntervalSinceNow;
  NSLog(@"Unbounded snapshot of the frozen app took %.2fs", elapsed);
  XCTAssertGreaterThan(elapsed, 5.0);
}

- (NSDictionary *)nodeIn:(NSDictionary *)node withContentDescription:(NSString *)contentDescription
{
  if ([node[@"contentDescription"] isEqualToString:contentDescription]) {
    return node;
  }
  for (NSDictionary *child in node[@"children"]) {
    NSDictionary *match = [self nodeIn:child withContentDescription:contentDescription];
    if (nil != match) {
      return match;
    }
  }
  return nil;
}

- (void)testStateOfFrozenAppIsBoundedAndNamesTheApp
{
  if (nil != NSProcessInfo.processInfo.environment[@"CI"]) {
    XCTSkip(@"Deliberately freezes the app for several seconds, too slow/flaky for CI");
  }

  CGSize screenSize = self.testedApplication.frame.size;
  XCUIElement *deadlockButton = self.testedApplication.buttons[@"Deadlock app"];
  FBAssertWaitTillBecomesTrue(deadlockButton.fb_isVisible);
  // Freezes the app's main thread for 20s - see -[ViewController deadlockApp:]. Without a bound
  // the snapshot waits for the app to answer, up to XCTest's 60s accessibility timeout.
  [deadlockButton tap];

  NSDate *start = [NSDate date];
  NSDictionary *state = [FBMobilerunA11yCommands stateOfActiveApplicationWithScale:1 session:nil];
  NSTimeInterval elapsed = -start.timeIntervalSinceNow;
  NSLog(@"Frozen app state took %.2fs", elapsed);

  XCTAssertLessThan(elapsed, FBMobilerunStateSnapshotTimeout + FBMobilerunStateShallowSnapshotTimeout + 2);
  XCTAssertEqualObjects(state[@"truncated"], @YES);
  XCTAssertEqualObjects(state[@"phone_state"][@"packageName"], self.testedApplication.bundleID);
  // Clients reject a null tree, so the app itself still stands in as the root.
  NSDictionary *root = state[@"a11y_tree"];
  XCTAssertEqualObjects(root[@"className"], @"XCUIElementTypeApplication");
  XCTAssertEqualObjects(root[@"packageName"], self.testedApplication.bundleID);
  // Covers the screen in either orientation; on a device the runner's own UIScreen bounds are the
  // letterboxed 320x480 compatibility screen, which falls short of it.
  NSInteger side = (NSInteger)MAX(screenSize.width, screenSize.height);
  XCTAssertGreaterThanOrEqual([root[@"boundsInScreen"][@"right"] integerValue], side);
  XCTAssertGreaterThanOrEqual([root[@"boundsInScreen"][@"bottom"] integerValue], side);
}

@end
