/**
 * Copyright (c) 2026-present, Droidrun.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBMobilerunA11yCommands.h"

#import "FBCommandStatus.h"
#import "FBExceptions.h"
#import "FBResponsePayload.h"
#import "FBRoute.h"
#import "FBRouteRequest.h"
#import "FBScreen.h"
#import "FBSession.h"
#import "XCUIApplication.h"
#import "XCUIApplication+FBHelpers.h"

// Parses the optional 'scale' query parameter shared by the mobilerun endpoints. Response/request
// coordinates are logical points multiplied by this scale; it defaults to the native screen scale
// (device pixels), and 'scale=1' yields plain points. Returns NO when the parameter is present but
// is not a positive number. Keep in sync with the copy in FBMobilerunActionsCommands.m.
static BOOL FBMobilerunScaleFromRequest(FBRouteRequest *request, CGFloat *scale)
{
  NSString *rawScale = request.parameters[@"scale"];
  if (0 == rawScale.length) {
    *scale = (CGFloat)[FBScreen scale];
    return YES;
  }
  NSScanner *scanner = [NSScanner scannerWithString:rawScale];
  double value = 0;
  if (![scanner scanDouble:&value] || !scanner.isAtEnd || value <= 0) {
    return NO;
  }
  *scale = (CGFloat)value;
  return YES;
}

@implementation FBMobilerunA11yCommands

#pragma mark - <FBCommandHandler>

+ (NSArray *)routes
{
  return
  @[
    [[FBRoute GET:@"/mobilerun/state"] respondWithTarget:self action:@selector(handleGetState:)],
    [[FBRoute GET:@"/mobilerun/state"].withoutSession respondWithTarget:self action:@selector(handleGetState:)],
  ];
}

#pragma mark - Commands

+ (NSDictionary *)stateWithSnapshotAttempt:(NSDictionary *(NS_NOESCAPE ^)(void))attempt
                                   failure:(FBCommandStatus **)failure
{
  NSException *snapshotFailure = nil;
  for (NSUInteger attemptIndex = 0; attemptIndex < 2; attemptIndex++) {
    @try {
      return attempt();
    } @catch (NSException *exception) {
      if (![exception.name isEqualToString:FBStaleElementException]) {
        @throw;
      }
      snapshotFailure = exception;
    }
  }
  // Left to the global exception mapping, a failed snapshot answers 404 (stale element reference),
  // which is also what a stock WebDriverAgent answers for this missing route - so clients take it
  // as "no /mobilerun/state here" and switch to the far slower /source for good. A 5xx would read
  // as a wedged runner instead. The app was just not in a state that can be snapshotted.
  if (failure) {
    *failure = [FBCommandStatus invalidElementStateErrorWithMessage:snapshotFailure.reason
                                                          traceback:nil];
  }
  return nil;
}

+ (id<FBResponsePayload>)handleGetState:(FBRouteRequest *)request
{
  CGFloat scale;
  if (!FBMobilerunScaleFromRequest(request, &scale)) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"'scale' must be a positive number"
                                                                       traceback:nil]);
  }
  FBCommandStatus *failure = nil;
  NSDictionary *state = [self stateWithSnapshotAttempt:^NSDictionary *{
    // Resolved on every attempt: right after a Home press the app picked at the start of the
    // request can be the one leaving the foreground, whose snapshot then fails. The retry resolves
    // the app that took over (SpringBoard).
    XCUIApplication *app = request.session.activeApplication ?: XCUIApplication.fb_activeApplication;
    return [app fb_mobilerunA11yStateWithScale:scale];
  } failure:&failure];
  return nil == state ? FBResponseWithStatus(failure) : FBResponseWithObject(state);
}

@end
