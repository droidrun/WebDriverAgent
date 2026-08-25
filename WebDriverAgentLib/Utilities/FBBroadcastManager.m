/**
 * Copyright (c) 2026-present, Droidrun.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBBroadcastManager.h"

#include <time.h>
#import <UIKit/UIKit.h>

#import "FBAudioStreamManager.h"
#import "FBBroadcastControlServer.h"
#import "FBBroadcastPickerHost.h"
#import "FBBroadcastProtocol.h"
#import "FBConfiguration.h"
#import "FBLogger.h"
#import "FBRunLoopSpinner.h"
#import "FBScreen.h"
#import "FBUnattachedAppLauncher.h"
#import "FBVideoStreamManager.h"
#import "FBXCTestDaemonsProxy.h"
#import "XCUIApplication+FBTouchAction.h"
#import "XCUIApplication.h"
#import "XCUIApplication+FBHelpers.h"

NSErrorDomain const FBBroadcastManagerErrorDomain = @"com.facebook.WebDriverAgent.FBBroadcastManager";

#if !TARGET_OS_SIMULATOR && !TARGET_OS_TV
static const NSTimeInterval FOREGROUND_TIMEOUT = 5.0;
static const NSTimeInterval CONFIRM_BUTTON_TIMEOUT = 10.0;
// The picker press is dropped silently by the system when it fires before the scene is fully
// active, so it is re-fired periodically until the confirmation sheet shows up.
static const uint64_t PICKER_RETRIGGER_INTERVAL_MS = 2000;
// How long the post-stop sweep waits for the delayed "Screen Broadcasting" alert to appear
// before giving up on it. SpringBoard publishes the alert well after the extension socket
// closes, and the delay varies by device and iOS version: ~5s observed on iOS 26, and ~10s
// (up to ~12s) on iOS 18 hardware.
static const NSTimeInterval ALERT_APPEARANCE_GRACE_SEC = 15.0;
// Additional budget, on top of the appearance wait, for the dismissal tap(s) to land and the
// alert to be observed gone.
static const NSTimeInterval ALERT_DISMISSAL_BUDGET_SEC = 5.0;

static uint64_t FBBroadcastNowMs(void)
{
  return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / NSEC_PER_MSEC;
}

// Tap via WDA's own event synthesis instead of XCUIElement.tap: a missed XCUIElement tap (e.g.
// the element disappeared in between) records an XCTest failure that tears down the whole test
// session, whereas a missed synthesized tap is harmless and surfaces as a timeout to the caller.
// `app` must be the app whose coordinate space produced `frame`: the synthesized event record is
// stamped with the receiver's interfaceOrientation.
// `waitForAck:NO` is for taps whose outcome the caller observes via state (e.g. does the alert
// still exist on the next spin iteration) and which must not block inside a bounded spin: the
// synthesis acknowledgement can take up to the event-synthesis timeout margin when the system
// sheds the event, and that wait cannot be interrupted by a spinner's own, much shorter, deadline.
static BOOL FBBroadcastTapFrameCenter(XCUIApplication *app, CGRect frame, BOOL waitForAck, NSError **error)
{
  CGFloat scale = (CGFloat)[FBScreen scale];
  CGPoint center = CGPointMake(CGRectGetMidX(frame) * scale, CGRectGetMidY(frame) * scale);
  NSArray *tapActions = @[
    @{@"type": @"pointerDown", @"x": @(center.x), @"y": @(center.y)},
    @{@"type": @"pause", @"duration": @60},
    @{@"type": @"pointerUp", @"x": @(center.x), @"y": @(center.y)},
  ];
  if (waitForAck) {
    return [app fb_performMobilerunActions:tapActions scale:scale error:error];
  }
  XCSynthesizedEventRecord *record = [app fb_mobilerunEventRecordFromActions:tapActions scale:scale error:error];
  if (nil == record) {
    return NO;
  }
  [FBXCTestDaemonsProxy synthesizeEventAsyncWithRecord:record];
  return YES;
}
#endif
static const NSTimeInterval STOP_TIMEOUT = 5.0;

@interface FBBroadcastManager () <FBBroadcastControlServerDelegate>

// Read from connection queues (broadcast status route, sessionless capture-stop notifications)
// while the main thread assigns/clears it - must stay atomic.
@property (atomic, nullable) FBBroadcastControlServer *controlServer;
@property (atomic, nullable, copy) NSDictionary *helloInfo;
@property (atomic, nullable, copy) NSDictionary *lastHeartbeat;
@property (atomic, nullable) NSDate *connectedAt;
@property (atomic, nullable) NSDate *lastHeartbeatAt;
@property (atomic) BOOL paused;
/** YES while a start dance is driving the system UI (used to serialize concurrent starts). */
@property (atomic) BOOL startInProgress;
#if !TARGET_OS_SIMULATOR && !TARGET_OS_TV
/** Monotonic ms timestamp of the last dismissal tap dispatch; guards the re-attempt cooldown. */
@property (atomic) uint64_t lastAlertDismissalAttemptMs;
#endif

