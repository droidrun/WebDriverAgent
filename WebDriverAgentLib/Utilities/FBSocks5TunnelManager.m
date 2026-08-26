/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBSocks5TunnelManager.h"

#import "FBSocks5TunnelProtocol.h"
#import "FBSocks5URI.h"

NSErrorDomain const FBSocks5TunnelManagerErrorDomain = @"com.facebook.WebDriverAgent.FBSocks5TunnelManager";

static BOOL FBSocks5Fail(NSError **error, FBSocks5TunnelManagerError code, NSString *message)
{
  if (nil != error) {
    *error = [NSError errorWithDomain:FBSocks5TunnelManagerErrorDomain
                                 code:code
                             userInfo:@{NSLocalizedDescriptionKey: message}];
  }
  return NO;
}

static NSMutableDictionary<NSString *, id> *FBSocks5DisconnectedStats(void)
{
  return [@{
    FBSocks5StatsKeyConnected: @NO,
    FBSocks5StatsKeyRxBytes: @0,
    FBSocks5StatsKeyTxBytes: @0,
    FBSocks5StatsKeyRxPackets: @0,
    FBSocks5StatsKeyTxPackets: @0,
  } mutableCopy];
}

#if TARGET_OS_SIMULATOR || TARGET_OS_TV

@implementation FBSocks5TunnelManager

+ (instancetype)sharedInstance
{
  static FBSocks5TunnelManager *instance;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[FBSocks5TunnelManager alloc] init];
  });
  return instance;
}

- (BOOL)connectWithURI:(FBSocks5URI *)uri
               timeout:(NSTimeInterval)timeout
   consentButtonLabels:(nullable NSArray<NSString *> *)consentButtonLabels
                 error:(NSError **)error
{
  return FBSocks5Fail(error, FBSocks5TunnelManagerErrorUnsupported,
                      @"SOCKS5 tunnels require a NetworkExtension packet tunnel, which is not available on Simulator/tvOS");
}

- (BOOL)disconnectWithError:(NSError **)error
{
  return FBSocks5Fail(error, FBSocks5TunnelManagerErrorUnsupported,
                      @"SOCKS5 tunnels require a NetworkExtension packet tunnel, which is not available on Simulator/tvOS");
}

- (NSDictionary<NSString *, id> *)statsDictionary
{
  return FBSocks5DisconnectedStats().copy;
}

@end

#else

#import <NetworkExtension/NetworkExtension.h>

#import "FBLogger.h"
#import "FBRunLoopSpinner.h"
#import "FBScreen.h"
#import "FBWebServer.h"
#import "FBXCTestDaemonsProxy.h"
#import "XCUIApplication.h"
#import "XCUIApplication+FBHelpers.h"
#import "XCUIApplication+FBTouchAction.h"
#import "XCUIElement.h"

// The embed script rewrites the extension bundle id to '<runner bundle id>.tunnel'
// (see Scripts/embed-tunnel-extension.sh), so derive it the same way at runtime.
static NSString *const FBSocks5TunnelBundleSuffix = @".tunnel";
static NSString *const FBSocks5TunnelDescription = @"mobilerun SOCKS5";
static const NSTimeInterval FBSocks5PreferencesTimeout = 10.0;
static const NSTimeInterval FBSocks5StopTimeout = 10.0;
static const NSTimeInterval FBSocks5StatsReplyTimeout = 3.0;
static const NSTimeInterval FBSocks5DefaultConnectTimeout = 30.0;
/** Minimum gap between two consent taps, so a re-attempt cannot land during the dismissal animation. */
static const uint64_t FBSocks5ConsentTapCooldownMs = 1000;

static uint64_t FBSocks5NowMs(void)
{
  return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / NSEC_PER_MSEC;
}

/// Queue-specific marker used to detect that the caller already holds the lifecycle queue.
static const void *FBSocks5LifecycleQueueKey = &FBSocks5LifecycleQueueKey;

/**
 How long an individual wait may block: whatever is left of the caller's whole-flow deadline,
 never more than that stage's own cap. `deadline` is nil for the flows that do not carry one
 (disconnect, stats), which then just get the cap. A non-positive result means the caller's
 budget is exhausted and the stage must not start at all.
 */
