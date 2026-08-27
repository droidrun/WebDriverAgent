/**
 * Copyright (c) 2026-present, Droidrun.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBSocks5TunnelManager.h"

#include <errno.h>
#import <stdatomic.h>

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

// The tunnel appex is only embedded by the WebDriverAgentRunnerTunnel schemes (the default
// runner schemes build without it so the hev submodule and paid-team signing stay optional);
// its presence in the host app is what decides whether SOCKS5 support exists in this build.
static BOOL FBSocks5TunnelExtensionEmbedded(NSBundle *bundle)
{
  NSString *appexPath = [bundle.bundlePath
                         stringByAppendingPathComponent:@"PlugIns/WebDriverAgentTunnel.appex"];
  BOOL isDirectory = NO;
  return [NSFileManager.defaultManager fileExistsAtPath:appexPath isDirectory:&isDirectory]
    && isDirectory;
}

static const NSTimeInterval FBSocks5PreferencesTimeout = 10.0;
static NSString *const FBSocks5NEVPNErrorDomain = @"NEVPNErrorDomain";
static NSString *const FBSocks5NEConfigurationErrorDomain = @"NEConfigurationErrorDomain";
static const NSInteger FBSocks5NEVPNErrorConfigurationStale = 4;
static const NSInteger FBSocks5NEConfigurationErrorPermissionDenied = 10;

typedef NS_ENUM(NSInteger, FBSocks5TunnelManagerSaveDisposition) {
  FBSocks5TunnelManagerSaveDispositionRetryStale,
  FBSocks5TunnelManagerSaveDispositionNotAuthorized,
  FBSocks5TunnelManagerSaveDispositionInternal,
};

static BOOL FBSocks5TunnelManagerErrorChainContainsPermissionFailure(NSError *error)
{
  NSError *candidate = error;
  for (NSUInteger depth = 0; nil != candidate && depth < 8; depth++) {
    if (([candidate.domain isEqualToString:FBSocks5NEConfigurationErrorDomain]
         && FBSocks5NEConfigurationErrorPermissionDenied == candidate.code)
        || ([candidate.domain isEqualToString:NSPOSIXErrorDomain]
            && (EACCES == candidate.code || EPERM == candidate.code))
        || ([candidate.domain isEqualToString:NSCocoaErrorDomain]
            && (NSFileReadNoPermissionError == candidate.code
                || NSFileWriteNoPermissionError == candidate.code))) {
      return YES;
    }
    id underlying = candidate.userInfo[NSUnderlyingErrorKey];
    candidate = [underlying isKindOfClass:NSError.class] ? underlying : nil;
  }
  return NO;
}

FBSocks5TunnelManagerSaveDisposition FBSocks5TunnelManagerSaveDispositionForError(NSError *error)
{
  if ([error.domain isEqualToString:FBSocks5NEVPNErrorDomain]
      && FBSocks5NEVPNErrorConfigurationStale == error.code) {
    return FBSocks5TunnelManagerSaveDispositionRetryStale;
  }
  if (FBSocks5TunnelManagerErrorChainContainsPermissionFailure(error)) {
    return FBSocks5TunnelManagerSaveDispositionNotAuthorized;
  }
  return FBSocks5TunnelManagerSaveDispositionInternal;
}

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

@interface FBSocks5LifecycleGuard : NSObject
@property (nonatomic, strong) NSRecursiveLock *lifecycleLock;
/**
 Signalled when a saveToPreferences that outlived its request finally completes.

 Returning from a timed-out save does not cancel it - NetworkExtension can still persist the
 manager afterwards. A follow-up operation that ran before that landed would load no manager,
 build a second one with the same provider id, and end up with two persisted configurations.
 */
@property (atomic, strong, nullable) dispatch_semaphore_t pendingSaveSignal;
- (BOOL)performLockedWithDeadline:(nullable NSDate *)deadline
                            block:(NS_NOESCAPE dispatch_block_t)block;
- (void)performLocked:(NS_NOESCAPE dispatch_block_t)block;
- (BOOL)fencePendingSaveWithDeadline:(nullable NSDate *)deadline error:(NSError **)error;
@end