#if !TARGET_OS_SIMULATOR && !TARGET_OS_TV
- (BOOL)performBroadcastStartWithTimeout:(NSTimeInterval)timeout
                     confirmButtonLabels:(NSArray<NSString *> *)confirmButtonLabels
                     dismissButtonLabels:(NSArray<NSString *> *)dismissButtonLabels
             goToApplicationButtonLabels:(NSArray<NSString *> *)goToApplicationButtonLabels
                    restoreForegroundApp:(BOOL)restoreForegroundApp
                                   error:(NSError **)error;
// Finds, but does not tap, the dismiss button of the system's stale "Screen Broadcasting" alert
// (posted by SpringBoard whenever a broadcast ends) when one is on screen. The alert is matched
// structurally, not by its (localized) title: exactly two buttons, of which exactly one matches
// dismissLabels and the OTHER matches goToAppLabels - the second button anchors the alert's
// identity, since "exactly one of two buttons matches the dismiss labels" alone still matches
// unrelated two-button prompts (e.g. "Settings" / "OK"). Both label lists are localizable via
// the request arguments. Anything else - including two-button alerts whose second button is
// unrecognized - is left alone; misfiring on an unrelated system dialog would silently
// acknowledge it, which is worse than letting the dance time out.
- (nullable XCUIElement *)matchingDismissButtonForAlertWithDismissLabels:(NSArray<NSString *> *)dismissLabels
                                                    goToApplicationLabels:(NSArray<NSString *> *)goToAppLabels;
// Dismisses the alert matched by matchingDismissButtonForAlertWithDismissLabels:goToApplicationLabels:
// above: applies the re-attempt cooldown, verifies the button's frame, and dispatches the tap.
- (BOOL)dismissBroadcastStoppedAlertWithLabels:(NSArray<NSString *> *)labels
                         goToApplicationLabels:(NSArray<NSString *> *)goToApplicationLabels;
// Clears the "Screen Broadcasting" alert end to end: waits up to appearanceGraceSec for it to
// appear at all, then keeps re-dispatching the dismissal tap until the alert is observed gone,
// bounded overall by appearanceGraceSec plus ALERT_DISMISSAL_BUDGET_SEC. Pass 0 for
// appearanceGraceSec to only act on an alert that is already on screen (a single existence
// probe when there is none). Returns YES when an alert was seen during the sweep - regardless
// of whether dismissing it succeeded. logContext prefixes the log lines, e.g. "broadcast/stop".
- (BOOL)sweepBroadcastStoppedAlertWithDismissLabels:(NSArray<NSString *> *)dismissLabels
                              goToApplicationLabels:(NSArray<NSString *> *)goToAppLabels
                                 appearanceGraceSec:(NSTimeInterval)appearanceGraceSec
                                         logContext:(NSString *)logContext;
#endif

@end

@implementation FBBroadcastManager

+ (instancetype)sharedInstance
{
  static FBBroadcastManager *instance;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[self alloc] init];
  });
  return instance;
}

- (BOOL)isExtensionConnected
{
  return self.controlServer.isExtensionConnected;
}

#pragma mark - Control server lifecycle

- (void)startListening
{
  if (nil != self.controlServer) {
    return;
  }
  uint16_t port = (uint16_t)FBConfiguration.broadcastControlPort;
  FBBroadcastControlServer *server = [[FBBroadcastControlServer alloc] initWithPort:port];
  server.delegate = self;
  NSError *error;
  if (![server startWithError:&error]) {
    [FBLogger logFmt:@"Cannot start the broadcast control server on port %d: %@", port, error.description];
    return;
  }
  self.controlServer = server;
}

- (void)stopListening
{
  [self.controlServer stop];
  self.controlServer = nil;
  [self resetConnectionState];
}

- (void)resetConnectionState
{
  self.helloInfo = nil;
  self.lastHeartbeat = nil;
  self.connectedAt = nil;
  self.lastHeartbeatAt = nil;
  self.paused = NO;
}

#pragma mark - Status

- (NSDictionary *)statusDictionary
{
  NSString *state = @"idle";
  if (self.isExtensionConnected) {
    state = self.paused ? @"paused" : @"connected";
  }
  NSDictionary *heartbeat = self.lastHeartbeat;
  return @{
    @"state": state,
    @"controlPort": @(FBConfiguration.broadcastControlPort),
    @"preferredExtension": FBConfiguration.broadcastExtensionBundleId,
    @"connectedAt": self.connectedAt ? @((uint64_t)(self.connectedAt.timeIntervalSince1970 * 1000)) : NSNull.null,
    @"lastHeartbeatAt": self.lastHeartbeatAt ? @((uint64_t)(self.lastHeartbeatAt.timeIntervalSince1970 * 1000)) : NSNull.null,
    @"hello": self.helloInfo ?: NSNull.null,
    @"heartbeat": heartbeat ?: NSNull.null,
    @"sessions": [FBVideoStreamManager.sharedInstance activeSessionsInfo],
    @"audioSessions": [FBAudioStreamManager.sharedInstance activeSessionsInfo],
  };
}

