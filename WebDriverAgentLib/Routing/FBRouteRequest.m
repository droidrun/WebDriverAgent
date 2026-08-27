/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBRouteRequest-Private.h"

static NSString *FBRedactedURIString(NSString *value)
{
  NSRange schemeSeparator = [value rangeOfString:@"://"];
  if (NSNotFound == schemeSeparator.location) {
    return value;
  }
  NSUInteger authorityStart = NSMaxRange(schemeSeparator);
  NSRange authorityTail = NSMakeRange(authorityStart, value.length - authorityStart);
  NSRange authorityEnd = [value rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/?#"]
                                                options:(NSStringCompareOptions)0
                                                  range:authorityTail];
  NSUInteger authorityLength = NSNotFound == authorityEnd.location
    ? value.length - authorityStart
    : authorityEnd.location - authorityStart;
  NSRange userInfoSeparator = [value rangeOfString:@"@"
                                          options:NSBackwardsSearch
                                            range:NSMakeRange(authorityStart, authorityLength)];
  if (NSNotFound == userInfoSeparator.location) {
    return value;
  }

  NSMutableString *redacted = value.mutableCopy;
  [redacted replaceCharactersInRange:NSMakeRange(authorityStart,
                                                  userInfoSeparator.location - authorityStart)
                           withString:@"<redacted>"];
  return redacted.copy;
}

static NSString *FBRedactedProxyURIString(NSString *value)
{
  NSString *redacted = FBRedactedURIString(value);
  if (![redacted isEqualToString:value]) {
    return redacted;
  }
  NSRange userInfoSeparator = [value rangeOfString:@"@" options:NSBackwardsSearch];
  if (NSNotFound == userInfoSeparator.location) {
    return value;
  }
  NSMutableString *fallback = value.mutableCopy;
  [fallback replaceCharactersInRange:NSMakeRange(0, userInfoSeparator.location)
                          withString:@"<redacted>"];
  return fallback.copy;
}

static id FBRedactedRequestLogValue(id value)
{
  if ([value isKindOfClass:NSString.class]) {
    return FBRedactedURIString((NSString *)value);
  }
  if ([value isKindOfClass:NSArray.class]) {
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:[(NSArray *)value count]];
    for (id item in (NSArray *)value) {
      [result addObject:FBRedactedRequestLogValue(item)];
    }
    return result.copy;
  }
  if ([value isKindOfClass:NSDictionary.class]) {
    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithCapacity:[(NSDictionary *)value count]];
    [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id key, id item, BOOL *stop) {
      result[key] = FBRedactedRequestLogValue(item);
    }];
    return result.copy;
  }
  return value;
}

static id FBRedactedRequestArguments(NSURL *URL, id arguments)
{
  id redactedValue = FBRedactedRequestLogValue(arguments);
  if (![redactedValue isKindOfClass:NSDictionary.class]
      || ![arguments isKindOfClass:NSDictionary.class]) {
    return redactedValue;
  }
  NSMutableDictionary *redacted = [(NSDictionary *)redactedValue mutableCopy];
  id uri = ((NSDictionary *)arguments)[@"uri"];
  if ([URL.path hasSuffix:@"/mobilerun/socks5/connect"] && [uri isKindOfClass:NSString.class]) {
    redacted[@"uri"] = FBRedactedProxyURIString((NSString *)uri);
  }
  return redacted.copy;
}

@implementation FBRouteRequest

+ (instancetype)routeRequestWithURL:(NSURL *)URL parameters:(NSDictionary *)parameters arguments:(NSDictionary *)arguments
{
  return [self routeRequestWithURL:URL
                        parameters:parameters
                         arguments:arguments
                     clientAddress:nil];
}

+ (instancetype)routeRequestWithURL:(NSURL *)URL
                         parameters:(NSDictionary *)parameters
                          arguments:(NSDictionary *)arguments
                      clientAddress:(nullable NSString *)clientAddress
{
  FBRouteRequest *request = [self.class new];
  request.URL = URL;
  request.parameters = parameters;
  request.arguments = arguments;
  request.clientAddress = clientAddress;
  return request;
}

- (NSString *)description
{
  return [NSString stringWithFormat:
    @"Request URL %@ | Params %@ | Arguments %@",
    self.URL,
    self.parameters,
    FBRedactedRequestArguments(self.URL, self.arguments)
  ];
}

@end
