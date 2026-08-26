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

@interface FBSocks5TunnelManager ()
@property (nonatomic, nullable) NETunnelProviderManager *activeManager;
/** Monotonic ms timestamp of the last consent tap dispatch; guards the re-attempt cooldown. */
@property (nonatomic) uint64_t lastConsentTapMs;
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

#pragma mark - Helpers

- (NSString *)providerBundleIdentifier
{
  return [NSBundle.mainBundle.bundleIdentifier stringByAppendingString:FBSocks5TunnelBundleSuffix];
}

- (BOOL)loadAllManagers:(NSArray<NETunnelProviderManager *> **)outManagers error:(NSError **)error
{
  __block NSArray<NETunnelProviderManager *> *managers = nil;
  __block NSError *loadError = nil;
  __block BOOL done = NO;
  [NETunnelProviderManager loadAllFromPreferencesWithCompletionHandler:^(NSArray<NETunnelProviderManager *> *all, NSError *err) {
    managers = all;
    loadError = err;
    done = YES;
  }];
  [[[[FBRunLoopSpinner new] timeout:FBSocks5PreferencesTimeout] interval:0.05] spinUntilTrue:^BOOL{
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

- (nullable NETunnelProviderManager *)ownManagerIn:(NSArray<NETunnelProviderManager *> *)managers
{
  NSString *providerId = self.providerBundleIdentifier;
  for (NETunnelProviderManager *manager in managers) {
    NETunnelProviderProtocol *protocol = (NETunnelProviderProtocol *)manager.protocolConfiguration;
    if ([protocol isKindOfClass:NETunnelProviderProtocol.class]
        && [protocol.providerBundleIdentifier isEqualToString:providerId]) {
      return manager;
    }
  }
  return nil;
}

- (BOOL)waitUntilStopped:(NETunnelProviderManager *)manager
{
  return [[[[FBRunLoopSpinner new] timeout:FBSocks5StopTimeout] interval:0.2] spinUntilTrue:^BOOL{
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
- (BOOL)tapConsentButtonWithLabels:(NSArray<NSString *> *)labels
{
  __block BOOL dispatched = NO;
  [FBWebServer performAutomationBlockOnMainQueue:^{
    XCUIApplication *system = XCUIApplication.fb_systemApplication;
    for (NSString *label in labels) {
      XCUIElement *button = system.buttons[label];
      if (!button.exists) {
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
  NSTimeInterval budget = timeout > 0 ? timeout : FBSocks5DefaultConnectTimeout;
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:budget];
  NSArray<NSString *> *labels = consentButtonLabels.count > 0 ? consentButtonLabels : @[@"Allow"];

  NSArray<NETunnelProviderManager *> *managers;
  if (![self loadAllManagers:&managers error:error]) {
    return NO;
  }
  NETunnelProviderManager *manager = [self ownManagerIn:managers] ?: [[NETunnelProviderManager alloc] init];

  // Connecting while a tunnel runs replaces it.
  NEVPNStatus status = manager.connection.status;
  if (status == NEVPNStatusConnected || status == NEVPNStatusConnecting || status == NEVPNStatusReasserting) {
    [FBLogger log:@"socks5/connect: stopping the already running tunnel first"];
    [manager.connection stopVPNTunnel];
    if (![self waitUntilStopped:manager]) {
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
  [manager saveToPreferencesWithCompletionHandler:^(NSError *err) {
    saveError = err;
    saveDone = YES;
  }];
  // Keep re-attempting for as long as the alert is still up: a dispatched tap can be shed by the
  // system, so 'we dispatched one' is not evidence that it landed. tapConsentButtonWithLabels:
  // paces the re-attempts itself and answers NO once the alert is gone.
  __block BOOL consentTapped = NO;
  [[[[FBRunLoopSpinner new] timeout:MAX(deadline.timeIntervalSinceNow, 1.0)] interval:0.3] spinUntilTrue:^BOOL{
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
  [[[[FBRunLoopSpinner new] timeout:FBSocks5PreferencesTimeout] interval:0.05] spinUntilTrue:^BOOL{
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
  BOOL connected = [[[[FBRunLoopSpinner new] timeout:MAX(deadline.timeIntervalSinceNow, 1.0)] interval:0.2] spinUntilTrue:^BOOL{
    return manager.connection.status == NEVPNStatusConnected;
  }];
  if (!connected) {
    NEVPNStatus finalStatus = manager.connection.status;
    [manager.connection stopVPNTunnel];
    return FBSocks5Fail(error, FBSocks5TunnelManagerErrorTimeout,
                        [NSString stringWithFormat:
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
  NSArray<NETunnelProviderManager *> *managers;
  if (![self loadAllManagers:&managers error:error]) {
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
  if (![self waitUntilStopped:manager]) {
    return FBSocks5Fail(error, FBSocks5TunnelManagerErrorTimeout,
                        @"Timed out stopping the SOCKS5 tunnel");
  }
  [FBLogger log:@"socks5/disconnect: tunnel stopped"];
  return YES;
}

- (NSDictionary<NSString *, id> *)statsDictionary
{
  NSMutableDictionary<NSString *, id> *stats = FBSocks5DisconnectedStats();
  NETunnelProviderManager *manager = self.activeManager;
  if (nil == manager) {
    // Adopt a tunnel that survived a WDA restart (the configuration persists per install).
    NSArray<NETunnelProviderManager *> *managers;
    if ([self loadAllManagers:&managers error:nil]) {
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