#pragma mark - Broadcast start/stop

- (BOOL)startBroadcastWithTimeout:(NSTimeInterval)timeout
              confirmButtonLabels:(NSArray<NSString *> *)confirmButtonLabels
              dismissButtonLabels:(NSArray<NSString *> *)dismissButtonLabels
      goToApplicationButtonLabels:(NSArray<NSString *> *)goToApplicationButtonLabels
             restoreForegroundApp:(BOOL)restoreForegroundApp
                            error:(NSError **)error
{
#if TARGET_OS_SIMULATOR || TARGET_OS_TV
  if (error) {
    *error = [NSError errorWithDomain:FBBroadcastManagerErrorDomain
                                 code:FBBroadcastManagerErrorUnsupported
                             userInfo:@{NSLocalizedDescriptionKey: @"ReplayKit broadcasts are only supported on physical iOS devices"}];
  }
  return NO;
#else
  if (self.isExtensionConnected) {
    return YES;
  }
  if (nil == self.controlServer) {
    [self startListening];
  }

  // Serialize concurrent starts: the dance below spins the main run loop, so another
  // /broadcast/start request can be dispatched re-entrantly while the first one is still driving
  // the system UI. Starting a second broadcast while one is launching makes iOS kill both, so
  // followers just await the leader's outcome.
  if (self.startInProgress) {
    [FBLogger log:@"broadcast/start: another start attempt is already in progress; awaiting its outcome"];
    [[[[FBRunLoopSpinner new] timeout:(timeout > 0 ? timeout : 30.0)] interval:0.3] spinUntilTrue:^BOOL{
      return self.isExtensionConnected || !self.startInProgress;
    }];
    if (self.isExtensionConnected) {
      return YES;
    }
    if (error) {
      *error = [NSError errorWithDomain:FBBroadcastManagerErrorDomain
                                   code:FBBroadcastManagerErrorTimeout
                               userInfo:@{NSLocalizedDescriptionKey: @"A concurrent broadcast start attempt finished without the extension connecting"}];
    }
    return NO;
  }

  self.startInProgress = YES;
  @try {
    return [self performBroadcastStartWithTimeout:timeout
                              confirmButtonLabels:confirmButtonLabels
                              dismissButtonLabels:dismissButtonLabels
                      goToApplicationButtonLabels:goToApplicationButtonLabels
                             restoreForegroundApp:restoreForegroundApp
                                            error:error];
  } @finally {
    self.startInProgress = NO;
  }
#endif
}