static NSTimeInterval FBSocks5RemainingTimeout(NSDate *_Nullable deadline, NSTimeInterval cap)
{
  return nil == deadline ? cap : MIN(cap, deadline.timeIntervalSinceNow);
}

@interface FBSocks5TunnelManager ()
@property (nonatomic, nullable) NETunnelProviderManager *activeManager;
/** Monotonic ms timestamp of the last consent tap dispatch; guards the re-attempt cooldown. */
@property (nonatomic) uint64_t lastConsentTapMs;
/**
 Signalled when a saveToPreferences that outlived its request finally completes.

 Returning from a timed-out save does not cancel it - NetworkExtension can still persist the
 manager afterwards. A follow-up operation that ran before that landed would load no manager,
 build a second one with the same provider id, and end up with two persisted configurations;
 ownManagerIn: could then hand a disconnected duplicate to disconnect, which would report
 success while the real tunnel kept running. Non-nil means such a save is still outstanding.
 */
@property (atomic, nullable) dispatch_semaphore_t pendingSaveSignal;
/**
 Serializes the whole tunnel lifecycle. The socks5 routes are marked onControlQueue, and
 FBWebServer only funnels the non-control ones, so requests arriving over different HTTP
 connections reach this singleton concurrently on their own connection queues. Without this
 queue a disconnect could return while an in-flight connect goes on to start the tunnel, and
 two connects could race different proxy configurations through stop/save/reload/start.
 */
@property (nonatomic, strong) dispatch_queue_t lifecycleQueue;
@end

@implementation FBSocks5TunnelManager

+ (instancetype)sharedInstance
{
  static FBSocks5TunnelManager *instance;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[FBSocks5TunnelManager alloc] init];
  });
  return instance;
}

- (instancetype)init
{
  self = [super init];
  if (nil != self) {
    _lifecycleQueue = dispatch_queue_create("com.facebook.WebDriverAgent.socks5-lifecycle",
                                            DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(_lifecycleQueue, FBSocks5LifecycleQueueKey,
                                (void *)FBSocks5LifecycleQueueKey, NULL);
  }
  return self;
}

/**
 Blocks until a save left in flight by a timed-out connect settles, so the next operation sees
 whatever it persisted instead of racing it. Safe to call from the lifecycle queue: the
 completion is delivered on the main queue, which this queue does not occupy.
 */
- (void)fencePendingSaveWithDeadline:(nullable NSDate *)deadline
{
  dispatch_semaphore_t signal = self.pendingSaveSignal;
  if (nil == signal) {
    return;
  }
  NSTimeInterval budget = FBSocks5RemainingTimeout(deadline, FBSocks5PreferencesTimeout);
  if (budget > 0) {
    [FBLogger log:@"socks5: waiting for a previously timed-out VPN save to settle"];
    dispatch_semaphore_wait(signal, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(budget * NSEC_PER_SEC)));
  }
  // Cleared either way: a save that outlives even this is not worth blocking every later call on.
  self.pendingSaveSignal = nil;
}

/// Runs `block` with the lifecycle queue held, tolerating a caller that already holds it.
- (void)performLocked:(NS_NOESCAPE dispatch_block_t)block
{
  if (NULL != dispatch_get_specific(FBSocks5LifecycleQueueKey)) {
    block();
    return;
  }
  dispatch_sync(self.lifecycleQueue, block);
}

#pragma mark - Helpers

- (NSString *)providerBundleIdentifier
{
  return [NSBundle.mainBundle.bundleIdentifier stringByAppendingString:FBSocks5TunnelBundleSuffix];
}