@implementation FBSocks5LifecycleGuard

- (instancetype)init
{
  self = [super init];
  if (nil != self) {
    _lifecycleLock = [[NSRecursiveLock alloc] init];
    _lifecycleLock.name = @"com.facebook.WebDriverAgent.socks5-lifecycle";
  }
  return self;
}

- (BOOL)performLockedWithDeadline:(nullable NSDate *)deadline
                            block:(NS_NOESCAPE dispatch_block_t)block
{
  BOOL acquired;
  if (nil == deadline) {
    [self.lifecycleLock lock];
    acquired = YES;
  } else {
    acquired = [self.lifecycleLock lockBeforeDate:(NSDate *)deadline];
  }
  if (!acquired) {
    return NO;
  }
  @try {
    block();
  } @finally {
    [self.lifecycleLock unlock];
  }
  return YES;
}

- (void)performLocked:(NS_NOESCAPE dispatch_block_t)block
{
  [self performLockedWithDeadline:nil block:block];
}

- (BOOL)fencePendingSaveWithDeadline:(nullable NSDate *)deadline error:(NSError **)error
{
  dispatch_semaphore_t signal = self.pendingSaveSignal;
  if (nil == signal) {
    return YES;
  }
  NSTimeInterval budget = FBSocks5RemainingTimeout(deadline, FBSocks5PreferencesTimeout);
  if (budget <= 0
      || 0 != dispatch_semaphore_wait(signal, dispatch_time(DISPATCH_TIME_NOW,
                                                            (int64_t)(budget * NSEC_PER_SEC)))) {
    return FBSocks5Fail(error, FBSocks5TunnelManagerErrorTimeout,
                        @"Timed out waiting for a previous VPN configuration save to finish");
  }
  self.pendingSaveSignal = nil;
  return YES;
}

@end

@interface FBSocks5TunnelManager ()
/** Serializes the whole tunnel lifecycle without allowing a timed acquisition to execute later. */
@property (nonatomic, strong) FBSocks5LifecycleGuard *lifecycle;
@end

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