#if !TARGET_OS_SIMULATOR && !TARGET_OS_TV
- (BOOL)performBroadcastStartWithTimeout:(NSTimeInterval)timeout
                     confirmButtonLabels:(NSArray<NSString *> *)confirmButtonLabels
                     dismissButtonLabels:(NSArray<NSString *> *)dismissButtonLabels
             goToApplicationButtonLabels:(NSArray<NSString *> *)goToApplicationButtonLabels
                    restoreForegroundApp:(BOOL)restoreForegroundApp
                                   error:(NSError **)error
{
  NSArray<NSString *> *dismissLabels = dismissButtonLabels.count > 0 ? dismissButtonLabels : @[@"OK"];
  NSArray<NSString *> *goToAppLabels = goToApplicationButtonLabels.count > 0 ? goToApplicationButtonLabels : @[@"Go to Application"];

  // The screen may already be captured by a live broadcast even though the extension is not
  // connected (it crashed, or it is between TCP reconnect attempts). Driving the picker on top
  // of a live broadcast makes iOS kill both, so wait for the extension instead.
  if (UIScreen.mainScreen.isCaptured) {
    [FBLogger log:@"broadcast/start: the screen is already being captured; waiting for the extension to connect instead of starting another broadcast"];
    [[[[FBRunLoopSpinner new] timeout:5.0] interval:0.2] spinUntilTrue:^BOOL{
      if (self.isExtensionConnected || !UIScreen.mainScreen.isCaptured) {
        return YES;
      }
      // A stale "Screen Broadcasting" alert left over from a previous broadcast's end can be
      // the very thing pinning isCaptured; clear it so the flag can drop.
      if ([self dismissBroadcastStoppedAlertWithLabels:dismissLabels goToApplicationLabels:goToAppLabels]) {
        [FBLogger log:@"broadcast/start: dispatched a dismissal tap for the stale Screen Broadcasting alert while waiting out the active capture"];
      }
      return NO;
    }];
    if (self.isExtensionConnected) {
      return YES;
    }
    if (UIScreen.mainScreen.isCaptured) {
      if (error) {
        *error = [NSError errorWithDomain:FBBroadcastManagerErrorDomain
                                     code:FBBroadcastManagerErrorTimeout
                                 userInfo:@{NSLocalizedDescriptionKey: @"The screen is already being captured (an active broadcast or recording), but the WebDriverAgent broadcast extension did not connect. Stop the existing capture (e.g. via the status bar pill) and retry"}];
      }
      return NO;
    }
    // The capture ended while waiting; fall through and start a fresh broadcast.
  }

  uint64_t startedMs = FBBroadcastNowMs();
  XCUIApplication *runner = [[XCUIApplication alloc] initWithBundleIdentifier:(NSString *)NSBundle.mainBundle.bundleIdentifier];
  XCUIApplication *previousApp = nil;
  BOOL runnerIsActive = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
  // When the runner is already frontmost there is neither an app to restore nor a need for the
  // (slow) active-app lookup.
  if (restoreForegroundApp && !runnerIsActive) {
    XCUIApplication *active = XCUIApplication.fb_activeApplication;
    if (nil != active && ![active.bundleID isEqualToString:runner.bundleID]) {
      previousApp = active;
    }
    [FBLogger logFmt:@"broadcast/start: active-app lookup finished after %llums", FBBroadcastNowMs() - startedMs];
  }

  // The picker can only present from a foreground app, so bring the runner up first. The
  // LaunchServices route is used instead of XCUIApplication.activate because activating the
  // runner from inside itself blocks on a self-quiescence wait that can only ever time out:
  // the waiting thread is the very main thread whose idleness is being awaited.
  if (!runnerIsActive) {
    // A stale "Screen Broadcasting" alert blocks LaunchServices and XCTest foregrounding alike,
    // so it must be cleared before the attempts, not discovered after they both time out. With
    // no alert on screen this costs a single existence probe.
    [self sweepBroadcastStoppedAlertWithDismissLabels:dismissLabels
                                goToApplicationLabels:goToAppLabels
                                   appearanceGraceSec:0
                                           logContext:@"broadcast/start"];
    BOOL launched = [FBUnattachedAppLauncher launchAppWithBundleId:(NSString *)NSBundle.mainBundle.bundleIdentifier];
    BOOL foregrounded = launched && [[[[FBRunLoopSpinner new] timeout:2.0] interval:0.05] spinUntilTrue:^BOOL{
      return UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    }];
    if (!foregrounded) {
      // Reliable but slow fallback: XCTest's activation waits out its quiescence timeout.
      [FBLogger log:@"broadcast/start: LaunchServices foregrounding failed; falling back to XCUIApplication.activate"];
      [runner activate];
      foregrounded = [[[[FBRunLoopSpinner new] timeout:FOREGROUND_TIMEOUT] interval:0.05] spinUntilTrue:^BOOL{
        return UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
      }];
    }
    if (!foregrounded) {
      // The delayed "Screen Broadcasting" alert of a recently ended broadcast can also land
      // right in the middle of the dance and swallow the activation. When that - and only
      // that - is what happened, clearing the alert and re-activating recovers the start.
      BOOL alertWasBlocking = [self sweepBroadcastStoppedAlertWithDismissLabels:dismissLabels
                                                          goToApplicationLabels:goToAppLabels
                                                             appearanceGraceSec:0
                                                                     logContext:@"broadcast/start"];
      if (alertWasBlocking) {
        [FBLogger log:@"broadcast/start: retrying the activation now that the Screen Broadcasting alert is cleared"];
        [runner activate];
        foregrounded = [[[[FBRunLoopSpinner new] timeout:FOREGROUND_TIMEOUT] interval:0.05] spinUntilTrue:^BOOL{
          return UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
        }];
      }
    }
    if (!foregrounded) {
      if (error) {
        *error = [NSError errorWithDomain:FBBroadcastManagerErrorDomain
                                     code:FBBroadcastManagerErrorTimeout
                                 userInfo:@{NSLocalizedDescriptionKey: @"The runner app could not be brought to the foreground to present the broadcast picker"}];
      }
      return NO;
    }
  }
  [FBLogger logFmt:@"broadcast/start: runner foreground after %llums", FBBroadcastNowMs() - startedMs];

  NSError *pickerError;
  if (![FBBroadcastPickerHost triggerPickerWithPreferredExtension:FBConfiguration.broadcastExtensionBundleId
                                                            error:&pickerError]) {
    if (error) {
      *error = [NSError errorWithDomain:FBBroadcastManagerErrorDomain
                                   code:FBBroadcastManagerErrorPicker
                               userInfo:@{NSLocalizedDescriptionKey: pickerError.localizedDescription ?: @"Cannot trigger the broadcast picker"}];
    }
    return NO;
  }
  [FBLogger logFmt:@"broadcast/start: picker triggered after %llums", FBBroadcastNowMs() - startedMs];

  // The confirmation sheet is hosted by different processes depending on the iOS version, so
  // look for the confirm button in both the system app and the runner itself.
  NSArray<NSString *> *labels = confirmButtonLabels.count > 0 ? confirmButtonLabels : @[@"Start Broadcast"];
  NSArray<XCUIApplication *> *candidateApps = @[XCUIApplication.fb_systemApplication, runner];
  __block BOOL confirmButtonFound = NO;
  __block CGRect confirmFrame = CGRectZero;
  __block uint64_t lastTriggerMs = FBBroadcastNowMs();
  [[[[FBRunLoopSpinner new] timeout:CONFIRM_BUTTON_TIMEOUT] interval:0.25] spinUntilTrue:^BOOL{
    if ([self dismissBroadcastStoppedAlertWithLabels:dismissLabels goToApplicationLabels:goToAppLabels]) {
      [FBLogger logFmt:@"broadcast/start: dispatched a dismissal tap for the stale Screen Broadcasting alert after %llums", FBBroadcastNowMs() - startedMs];
      return NO;
    }
    for (XCUIApplication *app in candidateApps) {
      for (NSString *label in labels) {
        XCUIElement *candidate = app.buttons[label];
        if (candidate.exists) {
          confirmFrame = candidate.frame;
          confirmButtonFound = YES;
          return YES;
        }
      }
      XCUIElement *prefixMatch = [app.buttons matchingPredicate:[NSPredicate predicateWithFormat:@"label BEGINSWITH[c] 'Start'"]].firstMatch;
      if (prefixMatch.exists) {
        confirmFrame = prefixMatch.frame;
        confirmButtonFound = YES;
        return YES;
      }
    }
    if (FBBroadcastNowMs() - lastTriggerMs >= PICKER_RETRIGGER_INTERVAL_MS) {
      lastTriggerMs = FBBroadcastNowMs();
      [FBLogger log:@"broadcast/start: confirmation sheet not visible yet; re-triggering the picker"];
      [FBBroadcastPickerHost triggerPickerWithPreferredExtension:FBConfiguration.broadcastExtensionBundleId
                                                           error:nil];
    }
    return NO;
  }];
  if (!confirmButtonFound || CGRectIsEmpty(confirmFrame)) {
    [FBBroadcastPickerHost dismiss];
    if (error) {
      *error = [NSError errorWithDomain:FBBroadcastManagerErrorDomain
                                   code:FBBroadcastManagerErrorTimeout
                               userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"The broadcast confirmation sheet did not show a button labeled %@ within %.0fs. Pass 'confirmButtonLabels' if the device language is not English", [labels componentsJoinedByString:@"/"], CONFIRM_BUTTON_TIMEOUT]}];
    }
    return NO;
  }
  // A missed tap here is harmless (surfaces as a connect timeout below); see
  // FBBroadcastTapFrameCenter for why this goes through WDA's own event synthesis.
  NSError *tapError;
  if (!FBBroadcastTapFrameCenter(runner, confirmFrame, YES, &tapError)) {
    [FBBroadcastPickerHost dismiss];
    if (error) {
      *error = [NSError errorWithDomain:FBBroadcastManagerErrorDomain
                                   code:FBBroadcastManagerErrorPicker
                               userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Cannot tap the broadcast confirmation button: %@", tapError.localizedDescription]}];
    }
    return NO;
  }
  [FBLogger logFmt:@"broadcast/start: confirmation tapped after %llums", FBBroadcastNowMs() - startedMs];

  // Cover the system's 3-2-1 countdown plus the extension's connect/HELLO round trip.
  BOOL connected = [[[[FBRunLoopSpinner new] timeout:(timeout > 0 ? timeout : 30.0)] interval:0.3] spinUntilTrue:^BOOL{
    return self.isExtensionConnected;
  }];
  [FBLogger logFmt:@"broadcast/start: %@ after %llums", connected ? @"extension connected" : @"extension connect timeout", FBBroadcastNowMs() - startedMs];
  [FBBroadcastPickerHost dismiss];
  if (!connected) {
    if (error) {
      *error = [NSError errorWithDomain:FBBroadcastManagerErrorDomain
                                   code:FBBroadcastManagerErrorTimeout
                               userInfo:@{NSLocalizedDescriptionKey: @"The broadcast was confirmed but the extension did not connect in time. Check that the extension is embedded and signed correctly (see docs/broadcast-extension.md)"}];
    }
    return NO;
  }

  if (nil != previousApp) {
    [previousApp activate];
  }
  return YES;
}