- (BOOL)loadAllManagers:(NSArray<NETunnelProviderManager *> **)outManagers
               deadline:(nullable NSDate *)deadline
                  error:(NSError **)error
{
  NSTimeInterval budget = FBSocks5RemainingTimeout(deadline, FBSocks5PreferencesTimeout);
  if (budget <= 0) {
    return FBSocks5Fail(error, FBSocks5TunnelManagerErrorTimeout,
                        @"Ran out of time before loading the VPN preferences");
  }
  __block NSArray<NETunnelProviderManager *> *managers = nil;
  __block NSError *loadError = nil;
  __block BOOL done = NO;
  [NETunnelProviderManager loadAllFromPreferencesWithCompletionHandler:^(NSArray<NETunnelProviderManager *> *all, NSError *err) {
    managers = all;
    loadError = err;
    done = YES;
  }];
  [[[[FBRunLoopSpinner new] timeout:budget] interval:0.05] spinUntilTrue:^BOOL{
    return done;
  }];
  if (!done || nil != loadError) {
    return FBSocks5Fail(error, FBSocks5TunnelManagerErrorInternal,
                        [NSString stringWithFormat:@"Cannot load the VPN preferences: %@",
                         loadError.localizedDescription ?: @"timed out"]);
  }
  if (nil != outManagers) {
    *outManagers = managers ?: @[];
  }
  return YES;
}

// Returns the manager for our own provider, preferring one that is not idle. Duplicates with the
// same provider id can exist transiently (see pendingSaveSignal); picking whichever came first
// would let a disconnected duplicate shadow the running tunnel, so disconnect would report
// success without stopping anything.
- (nullable NETunnelProviderManager *)ownManagerIn:(NSArray<NETunnelProviderManager *> *)managers
{
  NSString *providerId = self.providerBundleIdentifier;
  NETunnelProviderManager *idleMatch = nil;
  for (NETunnelProviderManager *manager in managers) {
    NETunnelProviderProtocol *protocol = (NETunnelProviderProtocol *)manager.protocolConfiguration;
    if (![protocol isKindOfClass:NETunnelProviderProtocol.class]
        || ![protocol.providerBundleIdentifier isEqualToString:providerId]) {
      continue;
    }
    NEVPNStatus status = manager.connection.status;
    if (status != NEVPNStatusDisconnected && status != NEVPNStatusInvalid) {
      return manager;
    }
    if (nil == idleMatch) {
      idleMatch = manager;
    }
  }
  return idleMatch;
}

- (BOOL)waitUntilStopped:(NETunnelProviderManager *)manager deadline:(nullable NSDate *)deadline
{
  NSTimeInterval budget = FBSocks5RemainingTimeout(deadline, FBSocks5StopTimeout);
  if (budget <= 0) {
    return NO;
  }
  return [[[[FBRunLoopSpinner new] timeout:budget] interval:0.2] spinUntilTrue:^BOOL{
    NEVPNStatus status = manager.connection.status;
    return status == NEVPNStatusDisconnected || status == NEVPNStatusInvalid;
  }];
}

