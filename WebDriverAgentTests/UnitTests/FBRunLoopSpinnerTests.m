/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <XCTest/XCTest.h>

#import "FBRunLoopSpinner.h"

@interface FBRunLoopSpinnerTests : XCTestCase
@property (nonatomic, strong) FBRunLoopSpinner *spinner;
@end

/**
 Non of the test methods should block testing thread.
 If they do, that means they are broken
 */
@implementation FBRunLoopSpinnerTests

- (void)setUp
{
  [super setUp];
  self.spinner = [[FBRunLoopSpinner new] timeout:0.1];
}

- (void)testSpinUntilCompletion
{
  __block BOOL _didExecuteBlock = NO;
  [FBRunLoopSpinner spinUntilCompletion:^(void (^completion)(void)) {
    _didExecuteBlock = YES;
    completion();
  }];
  XCTAssertTrue(_didExecuteBlock);
}

- (void)testSpinUntilTrue
{
  __block BOOL _didExecuteBlock = NO;
  BOOL didSucceed =
  [self.spinner spinUntilTrue:^BOOL{
    _didExecuteBlock = YES;
    return YES;
  }];
  XCTAssertTrue(didSucceed);
  XCTAssertTrue(_didExecuteBlock);
}

- (void)testSpinUntilTrueTimeout
{
  NSError *error;
  BOOL didSucceed =
  [self.spinner spinUntilTrue:^BOOL{
    return NO;
  } error:&error];
  XCTAssertFalse(didSucceed);
  XCTAssertNotNil(error);
}

- (void)testSpinUntilTrueTimeoutMessage
{
  NSString *expectedMessage = @"Magic message";
  NSError *error;
  BOOL didSucceed =
  [[self.spinner timeoutErrorMessage:expectedMessage]
   spinUntilTrue:^BOOL{
     return NO;
   } error:&error];
  XCTAssertFalse(didSucceed);
  XCTAssertEqual(error.localizedDescription, expectedMessage);
}

- (void)testSpinUntilNotNil
{
  __block id expectedObject = NSObject.new;
  NSError *error;
  id returnedObject =
  [self.spinner spinUntilNotNil:^id{
    return expectedObject;
  } error:&error];
  XCTAssertNil(error);
  XCTAssertEqual(returnedObject, expectedObject);
}

- (void)testSpinUntilNotNilTimeout
{
  NSError *error;
  id element =
  [self.spinner spinUntilNotNil:^id{
    return nil;
  } error:&error];
  XCTAssertNil(element);
  XCTAssertNotNil(error);
}

- (void)testBoundedSpinReturnsYesWhenCompletionFires
{
  NSDate *start = [NSDate date];
  BOOL result = [FBRunLoopSpinner spinUntilCompletion:^(void (^completion)(void)) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), completion);
  } timeout:5.0];
  XCTAssertTrue(result);
  XCTAssertLessThan([[NSDate date] timeIntervalSinceDate:start], 4.0);
}

- (void)testBoundedSpinReturnsNoOnTimeout
{
  NSDate *start = [NSDate date];
  BOOL result = [FBRunLoopSpinner spinUntilCompletion:^(void (^completion)(void)) {
    // The completion is intentionally never called
  } timeout:0.5];
  XCTAssertFalse(result);
  NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:start];
  XCTAssertGreaterThanOrEqual(elapsed, 0.5);
  XCTAssertLessThan(elapsed, 3.0);
}

- (void)testBoundedSpinToleratesLateCompletion
{
  __block void (^lateCompletion)(void) = nil;
  BOOL result = [FBRunLoopSpinner spinUntilCompletion:^(void (^completion)(void)) {
    lateCompletion = [completion copy];
  } timeout:0.2];
  XCTAssertFalse(result);
  XCTAssertNotNil(lateCompletion);
  // A completion arriving after the deadline must be a harmless no-op
  lateCompletion();
}

@end