// Finds, but does not tap, the dismiss button of the system's stale "Screen Broadcasting" alert
// (posted by SpringBoard whenever a broadcast ends) when one is on screen. The alert is matched
// structurally, not by its (localized) title: exactly two buttons, of which exactly one matches
// dismissLabels and the OTHER matches goToAppLabels - the second button anchors the alert's
// identity, since "exactly one of two buttons matches the dismiss labels" alone still matches
// unrelated two-button prompts (e.g. "Settings" / "OK"). Both label lists are localizable via
// the request arguments. Anything else - including two-button alerts whose second button is
// unrecognized - is left alone; misfiring on an unrelated system dialog would silently
// acknowledge it, which is worse than letting the dance time out.
- (nullable XCUIElement *)matchingDismissButtonForAlertWithDismissLabels:(NSArray<NSString *> *)dismissLabels
                                                    goToApplicationLabels:(NSArray<NSString *> *)goToAppLabels
{
  XCUIApplication *systemApp = XCUIApplication.fb_systemApplication;
  XCUIElement *alert = systemApp.alerts.firstMatch;
  if (!alert.exists) {
    return nil;
  }
  NSArray<XCUIElement *> *buttons = [alert.buttons allElementsBoundByIndex];
  if (buttons.count != 2) {
    return nil;
  }
  XCUIElement *dismissButton = nil;
  XCUIElement *otherButton = nil;
  for (XCUIElement *button in buttons) {
    if ([dismissLabels containsObject:button.label]) {
      if (nil != dismissButton) {
        // Both buttons match the dismiss labels - ambiguous, not the alert we expect.
        return nil;
      }
      dismissButton = button;
    } else {
      otherButton = button;
    }
  }
  if (nil == dismissButton || nil == otherButton) {
    return nil;
  }
  if (![goToAppLabels containsObject:otherButton.label]) {
    // The other button is not the expected "Go to Application" anchor - some other two-button
    // system prompt, not the Screen Broadcasting alert.
    return nil;
  }
  return dismissButton;
}