// The first save of the configuration makes the system present a '"…" Would Like to Add VPN
// Configurations' alert that must be confirmed before the save completion fires, so this is
// polled from within the save wait loop. Devices with a passcode additionally ask for it,
// which cannot be automated (documented in docs/socks5-tunnel.md).
// XCUI is only safe to touch from the main thread, and the socks5 routes are served off it
// (they are marked onControlQueue so the main queue stays free to drain the NetworkExtension
// completion handlers this class waits on). Every XCUI access below therefore hops onto the
// automation funnel and then the main queue, which is the same path the main-queue-served
// routes - e.g. the broadcast start/stop pair, whose consent handling this mirrors - take.
//
// The tap itself follows FBBroadcastManager's dismissal tap in three respects, each of which
// this code previously got wrong and which together left the alert standing while the caller
// believed it had been confirmed:
//   1. It is synthesized via the SYSTEM app, not the runner. The frame is read out of
//      SpringBoard's coordinate space and the event record is stamped with the RECEIVER's
//      interface orientation, so synthesizing through the (backgrounded, orientation-stale)
//      runner can land the tap somewhere else entirely.
//   2. It is fire-and-forget. The blocking variant's acknowledgement can take the full
//      event-synthesis timeout margin when the system sheds the event, which cannot be
//      interrupted by the caller's much shorter spin deadline.
//   3. Its outcome is therefore observed via state (has the alert gone / did the save
//      complete?), never inferred from the dispatch succeeding - so the caller must keep
//      re-attempting, paced by the cooldown below, instead of latching after one dispatch.
//
// The button is matched inside the VPN alert rather than app-wide. An unscoped
// system.buttons[@"Allow"] query would happily select any other SpringBoard prompt that
// happens to be up when the save is requested - silently granting an unrelated permission -
// so the alert is located first and identified structurally, the way FBBroadcastManager
// anchors its own alert: exactly two buttons, one of them the consent label.
- (nullable XCUIElement *)consentAlertButtonWithLabel:(NSString *)label
{
  XCUIApplication *system = XCUIApplication.fb_systemApplication;
  for (XCUIElement *alert in system.alerts.allElementsBoundByIndex) {
    if (!alert.exists) {
      continue;
    }
    NSArray<XCUIElement *> *buttons = alert.buttons.allElementsBoundByIndex;
    // "Would Like to Add VPN Configurations" is Allow / Don't Allow. A different button count is
    // a different prompt, whatever its labels say.
    if (buttons.count != 2) {
      continue;
    }
    // Two buttons plus a common label is not an identity: other system permission prompts are
    // also Allow / Don't Allow, and granting one of those instead would hand out an unrelated
    // permission. Anchor on the alert's own text as well. "VPN" is an initialism Apple leaves
    // untranslated in this title across locales; if that ever stops holding, the alert simply is
    // not matched and connect fails on the save timeout, which is the safe direction to fail.
    NSString *identity = [NSString stringWithFormat:@"%@ %@", alert.identifier ?: @"", alert.label ?: @""];
    if ([identity rangeOfString:@"VPN" options:NSCaseInsensitiveSearch].location == NSNotFound) {
      continue;
    }
    for (XCUIElement *button in buttons) {
      if ([button.label isEqualToString:label] && button.exists) {
        return button;
      }
    }
  }
  return nil;
}

- (BOOL)tapConsentButtonWithLabels:(NSArray<NSString *> *)labels
{
  __block BOOL dispatched = NO;
  [FBWebServer performAutomationBlockOnMainQueue:^{
    XCUIApplication *system = XCUIApplication.fb_systemApplication;
    for (NSString *label in labels) {
      XCUIElement *button = [self consentAlertButtonWithLabel:label];
      if (nil == button) {
        continue;
      }
      CGRect frame = button.frame;
      if (CGRectIsEmpty(frame)) {
        continue;
      }
      // Without a cooldown the next spin iteration could re-tap the same coordinates while the
      // alert's dismissal animation is still running, landing the extra tap on the UI beneath.
      if (FBSocks5NowMs() - self.lastConsentTapMs < FBSocks5ConsentTapCooldownMs) {
        return;
      }
      CGFloat scale = (CGFloat)[FBScreen scale];
      CGPoint center = CGPointMake(CGRectGetMidX(frame) * scale, CGRectGetMidY(frame) * scale);
      NSArray *tapActions = @[
        @{@"type": @"pointerDown", @"x": @(center.x), @"y": @(center.y)},
        @{@"type": @"pause", @"duration": @60},
        @{@"type": @"pointerUp", @"x": @(center.x), @"y": @(center.y)},
      ];
      NSError *tapError;
      XCSynthesizedEventRecord *record = [system fb_mobilerunEventRecordFromActions:tapActions
                                                                              scale:scale
                                                                              error:&tapError];
      if (nil == record) {
        [FBLogger logFmt:@"socks5/connect: cannot build the tap for the VPN consent button '%@': %@",
         label, tapError.localizedDescription];
        return;
      }
      self.lastConsentTapMs = FBSocks5NowMs();
      [FBXCTestDaemonsProxy synthesizeEventAsyncWithRecord:record];
      [FBLogger logFmt:@"socks5/connect: dispatched a tap at the VPN consent button '%@'", label];
      dispatched = YES;
      return;
    }
  }];
  return dispatched;
}

#pragma mark - Public API

- (BOOL)connectWithURI:(FBSocks5URI *)uri
               timeout:(NSTimeInterval)timeout
   consentButtonLabels:(nullable NSArray<NSString *> *)consentButtonLabels
                 error:(NSError **)error
{
  __block BOOL succeeded = NO;
  __block NSError *localError = nil;
  [self performLocked:^{
    succeeded = [self lockedConnectWithURI:uri
                                   timeout:timeout
                       consentButtonLabels:consentButtonLabels
                                     error:&localError];
  }];
  if (!succeeded && nil != error) {
    *error = localError;
  }
  return succeeded;
}

