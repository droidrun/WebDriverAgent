/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBMobilerunSocks5Commands.h"

#include <math.h>

#import "FBCommandStatus.h"
#import "FBResponsePayload.h"
#import "FBRoute.h"
#import "FBRouteRequest.h"
#import "FBSocks5TunnelManager.h"
#import "FBSocks5URI.h"

static const NSTimeInterval FBSocks5ConnectDefaultTimeout = 30.0;
static const NSTimeInterval FBSocks5ConnectMaximumTimeout = 300.0;

BOOL FBSocks5ConnectTimeoutFromValue(id _Nullable value, NSTimeInterval *timeout)
{
  NSTimeInterval validatedTimeout = FBSocks5ConnectDefaultTimeout;
  if (nil != value) {
    if (![value isKindOfClass:NSNumber.class]
        || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
      return NO;
    }
    validatedTimeout = [value doubleValue];
    if (!isfinite(validatedTimeout)
        || validatedTimeout <= 0
        || validatedTimeout > FBSocks5ConnectMaximumTimeout) {
      return NO;
    }
  }
  if (NULL != timeout) {
    *timeout = validatedTimeout;
  }
  return YES;
}

@implementation FBMobilerunSocks5Commands

#pragma mark - <FBCommandHandler>

+ (NSArray *)routes
{
  return
  @[
    [[FBRoute POST:@"/mobilerun/socks5/connect"].standalone respondWithTarget:self action:@selector(handleConnect:)],
    [[FBRoute POST:@"/mobilerun/socks5/disconnect"].standalone respondWithTarget:self action:@selector(handleDisconnect:)],
    [[FBRoute GET:@"/mobilerun/socks5/stats"].standalone respondWithTarget:self action:@selector(handleStats:)],
    [[FBRoute POST:@"/mobilerun/socks5/connect"].withoutSession.standalone respondWithTarget:self action:@selector(handleConnect:)],
    [[FBRoute POST:@"/mobilerun/socks5/disconnect"].withoutSession.standalone respondWithTarget:self action:@selector(handleDisconnect:)],
    [[FBRoute GET:@"/mobilerun/socks5/stats"].withoutSession.standalone respondWithTarget:self action:@selector(handleStats:)],
  ];
}

#pragma mark - Commands

+ (id<FBResponsePayload>)handleConnect:(FBRouteRequest *)request
{
  id uriValue = request.arguments[@"uri"];
  if (![uriValue isKindOfClass:NSString.class] || 0 == [uriValue length]) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"The request body must contain a 'uri' string like socks5h://user:pass@host:1080"
                                                                       traceback:nil]);
  }
  NSError *parseError;
  FBSocks5URI *uri = [FBSocks5URI parse:(NSString *)uriValue error:&parseError];
  if (nil == uri) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:parseError.localizedDescription
                                                                       traceback:nil]);
  }
  NSTimeInterval timeout;
  id timeoutValue = request.arguments[@"timeout"];
  if (!FBSocks5ConnectTimeoutFromValue(timeoutValue, &timeout)) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:
                                 @"'timeout' must be a finite number greater than 0 and at most 300 seconds"
                                                                       traceback:nil]);
  }
  NSArray<NSString *> *consentLabels = nil;
  id labelsValue = request.arguments[@"consentButtonLabels"];
  if ([labelsValue isKindOfClass:NSArray.class]) {
    NSPredicate *isString = [NSPredicate predicateWithBlock:^BOOL(id item, NSDictionary *bindings) {
      return [item isKindOfClass:NSString.class];
    }];
    consentLabels = [(NSArray *)labelsValue filteredArrayUsingPredicate:isString];
  }

  NSError *error;
  // The snapshot comes back from inside the same lifecycle transaction as the mutation; asking
  // for stats afterwards would let a queued disconnect slip in and make this response describe
  // a tunnel that is already gone.
  NSDictionary<NSString *, id> *stats =
    [FBSocks5TunnelManager.sharedInstance connectWithURI:uri
                                         controlAddress:request.clientAddress
                                                 timeout:timeout
                                     consentButtonLabels:consentLabels
                                                   error:&error];
  if (nil == stats) {
    return [self responseWithTunnelManagerError:error];
  }
  return FBResponseWithObject(stats);
}

+ (id<FBResponsePayload>)handleDisconnect:(FBRouteRequest *)request
{
  NSError *error;
  NSDictionary<NSString *, id> *stats = [FBSocks5TunnelManager.sharedInstance disconnectWithError:&error];
  if (nil == stats) {
    return [self responseWithTunnelManagerError:error];
  }
  return FBResponseWithObject(stats);
}

+ (id<FBResponsePayload>)handleStats:(FBRouteRequest *)request
{
  return FBResponseWithObject(FBSocks5TunnelManager.sharedInstance.statsDictionary);
}

#pragma mark - Helpers

+ (id<FBResponsePayload>)responseWithTunnelManagerError:(NSError *)error
{
  if (![error.domain isEqualToString:FBSocks5TunnelManagerErrorDomain]) {
    return FBResponseWithUnknownError(error);
  }
  switch ((FBSocks5TunnelManagerError)error.code) {
    case FBSocks5TunnelManagerErrorUnsupported:
    case FBSocks5TunnelManagerErrorNotAuthorized:
      return FBResponseWithStatus([FBCommandStatus unsupportedOperationErrorWithMessage:error.localizedDescription
                                                                               traceback:nil]);
    case FBSocks5TunnelManagerErrorTimeout:
      return FBResponseWithStatus([FBCommandStatus timeoutErrorWithMessage:error.localizedDescription
                                                                  traceback:nil]);
    case FBSocks5TunnelManagerErrorInternal:
      return FBResponseWithUnknownError(error);
  }
  return FBResponseWithUnknownError(error);
}

@end