// Dismisses the alert matched by matchingDismissButtonForAlertWithDismissLabels:goToApplicationLabels:
// above: applies the re-attempt cooldown, verifies the button's frame, and dispatches the tap.
- (BOOL)dismissBroadcastStoppedAlertWithLabels:(NSArray<NSString *> *)labels
                         goToApplicationLabels:(NSArray<NSString *> *)goToApplicationLabels
{
  XCUIElement *dismissButton = [self matchingDismissButtonForAlertWithDismissLabels:labels
                                                                goToApplicationLabels:goToApplicationLabels];
  if (nil == dismissButton) {
    return NO;
  }
  // The dismissal tap is fire-and-forget (see FBBroadcastTapFrameCenter), so without a cooldown
  // the next 0.25s spin iteration could re-tap the same coordinates while the alert's dismissal
  // animation is still running, landing the extra tap on the UI underneath.
  if (FBBroadcastNowMs() - self.lastAlertDismissalAttemptMs < 1000) {
    return NO;
  }
  CGRect frame = dismissButton.frame;
  if (CGRectIsEmpty(frame)) {
    return NO;
  }
  // The frame is in SpringBoard's coordinate space, and the synthesized event record is stamped
  // with the RECEIVER's interface orientation - so the tap must be synthesized via the system
  // app, not the (possibly backgrounded, orientation-stale) runner.
  self.lastAlertDismissalAttemptMs = FBBroadcastNowMs();
  return FBBroadcastTapFrameCenter(XCUIApplication.fb_systemApplication, frame, NO, nil);
}

// Survives both known failure modes: exiting once a dismissal tap is merely dispatched
// (FBBroadcastTapFrameCenter's waitForAck:NO tap is fire-and-forget and can be shed by the
// system, so the sweep must keep spinning on the matcher's OBSERVED state, not on the dispatch
// call succeeding), and exiting before the alert - which SpringBoard publishes with a delay
// AFTER the extension socket closes - has appeared at all. So: once the alert has been seen,
// declare success only when it is next observed gone (retrying the dismissal tap in between,
// paced by the 1s cooldown inside dismissBroadcastStoppedAlertWithLabels:goToApplicationLabels:);
// until it has been seen, keep waiting out the appearance grace period rather than exiting on
// the first (empty) read.
- (BOOL)sweepBroadcastStoppedAlertWithDismissLabels:(NSArray<NSString *> *)dismissLabels
                              goToApplicationLabels:(NSArray<NSString *> *)goToAppLabels
                                 appearanceGraceSec:(NSTimeInterval)appearanceGraceSec
                                         logContext:(NSString *)logContext
{
  uint64_t sweepStartedMs = FBBroadcastNowMs();
  __block BOOL alertSeen = NO;
  [[[[FBRunLoopSpinner new] timeout:(appearanceGraceSec + ALERT_DISMISSAL_BUDGET_SEC)] interval:0.25] spinUntilTrue:^BOOL{
    XCUIElement *dismissButton = [self matchingDismissButtonForAlertWithDismissLabels:dismissLabels goToApplicationLabels:goToAppLabels];
    if (nil != dismissButton) {
      if (!alertSeen) {
        alertSeen = YES;
        [FBLogger logFmt:@"%@: the Screen Broadcasting alert appeared %llums into the sweep", logContext, FBBroadcastNowMs() - sweepStartedMs];
      }
      if ([self dismissBroadcastStoppedAlertWithLabels:dismissLabels goToApplicationLabels:goToAppLabels]) {
        [FBLogger logFmt:@"%@: dispatched a dismissal tap for the Screen Broadcasting alert", logContext];
      }
      return NO;
    }
    if (alertSeen) {
      return YES;
    }
    return (FBBroadcastNowMs() - sweepStartedMs) >= (uint64_t)(appearanceGraceSec * 1000);
  }];
  return alertSeen;
}
#endif

- (BOOL)stopBroadcastWithError:(NSError **)error
{
  return [self stopBroadcastWithDismissButtonLabels:nil goToApplicationButtonLabels:nil error:error];
}