- (BOOL)lockedConnectWithURI:(FBSocks5URI *)uri
                     timeout:(NSTimeInterval)timeout
         consentButtonLabels:(nullable NSArray<NSString *> *)consentButtonLabels
                       error:(NSError **)error
{
  NSTimeInterval budget = timeout > 0 ? timeout : FBSocks5DefaultConnectTimeout;
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:budget];
  NSArray<NSString *> *labels = consentButtonLabels.count > 0 ? consentButtonLabels : @[@"Allow"];

  [self fencePendingSaveWithDeadline:deadline];
  NSArray<NETunnelProviderManager *> *managers;
  if (![self loadAllManagers:&managers deadline:deadline error:error]) {
    return NO;
  }
  NETunnelProviderManager *manager = [self ownManagerIn:managers] ?: [[NETunnelProviderManager alloc] init];

  // Connecting while a tunnel runs replaces it. Disconnecting counts as in-flight too: an
  // immediate retry after a timed-out connect, or a connect racing an external VPN stop, would
  // otherwise rewrite, save and start this very manager while its previous stop is still
  // running - and that stop then rejects or tears down the replacement.
  NEVPNStatus status = manager.connection.status;
  if (status == NEVPNStatusConnected || status == NEVPNStatusConnecting
      || status == NEVPNStatusReasserting || status == NEVPNStatusDisconnecting) {
    if (status == NEVPNStatusDisconnecting) {
      [FBLogger log:@"socks5/connect: waiting for the in-flight tunnel stop to settle first"];
    } else {
      [FBLogger log:@"socks5/connect: stopping the already running tunnel first"];
      [manager.connection stopVPNTunnel];
    }
    if (![self waitUntilStopped:manager deadline:deadline]) {
      return FBSocks5Fail(error, FBSocks5TunnelManagerErrorTimeout,
                          @"Timed out stopping the previously running SOCKS5 tunnel");
    }
  }

  NETunnelProviderProtocol *protocol = [[NETunnelProviderProtocol alloc] init];
  protocol.providerBundleIdentifier = self.providerBundleIdentifier;
  protocol.serverAddress = uri.host;
  protocol.providerConfiguration = uri.providerConfiguration;
  protocol.disconnectOnSleep = NO;
  manager.protocolConfiguration = protocol;
  manager.localizedDescription = FBSocks5TunnelDescription;
  manager.enabled = YES;

  __block BOOL saveDone = NO;
  __block NSError *saveError = nil;
  dispatch_semaphore_t saveSignal = dispatch_semaphore_create(0);
  self.pendingSaveSignal = saveSignal;
  [manager saveToPreferencesWithCompletionHandler:^(NSError *err) {
    saveError = err;
    saveDone = YES;
    dispatch_semaphore_signal(saveSignal);
  }];
  // Keep re-attempting for as long as the alert is still up: a dispatched tap can be shed by the
  // system, so 'we dispatched one' is not evidence that it landed. tapConsentButtonWithLabels:
  // paces the re-attempts itself and answers NO once the alert is gone.
  __block BOOL consentTapped = NO;
  // No MAX(..., 1.0) floor here: granting an already-exhausted request another second is
  // exactly the overshoot the caller's timeout is supposed to prevent.
  [[[[FBRunLoopSpinner new] timeout:deadline.timeIntervalSinceNow] interval:0.3] spinUntilTrue:^BOOL{
    if (saveDone) {
      return YES;
    }
    if ([self tapConsentButtonWithLabels:labels]) {
      consentTapped = YES;
    }
    return NO;
  }];
  if (!saveDone) {
    return FBSocks5Fail(error, FBSocks5TunnelManagerErrorNotAuthorized,
                        [NSString stringWithFormat:
                         @"Timed out saving the VPN configuration. The consent alert was %@; "
                         "pass 'consentButtonLabels' if the device language is not English, and note that "
                         "devices with a passcode cannot confirm the VPN consent automatically",
                         consentTapped ? @"confirmed" : @"not confirmed"]);
  }
  self.pendingSaveSignal = nil;
  if (nil != saveError) {
    return FBSocks5Fail(error, FBSocks5TunnelManagerErrorNotAuthorized,
                        [NSString stringWithFormat:@"The VPN configuration was not authorized: %@",
                         saveError.localizedDescription]);
  }

  // A freshly saved configuration must be re-loaded before the tunnel can be started.
  __block BOOL reloadDone = NO;
  __block NSError *reloadError = nil;
  [manager loadFromPreferencesWithCompletionHandler:^(NSError *err) {
    reloadError = err;
    reloadDone = YES;
  }];
  [[[[FBRunLoopSpinner new] timeout:FBSocks5RemainingTimeout(deadline, FBSocks5PreferencesTimeout)] interval:0.05] spinUntilTrue:^BOOL{
    return reloadDone;
  }];
  if (!reloadDone || nil != reloadError) {
    return FBSocks5Fail(error, FBSocks5TunnelManagerErrorInternal,
                        [NSString stringWithFormat:@"Cannot reload the saved VPN configuration: %@",
                         reloadError.localizedDescription ?: @"timed out"]);
  }

  NSError *startError;
  if (![(NETunnelProviderSession *)manager.connection startVPNTunnelWithOptions:nil andReturnError:&startError]) {
    return FBSocks5Fail(error, FBSocks5TunnelManagerErrorInternal,
                        [NSString stringWithFormat:@"Cannot start the SOCKS5 tunnel: %@",
                         startError.localizedDescription]);
  }
  // The provider now validates the proxy before it reports startup, so a rejected start comes
  // back as the session dropping to disconnected. Stop on that rather than spinning out the
  // caller's whole deadline for a tunnel that is never going to come up.
  __block BOOL startRejected = NO;
  __block BOOL leftIdle = NO;
  BOOL connected = [[[[FBRunLoopSpinner new] timeout:deadline.timeIntervalSinceNow] interval:0.2] spinUntilTrue:^BOOL{
    NEVPNStatus status = manager.connection.status;
    if (status == NEVPNStatusConnected) {
      return YES;
    }
    // The session can still read as disconnected for an instant after startVPNTunnel, so only
    // treat that as terminal once it has actually entered a starting state. Reasserting still
    // counts as in-flight; only a settled stop is terminal.
    if (status != NEVPNStatusDisconnected && status != NEVPNStatusInvalid) {
      leftIdle = YES;
    } else if (leftIdle) {
      startRejected = YES;
      return YES;
    }
    return NO;
  }];
  if (!connected || startRejected) {
    NEVPNStatus finalStatus = manager.connection.status;
    [manager.connection stopVPNTunnel];
    return FBSocks5Fail(error, FBSocks5TunnelManagerErrorTimeout,
                        startRejected
                        ? [NSString stringWithFormat:
                           @"The SOCKS5 tunnel stopped right after starting. The proxy at %@:%lu "
                           "is unreachable, is not a SOCKS5 proxy, or rejected the credentials",
                           uri.host, (unsigned long)uri.port]
                        : [NSString stringWithFormat:
                           @"The SOCKS5 tunnel did not connect within %.0fs (status %ld). "
                           "Check that the proxy at %@:%lu is reachable from the device",
                           budget, (long)finalStatus, uri.host, (unsigned long)uri.port]);
  }
  self.activeManager = manager;
  [FBLogger logFmt:@"socks5/connect: tunnel connected through %@:%lu", uri.host, (unsigned long)uri.port];
  return YES;
}

