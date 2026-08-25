/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBRunLoopSpinner.h"

#import <stdatomic.h>

#import "FBErrorBuilder.h"

static const NSTimeInterval FBWaitInterval = 0.1;

@interface FBRunLoopSpinner ()
@property (nonatomic, copy) NSString *timeoutErrorMessage;
@property (nonatomic, assign) NSTimeInterval timeout;
@property (nonatomic, assign) NSTimeInterval interval;
@end

@implementation FBRunLoopSpinner

+ (void)spinUntilCompletion:(void (^)(void(^completion)(void)))block
{
  [self spinUntilCompletion:block timeout:DBL_MAX];
}

+ (BOOL)spinUntilCompletion:(void (^)(void(^completion)(void)))block timeout:(NSTimeInterval)timeout
{
  // The __block flag is moved to the heap when the completion block escapes, so a completion
  // arriving after a timeout return still writes valid memory and is simply never read.
  __block volatile atomic_bool didFinish = false;
  block(^{
    atomic_fetch_or(&didFinish, true);
  });
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  while (!atomic_fetch_and(&didFinish, false)) {
    if (deadline.timeIntervalSinceNow <= 0) {
      return NO;
    }
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:FBWaitInterval]];
  }
  return YES;
}

- (instancetype)init
{
  self = [super init];
  if (self) {
    _interval = FBWaitInterval;
    _timeout = 60;
  }
  return self;
}

- (instancetype)timeoutErrorMessage:(NSString *)timeoutErrorMessage
{
  self.timeoutErrorMessage = timeoutErrorMessage;
  return self;
}

- (instancetype)timeout:(NSTimeInterval)timeout
{
  self.timeout = timeout;
  return self;
}

- (instancetype)interval:(NSTimeInterval)interval
{
  self.interval = interval;
  return self;
}

- (BOOL)spinUntilTrue:(FBRunLoopSpinnerBlock)untilTrue
{
  return [self spinUntilTrue:untilTrue error:nil];
}

- (BOOL)spinUntilTrue:(FBRunLoopSpinnerBlock)untilTrue error:(NSError **)error
{
  NSDate *timeoutDate = [NSDate dateWithTimeIntervalSinceNow:self.timeout];
  while (!untilTrue()) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:self.interval]];
    if (timeoutDate.timeIntervalSinceNow < 0) {
      return
      [[[FBErrorBuilder builder]
        withDescription:(self.timeoutErrorMessage ?: @"FBRunLoopSpinner timeout")]
       buildError:error];
    }
  }
  return YES;
}

- (id)spinUntilNotNil:(FBRunLoopSpinnerObjectBlock)untilNotNil error:(NSError **)error
{
  __block id object;
  [self spinUntilTrue:^BOOL{
    object = untilNotNil();
    return object != nil;
  } error:error];
  return object;
}

@end
