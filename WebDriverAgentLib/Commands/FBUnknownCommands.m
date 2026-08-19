/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBUnknownCommands.h"

#import "FBRouteRequest.h"

@implementation FBUnknownCommands

#pragma mark - <FBCommandHandler>

+ (BOOL)shouldRegisterAutomatically
{
  return NO;
}

+ (NSArray *)routes
{
  return
  @[
    [[[FBRoute GET:@"/*"].withoutSession onControlQueue] respondWithTarget:self action:@selector(unhandledHandler:)],
    [[[FBRoute POST:@"/*"].withoutSession onControlQueue] respondWithTarget:self action:@selector(unhandledHandler:)],
    [[[FBRoute PUT:@"/*"].withoutSession onControlQueue] respondWithTarget:self action:@selector(unhandledHandler:)],
    [[[FBRoute DELETE:@"/*"].withoutSession onControlQueue] respondWithTarget:self action:@selector(unhandledHandler:)]
  ];
}

+ (id<FBResponsePayload>)unhandledHandler:(FBRouteRequest *)request
{
  return FBResponseWithStatus([FBCommandStatus unknownCommandErrorWithMessage:[NSString stringWithFormat:@"Unhandled endpoint: %@ with parameters %@", request.URL, request.parameters]
                                                                    traceback:nil]);
}

@end