- (BOOL)disconnectWithError:(NSError **)error
{
  __block BOOL succeeded = NO;
  __block NSError *localError = nil;
  [self performLocked:^{
    succeeded = [self lockedDisconnectWithError:&localError];
  }];
  if (!succeeded && nil != error) {
    *error = localError;
  }
  return succeeded;
}

- (BOOL)lockedDisconnectWithError:(NSError **)error
{
  // Without this a disconnect racing a timed-out connect could load nothing, or load a duplicate
  // that is not the tunnel actually running, and report success while the VPN stayed up.
  [self fencePendingSaveWithDeadline:nil];
  NSArray<NETunnelProviderManager *> *managers;
  if (![self loadAllManagers:&managers deadline:nil error:error]) {
    return NO;
  }
  NETunnelProviderManager *manager = [self ownManagerIn:managers] ?: self.activeManager;
  if (nil == manager) {
    return YES;
  }
  self.activeManager = manager;
  NEVPNStatus status = manager.connection.status;
  if (status == NEVPNStatusDisconnected || status == NEVPNStatusInvalid) {
    return YES;
  }
  [manager.connection stopVPNTunnel];
  if (![self waitUntilStopped:manager deadline:nil]) {
    return FBSocks5Fail(error, FBSocks5TunnelManagerErrorTimeout,
                        @"Timed out stopping the SOCKS5 tunnel");
  }
  [FBLogger log:@"socks5/disconnect: tunnel stopped"];
  return YES;
}

