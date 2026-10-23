/**
 * Copyright (c) 2026-present, Droidrun.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBMobilerunA11yCommands.h"

#import "FBCommandStatus.h"
#import "FBLogger.h"
#import "FBResponsePayload.h"
#import "FBRoute.h"
#import "FBRouteRequest.h"
#import "FBScreen.h"
#import "FBSession.h"
#import "XCUIApplication.h"
#import "XCUIApplication+FBHelpers.h"
#import "XCAXClient_iOS+FBSnapshotReqParams.h"

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

const NSTimeInterval FBMobilerunStateSnapshotTimeout = 10.;
const NSTimeInterval FBMobilerunStateShallowSnapshotTimeout = 5.;
const int FBMobilerunStateShallowSnapshotMaxDepth = 15;
const int FBMobilerunStateShallowSnapshotMaxChildren = 20;

@interface XCUIApplication (FBMobilerunStateApplication) <FBMobilerunStateApplication>
@end

@implementation XCUIApplication (FBMobilerunStateApplication)
@end

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

+ (NSDictionary *)stateWithActiveApplication:(id<FBMobilerunStateApplication> (NS_NOESCAPE ^)(void))activeApplication
                                    snapshot:(id _Nullable (NS_NOESCAPE ^)(id<FBMobilerunStateApplication> application, FBMobilerunSnapshotDepth depth))snapshot
                                       build:(NSDictionary *(NS_NOESCAPE ^)(id<FBMobilerunStateApplication> application, id _Nullable snapshot, BOOL truncated))build
{
  id<FBMobilerunStateApplication> application = activeApplication();
  id result = snapshot(application, FBMobilerunSnapshotDepthFull);
  if (nil != result) {
    return build(application, result, NO);
  }
  // Right after a Home press the app resolved at the start of the request can be the one leaving
  // the foreground, whose snapshot then fails; the app that took over (SpringBoard) is still worth
  // a full snapshot.
  id<FBMobilerunStateApplication> currentApplication = activeApplication();
  if (currentApplication.processID != application.processID) {
    application = currentApplication;
    result = snapshot(application, FBMobilerunSnapshotDepthFull);
    if (nil != result) {
      return build(application, result, NO);
    }
  }
  // A shallow snapshot can still come back when the full one is too big to finish in time.
  return build(application, snapshot(application, FBMobilerunSnapshotDepthShallow), YES);
}

+ (NSDictionary *)stateOfActiveApplicationWithScale:(CGFloat)scale session:(FBSession *)session
{
  return [self stateWithActiveApplication:^id<FBMobilerunStateApplication>{
    // Detected without a snapshot, so the state names the app even when no snapshot succeeds.
    return session.activeApplication ?: XCUIApplication.fb_activeApplication;
  } snapshot:^id(id<FBMobilerunStateApplication> application, FBMobilerunSnapshotDepth depth) {
    BOOL isFull = FBMobilerunSnapshotDepthFull == depth;
    NSTimeInterval timeout = isFull ? FBMobilerunStateSnapshotTimeout : FBMobilerunStateShallowSnapshotTimeout;
    NSDictionary *parameters = isFull ? @{} : @{
      FBSnapshotMaxDepthKey: @(FBMobilerunStateShallowSnapshotMaxDepth),
      FBSnapshotMaxChildrenKey: @(FBMobilerunStateShallowSnapshotMaxChildren),
    };
    NSError *error;
    id<FBXCElementSnapshot> snapshot = [(XCUIApplication *)application fb_snapshotWithTimeout:timeout
                                                                                   parameters:parameters
                                                                                        error:&error];
    if (nil == snapshot) {
      [FBLogger logFmt:@"The %@ snapshot of %@ failed within %.0fs: %@", isFull ? @"full" : @"shallow",
       ((XCUIApplication *)application).bundleID, timeout, error.localizedDescription];
    }
    return snapshot;
  } build:^NSDictionary *(id<FBMobilerunStateApplication> application, id snapshot, BOOL truncated) {
    return [(XCUIApplication *)application fb_mobilerunA11yStateWithSnapshot:snapshot
                                                                         scale:scale
                                                                     truncated:truncated];
  }];
}

+ (id<FBResponsePayload>)handleGetState:(FBRouteRequest *)request
{
  CGFloat scale;
  if (!FBMobilerunScaleFromRequest(request, &scale)) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"'scale' must be a positive number"
                                                                       traceback:nil]);
  }
  return FBResponseWithObject([self stateOfActiveApplicationWithScale:scale session:request.session]);
}

@end
