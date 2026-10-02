/**
 * Copyright (c) 2026-present, Droidrun.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <XCTest/XCTest.h>

#import "FBCommandStatus.h"
#import "FBExceptions.h"
#import "FBHTTPStatusCodes.h"
#import "FBMobilerunA11yCommands.h"

@interface FBMobilerunA11yCommandsTests : XCTestCase
@end

@implementation FBMobilerunA11yCommandsTests

static NSException *FBStaleSnapshotException(void)
{
  return [NSException exceptionWithName:FBStaleElementException reason:@"snapshot failed" userInfo:nil];
}

- (void)testStateIsReturnedWhenTheFirstSnapshotSucceeds
{
  __block NSUInteger attempts = 0;
  FBCommandStatus *failure = nil;
  NSDictionary *state = [FBMobilerunA11yCommands stateWithSnapshotAttempt:^NSDictionary *{
    attempts++;
    return @{@"phone_state": @{}};
  } failure:&failure];

  XCTAssertEqualObjects(state, @{@"phone_state": @{}});
  XCTAssertNil(failure);
  XCTAssertEqual(attempts, 1u);
}

- (void)testFailedSnapshotIsRetriedOnce
{
  // After a Home press the app resolved at the start of the request can be the one that is
  // leaving the foreground; its snapshot fails, and a second attempt resolves SpringBoard.
  __block NSUInteger attempts = 0;
  FBCommandStatus *failure = nil;
  NSDictionary *state = [FBMobilerunA11yCommands stateWithSnapshotAttempt:^NSDictionary *{
    if (0 == attempts++) {
      @throw FBStaleSnapshotException();
    }
    return @{@"phone_state": @{@"packageName": @"com.apple.springboard"}};
  } failure:&failure];

  XCTAssertEqualObjects(state[@"phone_state"][@"packageName"], @"com.apple.springboard");
  XCTAssertNil(failure);
  XCTAssertEqual(attempts, 2u);
}

- (void)testPersistentSnapshotFailureIsNotReportedAsNotFound
{
  // A 404 is what a stock WebDriverAgent answers for the missing route, and clients take it as
  // "this runner has no /mobilerun/state" for good. A failed snapshot must say something else,
  // and must not be a 5xx either: that reads as a wedged runner and triggers a relaunch.
  __block NSUInteger attempts = 0;
  FBCommandStatus *failure = nil;
  NSDictionary *state = [FBMobilerunA11yCommands stateWithSnapshotAttempt:^NSDictionary *{
    attempts++;
    @throw FBStaleSnapshotException();
  } failure:&failure];

  XCTAssertNil(state);
  XCTAssertEqual(attempts, 2u);
  XCTAssertNotNil(failure);
  XCTAssertNotEqual(failure.statusCode, kHTTPStatusCodeNotFound);
  XCTAssertGreaterThanOrEqual(failure.statusCode, 400);
  XCTAssertLessThan(failure.statusCode, 500);
  XCTAssertTrue([failure.message containsString:@"snapshot failed"]);
}

- (void)testOtherExceptionsAreNotSwallowed
{
  // Anything but a failed snapshot keeps the global exception mapping (a deadlocked app, say).
  __block NSUInteger attempts = 0;
  FBCommandStatus *failure = nil;
  XCTAssertThrowsSpecificNamed(([FBMobilerunA11yCommands stateWithSnapshotAttempt:^NSDictionary *{
    attempts++;
    @throw [NSException exceptionWithName:FBApplicationDeadlockDetectedException reason:@"" userInfo:nil];
  } failure:&failure]), NSException, FBApplicationDeadlockDetectedException);
  XCTAssertEqual(attempts, 1u);
}

@end