- (BOOL)stopBroadcastWithDismissButtonLabels:(NSArray<NSString *> *)dismissButtonLabels
                 goToApplicationButtonLabels:(NSArray<NSString *> *)goToApplicationButtonLabels
                                        error:(NSError **)error
{
#if !TARGET_OS_SIMULATOR && !TARGET_OS_TV
  NSArray<NSString *> *dismissLabels = dismissButtonLabels.count > 0 ? dismissButtonLabels : @[@"OK"];
  NSArray<NSString *> *goToAppLabels = goToApplicationButtonLabels.count > 0 ? goToApplicationButtonLabels : @[@"Go to Application"];
#endif
  if (!self.isExtensionConnected) {
#if !TARGET_OS_SIMULATOR && !TARGET_OS_TV
    // Nothing to stop, but a previous broadcast that ended without a stop call (a crash, or the
    // runner being relaunched) can have left its alert on screen; clear it when it is there
    // right now. Grace 0 keeps the idempotent-stop case a single existence probe.
    [self sweepBroadcastStoppedAlertWithDismissLabels:dismissLabels
                                goToApplicationLabels:goToAppLabels
                                   appearanceGraceSec:0
                                           logContext:@"broadcast/stop"];
#endif
    return YES;
  }
  [self.controlServer sendStopBroadcast];
  BOOL stopped = [[[[FBRunLoopSpinner new] timeout:STOP_TIMEOUT] interval:0.2] spinUntilTrue:^BOOL{
    return !self.isExtensionConnected;
  }];
  if (!stopped) {
    if (error) {
      *error = [NSError errorWithDomain:FBBroadcastManagerErrorDomain
                                   code:FBBroadcastManagerErrorTimeout
                               userInfo:@{NSLocalizedDescriptionKey: @"The broadcast extension did not finish the broadcast in time"}];
    }
    return NO;
  }
#if !TARGET_OS_SIMULATOR && !TARGET_OS_TV
  // Best-effort: a broadcast stop almost always leaves the stale "Screen Broadcasting" alert
  // behind, so proactively clear it here instead of waiting for the next start dance to hit it.
  // Not gated by iOS version: the delayed alert has been observed on iOS 18 (~10s, up to ~12s
  // after the stop) and iOS 26 (~5s) alike. This never affects the return value below.
  [self sweepBroadcastStoppedAlertWithDismissLabels:dismissLabels
                              goToApplicationLabels:goToAppLabels
                                 appearanceGraceSec:ALERT_APPEARANCE_GRACE_SEC
                                         logContext:@"broadcast/stop"];
#endif
  return YES;
}

#pragma mark - Session bridging

+ (NSDictionary *)sessionAddPayloadForConfiguration:(FBScreenCaptureConfiguration *)configuration
{
  return @{
    FBBroadcastKeyWidth: @(configuration.width),
    FBBroadcastKeyHeight: @(configuration.height),
    FBBroadcastKeyCodec: configuration.codec == FBVideoCodecH265 ? FBBroadcastCodecH265 : FBBroadcastCodecH264,
    FBBroadcastKeyBitrate: @(configuration.bitrate),
    FBBroadcastKeyFps: @(configuration.fps),
  };
}

- (void)notifySessionAdded:(FBVideoStreamSession *)session
{
  if (!self.isExtensionConnected) {
    return;
  }
  [self.controlServer sendSessionAdd:(uint32_t)session.identifier
                       configuration:[self.class sessionAddPayloadForConfiguration:session.configuration]];
}

- (void)notifySessionRemoved:(NSUInteger)identifier
{
  if (!self.isExtensionConnected) {
    return;
  }
  [self.controlServer sendSessionRemove:(uint32_t)identifier];
}

+ (NSDictionary *)sessionAddPayloadForAudioConfiguration:(FBAudioCaptureConfiguration *)configuration
{
  return @{
    FBBroadcastKeyMedia: FBBroadcastMediaAudio,
    FBBroadcastKeyCodec: FBBroadcastCodecOpus,
    FBBroadcastKeyBitrate: @(configuration.bitrate),
    FBBroadcastKeyChannels: @(configuration.channels),
    FBBroadcastKeySampleRate: @48000,
  };
}

- (void)notifyAudioSessionAdded:(FBAudioStreamSession *)session
{
  if (!self.isExtensionConnected) {
    return;
  }
  [self.controlServer sendSessionAdd:(uint32_t)session.identifier | FBBroadcastAudioSessionIdFlag
                       configuration:[self.class sessionAddPayloadForAudioConfiguration:session.configuration]];
}

- (void)notifyAudioSessionRemoved:(NSUInteger)identifier
{
  if (!self.isExtensionConnected) {
    return;
  }
  [self.controlServer sendSessionRemove:(uint32_t)identifier | FBBroadcastAudioSessionIdFlag];
}

- (void)requestKeyFrameForSession:(NSUInteger)identifier
{
  [self.controlServer sendKeyframeRequest:(uint32_t)identifier];
}

#pragma mark - <FBBroadcastControlServerDelegate>