// Serialized like the mutating operations so a caller never observes the tunnel halfway through
// a stop/save/reload/start sequence.
- (NSDictionary<NSString *, id> *)statsDictionary
{
  __block NSDictionary<NSString *, id> *snapshot = nil;
  [self performLocked:^{
    snapshot = [self lockedStatsDictionary];
  }];
  return snapshot;
}

- (NSDictionary<NSString *, id> *)lockedStatsDictionary
{
  NSMutableDictionary<NSString *, id> *stats = FBSocks5DisconnectedStats();
  NETunnelProviderManager *manager = self.activeManager;
  if (nil == manager) {
    // Adopt a tunnel that survived a WDA restart (the configuration persists per install).
    NSArray<NETunnelProviderManager *> *managers;
    if ([self loadAllManagers:&managers deadline:nil error:nil]) {
      manager = [self ownManagerIn:managers];
      self.activeManager = manager;
    }
  }
  if (manager.connection.status != NEVPNStatusConnected) {
    return stats.copy;
  }
  stats[FBSocks5StatsKeyConnected] = @YES;
  NETunnelProviderProtocol *protocol = (NETunnelProviderProtocol *)manager.protocolConfiguration;
  if ([protocol isKindOfClass:NETunnelProviderProtocol.class]) {
    NSDictionary *config = protocol.providerConfiguration;
    stats[FBSocks5StatsKeyHost] = config[FBSocks5KeyHost];
    stats[FBSocks5StatsKeyPort] = config[FBSocks5KeyPort];
    stats[FBSocks5StatsKeyUser] = config[FBSocks5KeyUser];
  }

  NETunnelProviderSession *session = (NETunnelProviderSession *)manager.connection;
  __block NSDictionary *counters = nil;
  __block BOOL done = NO;
  NSError *messageError;
  BOOL sent = [session sendProviderMessage:(NSData *)[FBSocks5MsgStats dataUsingEncoding:NSUTF8StringEncoding]
                               returnError:&messageError
                           responseHandler:^(NSData *responseData) {
    if (nil != responseData) {
      id parsed = [NSJSONSerialization JSONObjectWithData:responseData
                                                  options:(NSJSONReadingOptions)0
                                                    error:nil];
      counters = [parsed isKindOfClass:NSDictionary.class] ? parsed : nil;
    }
    done = YES;
  }];
  if (sent) {
    [[[[FBRunLoopSpinner new] timeout:FBSocks5StatsReplyTimeout] interval:0.05] spinUntilTrue:^BOOL{
      return done;
    }];
  } else {
    [FBLogger logFmt:@"socks5/stats: cannot query the tunnel extension: %@", messageError.localizedDescription];
  }
  // Counters stay zero when the extension cannot answer in time; stats polling must not fail.
  for (NSString *key in @[FBSocks5StatsKeyRxBytes, FBSocks5StatsKeyTxBytes,
                          FBSocks5StatsKeyRxPackets, FBSocks5StatsKeyTxPackets]) {
    NSNumber *value = counters[key];
    if ([value isKindOfClass:NSNumber.class]) {
      stats[key] = value;
    }
  }
  return stats.copy;
}

@end

#endif