NSDictionary<NSString *, id> *_Nullable FBSocks5TunnelManagerDisconnectedStatsIfExtensionUnavailable(NSBundle *bundle)
{
  return FBSocks5TunnelExtensionEmbedded(bundle) ? nil : FBSocks5DisconnectedStats().copy;
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

- (nullable NSDictionary<NSString *, id> *)connectWithURI:(FBSocks5URI *)uri
                                                  timeout:(NSTimeInterval)timeout
                                      consentButtonLabels:(nullable NSArray<NSString *> *)consentButtonLabels
                                                    error:(NSError **)error
{
  return [self connectWithURI:uri
               controlAddress:nil
                      timeout:timeout
          consentButtonLabels:consentButtonLabels
                        error:error];
}

- (nullable NSDictionary<NSString *, id> *)connectWithURI:(FBSocks5URI *)uri
                                           controlAddress:(nullable NSString *)controlAddress
                                                  timeout:(NSTimeInterval)timeout
                                      consentButtonLabels:(nullable NSArray<NSString *> *)consentButtonLabels
                                                    error:(NSError **)error
{
  FBSocks5Fail(error, FBSocks5TunnelManagerErrorUnsupported,
               @"SOCKS5 tunnels require a NetworkExtension packet tunnel, which is not available on Simulator/tvOS");
  return nil;
}

- (nullable NSDictionary<NSString *, id> *)disconnectWithError:(NSError **)error
{
  FBSocks5Fail(error, FBSocks5TunnelManagerErrorUnsupported,
               @"SOCKS5 tunnels require a NetworkExtension packet tunnel, which is not available on Simulator/tvOS");
  return nil;
}

- (NSDictionary<NSString *, id> *)statsDictionary
{
  return FBSocks5DisconnectedStats().copy;
}

+ (BOOL)isTunnelExtensionEmbeddedInBundle:(NSBundle *)bundle
{
  return FBSocks5TunnelExtensionEmbedded(bundle);
}

- (instancetype)init
{
  self = [super init];
  if (nil != self) {
    _lifecycle = [[FBSocks5LifecycleGuard alloc] init];
  }
  return self;
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

// The extension target is built as '<runner bundle id>.xctrunner.tunnel', which becomes
// '<generated Runner.app bundle id>.tunnel'; derive the provider id from that final host id.
static NSString *const FBSocks5TunnelBundleSuffix = @".tunnel";
static NSString *const FBSocks5TunnelDescription = @"mobilerun SOCKS5";
static const NSTimeInterval FBSocks5StopTimeout = 10.0;
static const NSTimeInterval FBSocks5StatsReplyTimeout = 3.0;
static const NSTimeInterval FBSocks5DefaultConnectTimeout = 30.0;
/** Minimum gap between two consent taps, so a re-attempt cannot land during the dismissal animation. */
static const uint64_t FBSocks5ConsentTapCooldownMs = 1000;

static uint64_t FBSocks5NowMs(void)
{
  return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / NSEC_PER_MSEC;
}

@interface FBSocks5TunnelManager ()
@property (nonatomic, nullable) NETunnelProviderManager *activeManager;
/** Monotonic ms timestamp of the last consent tap dispatch; guards the re-attempt cooldown. */
@property (nonatomic) uint64_t lastConsentTapMs;
- (BOOL)reloadManager:(NETunnelProviderManager *)manager
              deadline:(NSDate *)deadline
               context:(NSString *)context
                 error:(NSError **)error;
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

+ (BOOL)isTunnelExtensionEmbeddedInBundle:(NSBundle *)bundle
{
  return FBSocks5TunnelExtensionEmbedded(bundle);
}

- (instancetype)init
{
  self = [super init];
  if (nil != self) {
    _lifecycle = [[FBSocks5LifecycleGuard alloc] init];
  }
  return self;
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
  __block volatile atomic_bool done = false;
  [NETunnelProviderManager loadAllFromPreferencesWithCompletionHandler:^(NSArray<NETunnelProviderManager *> *all, NSError *err) {
    managers = all;
    loadError = err;
    atomic_store_explicit(&done, true, memory_order_release);
  }];
  [[[[FBRunLoopSpinner new] timeout:budget] interval:0.05] spinUntilTrue:^BOOL{
    return atomic_load_explicit(&done, memory_order_acquire);
  }];
  // Running out of budget is a timeout, not an internal fault: collapsing the two would surface
  // a plain deadline miss as 'unknown error' instead of the documented timeout response.
  if (!atomic_load_explicit(&done, memory_order_acquire)) {
    return FBSocks5Fail(error, FBSocks5TunnelManagerErrorTimeout,
                        @"Timed out loading the VPN preferences");
  }
  if (nil != loadError) {
    return FBSocks5Fail(error, FBSocks5TunnelManagerErrorInternal,
                        [NSString stringWithFormat:@"Cannot load the VPN preferences: %@",
                         loadError.localizedDescription]);
  }
  if (nil != outManagers) {
    *outManagers = managers ?: @[];
  }
  return YES;
}

- (BOOL)reloadManager:(NETunnelProviderManager *)manager
              deadline:(NSDate *)deadline
               context:(NSString *)context
                 error:(NSError **)error
{
  NSTimeInterval budget = FBSocks5RemainingTimeout(deadline, FBSocks5PreferencesTimeout);
  if (budget <= 0) {
    return FBSocks5Fail(error, FBSocks5TunnelManagerErrorTimeout,
                        [NSString stringWithFormat:@"Timed out %@", context]);
  }
  __block volatile atomic_bool reloadDone = false;
  __block NSError *reloadError = nil;
  [manager loadFromPreferencesWithCompletionHandler:^(NSError *err) {
    reloadError = err;
    atomic_store_explicit(&reloadDone, true, memory_order_release);
  }];
  [[[[FBRunLoopSpinner new] timeout:budget] interval:0.05] spinUntilTrue:^BOOL{
    return atomic_load_explicit(&reloadDone, memory_order_acquire);
  }];
  if (!atomic_load_explicit(&reloadDone, memory_order_acquire)) {
    return FBSocks5Fail(error, FBSocks5TunnelManagerErrorTimeout,
                        [NSString stringWithFormat:@"Timed out %@", context]);
  }
  if (nil != reloadError) {
    return FBSocks5Fail(error, FBSocks5TunnelManagerErrorInternal,
                        [NSString stringWithFormat:@"Cannot %@: %@",
                         context, reloadError.localizedDescription]);
  }
  return YES;
}

// Returns the manager for our own provider, preferring one that is not idle. Duplicates with the
// same provider id can exist transiently (see the pending-save fence); picking whichever came first
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
// (they are marked standalone so the main queue stays free to drain the NetworkExtension
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

- (BOOL)tapConsentButtonWithLabels:(NSArray<NSString *> *)labels deadline:(NSDate *)deadline
{
  __block BOOL dispatched = NO;
  BOOL acquired = [FBWebServer performAutomationBlockOnMainQueue:^{
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
  } beforeDate:deadline];
  return acquired && dispatched;
}

#pragma mark - Public API

- (nullable NSDictionary<NSString *, id> *)connectWithURI:(FBSocks5URI *)uri
                                                  timeout:(NSTimeInterval)timeout
                                      consentButtonLabels:(nullable NSArray<NSString *> *)consentButtonLabels
                                                    error:(NSError **)error
{
  return [self connectWithURI:uri
               controlAddress:nil
                      timeout:timeout
          consentButtonLabels:consentButtonLabels
                        error:error];
}

- (nullable NSDictionary<NSString *, id> *)connectWithURI:(FBSocks5URI *)uri
                                           controlAddress:(nullable NSString *)controlAddress
                                                  timeout:(NSTimeInterval)timeout
                                      consentButtonLabels:(nullable NSArray<NSString *> *)consentButtonLabels
                                                    error:(NSError **)error
{
  // Start the clock before queueing, not inside the locked body: waiting behind another
  // operation is part of the caller's wall-clock budget, and a request with timeout:1 that
  // queued behind a 30s connect must not then be handed a fresh one-second budget.
  NSTimeInterval budget = timeout > 0 ? timeout : FBSocks5DefaultConnectTimeout;
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:budget];
  if (!FBSocks5TunnelExtensionEmbedded(NSBundle.mainBundle)) {
    FBSocks5Fail(error, FBSocks5TunnelManagerErrorUnsupported,
                 @"This build does not embed the WebDriverAgentTunnel extension; build the"
                 " WebDriverAgentRunnerTunnel scheme to include SOCKS5 VPN support"
                 " (see docs/socks5-tunnel.md)");
    return nil;
  }
  __block NSDictionary<NSString *, id> *snapshot = nil;
  __block NSError *localError = nil;
  BOOL acquired = [self.lifecycle performLockedWithDeadline:deadline block:^{
    if ([self lockedConnectWithURI:uri
                    controlAddress:controlAddress
                          deadline:deadline
               consentButtonLabels:consentButtonLabels
                             error:&localError]) {
      // Taken before the lock is released, so the payload cannot describe a tunnel that a
      // queued disconnect has since torn down. Capped at the caller's deadline: the documented
      // timeout covers the whole connect flow, so a slow provider stats reply must trim the
      // counters (they fall back to zero) rather than blow the budget.
      snapshot = [self lockedStatsDictionaryWithDeadline:deadline];
    }
  }];
  if (!acquired) {
    FBSocks5Fail(&localError, FBSocks5TunnelManagerErrorTimeout,
                 @"Timed out waiting for another SOCKS5 lifecycle operation to finish");
  }
  if (nil == snapshot && nil != error) {
    *error = localError;
  }
  return snapshot;
}

- (BOOL)lockedConnectWithURI:(FBSocks5URI *)uri
              controlAddress:(nullable NSString *)controlAddress
                    deadline:(NSDate *)deadline
         consentButtonLabels:(nullable NSArray<NSString *> *)consentButtonLabels
                       error:(NSError **)error
{
  NSTimeInterval budget = deadline.timeIntervalSinceNow;
  NSArray<NSString *> *labels = consentButtonLabels.count > 0 ? consentButtonLabels : @[@"Allow"];

  if (![self.lifecycle fencePendingSaveWithDeadline:deadline error:error]) {
    return NO;
  }
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
  protocol.providerConfiguration = [uri providerConfigurationWithControlAddress:controlAddress];
  protocol.disconnectOnSleep = NO;
  manager.protocolConfiguration = protocol;
  manager.localizedDescription = FBSocks5TunnelDescription;
  manager.enabled = YES;

  __block BOOL consentTapped = NO;
  NSUInteger staleRetries = 0;
  while (YES) {
    if (deadline.timeIntervalSinceNow <= 0) {
      return FBSocks5Fail(error, FBSocks5TunnelManagerErrorTimeout,
                          @"Timed out before saving the VPN configuration");
    }
    __block volatile atomic_bool saveDone = false;
    __block NSError *saveError = nil;
    dispatch_semaphore_t saveSignal = dispatch_semaphore_create(0);
    self.lifecycle.pendingSaveSignal = saveSignal;
    [manager saveToPreferencesWithCompletionHandler:^(NSError *err) {
      saveError = err;
      atomic_store_explicit(&saveDone, true, memory_order_release);
      dispatch_semaphore_signal(saveSignal);
    }];
    // Keep re-attempting for as long as the alert is still up: a dispatched tap can be shed by the
    // system, so 'we dispatched one' is not evidence that it landed. tapConsentButtonWithLabels:
    // paces the re-attempts itself and answers NO once the alert is gone.
    // No MAX(..., 1.0) floor here: granting an already-exhausted request another second is
    // exactly the overshoot the caller's timeout is supposed to prevent.
    [[[[FBRunLoopSpinner new] timeout:deadline.timeIntervalSinceNow] interval:0.3] spinUntilTrue:^BOOL{
      if (atomic_load_explicit(&saveDone, memory_order_acquire)) {
        return YES;
      }
      if ([self tapConsentButtonWithLabels:labels deadline:deadline]) {
        consentTapped = YES;
      }
      return NO;
    }];
    if (!atomic_load_explicit(&saveDone, memory_order_acquire)) {
      return FBSocks5Fail(error, FBSocks5TunnelManagerErrorTimeout,
                          [NSString stringWithFormat:
                           @"Timed out saving the VPN configuration. The consent alert was %@; "
                           "pass 'consentButtonLabels' if the device language is not English, and note that "
                           "devices with a passcode cannot confirm the VPN consent automatically",
                           consentTapped ? @"confirmed" : @"not confirmed"]);
    }
    self.lifecycle.pendingSaveSignal = nil;
    if (nil == saveError) {
      break;
    }
    FBSocks5TunnelManagerSaveDisposition disposition =
      FBSocks5TunnelManagerSaveDispositionForError(saveError);
    if (FBSocks5TunnelManagerSaveDispositionRetryStale == disposition && 0 == staleRetries) {
      staleRetries++;
      [FBLogger log:@"socks5/connect: VPN configuration became stale; reloading and retrying the save once"];
      if (![self reloadManager:manager
                      deadline:deadline
                       context:@"reloading the stale VPN configuration"
                         error:error]) {
        return NO;
      }
      manager.protocolConfiguration = protocol;
      manager.localizedDescription = FBSocks5TunnelDescription;
      manager.enabled = YES;
      continue;
    }
    FBSocks5TunnelManagerError code = FBSocks5TunnelManagerSaveDispositionNotAuthorized == disposition
      ? FBSocks5TunnelManagerErrorNotAuthorized
      : FBSocks5TunnelManagerErrorInternal;
    NSString *prefix = FBSocks5TunnelManagerSaveDispositionNotAuthorized == disposition
      ? @"The VPN configuration was not authorized"
      : @"Cannot save the VPN configuration";
    return FBSocks5Fail(error, code,
                        [NSString stringWithFormat:@"%@: %@", prefix, saveError.localizedDescription]);
  }

  // A freshly saved configuration must be re-loaded before the tunnel can be started.
  if (![self reloadManager:manager
                  deadline:deadline
                   context:@"reloading the saved VPN configuration"
                     error:error]) {
    return NO;
  }

  if (deadline.timeIntervalSinceNow <= 0) {
    return FBSocks5Fail(error, FBSocks5TunnelManagerErrorTimeout,
                        @"Timed out before the SOCKS5 tunnel could start");
  }
  NSDictionary<NSString *, NSObject *> *startOptions = @{
    FBSocks5OptionStartupDeadline: @(deadline.timeIntervalSinceReferenceDate),
  };
  NSError *startError;
  if (![(NETunnelProviderSession *)manager.connection startVPNTunnelWithOptions:startOptions
                                                                 andReturnError:&startError]) {
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
    NEVPNStatus currentStatus = manager.connection.status;
    if (currentStatus == NEVPNStatusConnected) {
      return YES;
    }
    // The session can still read as disconnected for an instant after startVPNTunnel, so only
    // treat that as terminal once it has actually entered a starting state. Reasserting still
    // counts as in-flight; only a settled stop is terminal.
    if (currentStatus != NEVPNStatusDisconnected && currentStatus != NEVPNStatusInvalid) {
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

- (nullable NSDictionary<NSString *, id> *)disconnectWithError:(NSError **)error
{
  NSDictionary<NSString *, id> *unavailableSnapshot =
    FBSocks5TunnelManagerDisconnectedStatsIfExtensionUnavailable(NSBundle.mainBundle);
  if (nil != unavailableSnapshot) {
    return unavailableSnapshot;
  }
  __block NSDictionary<NSString *, id> *snapshot = nil;
  __block NSError *localError = nil;
  [self.lifecycle performLocked:^{
    if ([self lockedDisconnectWithError:&localError]) {
      snapshot = [self lockedStatsDictionary];
    }
  }];
  if (nil == snapshot && nil != error) {
    *error = localError;
  }
  return snapshot;
}

- (BOOL)lockedDisconnectWithError:(NSError **)error
{
  // Without this a disconnect racing a timed-out connect could load nothing, or load a duplicate
  // that is not the tunnel actually running, and report success while the VPN stayed up.
  if (![self.lifecycle fencePendingSaveWithDeadline:nil error:error]) {
    return NO;
  }
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
  [self.lifecycle performLocked:^{
    snapshot = [self lockedStatsDictionary];
  }];
  return snapshot;
}

- (NSDictionary<NSString *, id> *)lockedStatsDictionary
{
  return [self lockedStatsDictionaryWithDeadline:nil];
}

- (NSDictionary<NSString *, id> *)lockedStatsDictionaryWithDeadline:(nullable NSDate *)deadline
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

  // Counters are best-effort: with the caller's budget already exhausted, skip the round trip
  // to the extension instead of stretching the response past the documented timeout.
  NSTimeInterval statsBudget = FBSocks5RemainingTimeout(deadline, FBSocks5StatsReplyTimeout);
  if (statsBudget <= 0) {
    return stats.copy;
  }
  NETunnelProviderSession *session = (NETunnelProviderSession *)manager.connection;
  __block NSDictionary *counters = nil;
  __block volatile atomic_bool done = false;
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
    atomic_store_explicit(&done, true, memory_order_release);
  }];
  if (sent) {
    [[[[FBRunLoopSpinner new] timeout:statsBudget] interval:0.05] spinUntilTrue:^BOOL{
      return atomic_load_explicit(&done, memory_order_acquire);
    }];
  } else {
    [FBLogger logFmt:@"socks5/stats: cannot query the tunnel extension: %@", messageError.localizedDescription];
  }
  // Counters stay zero when the extension cannot answer in time; do not read the result storage
  // unless the acquire observed the callback's release publication.
  NSDictionary *completedCounters = atomic_load_explicit(&done, memory_order_acquire) ? counters : nil;
  for (NSString *key in @[FBSocks5StatsKeyRxBytes, FBSocks5StatsKeyTxBytes,
                          FBSocks5StatsKeyRxPackets, FBSocks5StatsKeyTxPackets]) {
    NSNumber *value = completedCounters[key];
    if ([value isKindOfClass:NSNumber.class]) {
      stats[key] = value;
    }
  }
  return stats.copy;
}

@end

#endif