- (void)broadcastServerDidConnect:(NSDictionary<NSString *, id> *)helloInfo
{
  [FBLogger logFmt:@"The broadcast extension connected: %@", helloInfo];
  self.helloInfo = helloInfo;
  self.connectedAt = NSDate.date;
  self.paused = NO;
  // Attach every live capture session to the broadcast source.
  for (FBVideoStreamSession *session in [FBVideoStreamManager.sharedInstance activeSessions]) {
    [self.controlServer sendSessionAdd:(uint32_t)session.identifier
                         configuration:[self.class sessionAddPayloadForConfiguration:session.configuration]];
  }
  for (FBAudioStreamSession *audioSession in [FBAudioStreamManager.sharedInstance activeSessions]) {
    [self.controlServer sendSessionAdd:(uint32_t)audioSession.identifier | FBBroadcastAudioSessionIdFlag
                         configuration:[self.class sessionAddPayloadForAudioConfiguration:audioSession.configuration]];
  }
}

- (void)broadcastServerDidReceiveHeartbeat:(NSDictionary<NSString *, id> *)heartbeat
{
  self.lastHeartbeat = heartbeat;
  self.lastHeartbeatAt = NSDate.date;
  self.paused = [@"paused" isEqualToString:(NSString *)(heartbeat[FBBroadcastKeyState] ?: @"")];
}

- (void)broadcastServerDidReceiveStatus:(NSDictionary<NSString *, id> *)status
{
  NSString *event = status[FBBroadcastKeyEvent];
  [FBLogger logFmt:@"Broadcast status event: %@", status];
  if ([@"paused" isEqualToString:event]) {
    self.paused = YES;
  } else if ([@"resumed" isEqualToString:event]) {
    self.paused = NO;
  }
}

- (void)broadcastServerDidReceiveSessionError:(NSString *)message forSession:(uint32_t)sessionId
{
  [FBLogger logFmt:@"The broadcast extension cannot serve session %u: %@", sessionId, message];
  if (sessionId & FBBroadcastAudioSessionIdFlag) {
    NSUInteger identifier = sessionId & ~FBBroadcastAudioSessionIdFlag;
    [[FBAudioStreamManager.sharedInstance sessionWithIdentifier:identifier] markBroadcastError:message];
    return;
  }
  FBVideoStreamSession *session = [FBVideoStreamManager.sharedInstance sessionWithIdentifier:sessionId];
  [session detachBroadcastSourceAndForceKeyFrame];
}

- (void)broadcastServerDidReceiveParameterSets:(NSData *)parameterSets forSession:(uint32_t)sessionId
{
  FBVideoStreamSession *session = [FBVideoStreamManager.sharedInstance sessionWithIdentifier:sessionId];
  if (nil == session) {
    [self.controlServer sendSessionRemove:sessionId];
    return;
  }
  [session ingestBroadcastParameterSets:parameterSets];
}

- (void)broadcastServerDidReceiveFrame:(NSData *)annexBPictureData
                            isKeyFrame:(BOOL)isKeyFrame
                                 ptsUs:(uint64_t)ptsUs
                           orientation:(uint8_t)orientation
                            forSession:(uint32_t)sessionId
{
  FBVideoStreamSession *session = [FBVideoStreamManager.sharedInstance sessionWithIdentifier:sessionId];
  if (nil == session) {
    // The session is gone (stale extension pipeline); ask the extension to drop it.
    [self.controlServer sendSessionRemove:sessionId];
    return;
  }
  [session ingestBroadcastFrame:annexBPictureData isKeyFrame:isKeyFrame];
}

- (void)broadcastServerDidReceiveAudioParams:(NSData *)opusHead forSession:(uint32_t)sessionId
{
  NSUInteger identifier = sessionId & ~FBBroadcastAudioSessionIdFlag;
  FBAudioStreamSession *session = [FBAudioStreamManager.sharedInstance sessionWithIdentifier:identifier];
  if (nil == session) {
    [self.controlServer sendSessionRemove:sessionId];
    return;
  }
  [session ingestBroadcastOpusHead:opusHead];
}

- (void)broadcastServerDidReceiveAudioPacket:(NSData *)opusPacket
                                       ptsUs:(uint64_t)ptsUs
                                  forSession:(uint32_t)sessionId
{
  NSUInteger identifier = sessionId & ~FBBroadcastAudioSessionIdFlag;
  FBAudioStreamSession *session = [FBAudioStreamManager.sharedInstance sessionWithIdentifier:identifier];
  if (nil == session) {
    // The session is gone (stale extension pipeline); ask the extension to drop it.
    [self.controlServer sendSessionRemove:sessionId];
    return;
  }
  [session ingestBroadcastPacket:opusPacket ptsUs:ptsUs];
}

- (void)broadcastServerDidDisconnect
{
  [FBLogger log:@"The broadcast extension disconnected; reverting sessions to the screenshot source"];
  [self resetConnectionState];
  for (FBVideoStreamSession *session in [FBVideoStreamManager.sharedInstance activeSessions]) {
    [session detachBroadcastSourceAndForceKeyFrame];
  }
  // Audio has no fallback source; the sessions stay alive and simply pause.
  for (FBAudioStreamSession *audioSession in [FBAudioStreamManager.sharedInstance activeSessions]) {
    [audioSession detachBroadcastSource];
  }
}

@end
