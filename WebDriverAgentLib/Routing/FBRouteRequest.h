/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <Foundation/Foundation.h>

@class FBSession;

NS_ASSUME_NONNULL_BEGIN

/**
 Class that represents WebDriverAgent command request
 */
@interface FBRouteRequest : NSObject

/*! Request's URL */
@property (nonatomic, strong, readonly) NSURL *URL;

/*! Parameters sent with that request */
@property (nonatomic, copy, readonly) NSDictionary *parameters;

/*! Arguments sent with that request */
@property (nonatomic, copy, readonly) NSDictionary *arguments;

/*! Remote IP address of the HTTP client, when available */
@property (nonatomic, copy, readonly, nullable) NSString *clientAddress;

/*! Session associated with that request */
@property (nonatomic, strong, readonly) FBSession *session;

/**
 Convenience constructor for request
 */
+ (instancetype)routeRequestWithURL:(NSURL *)URL parameters:(NSDictionary *)parameters arguments:(NSDictionary *)arguments;

+ (instancetype)routeRequestWithURL:(NSURL *)URL
                         parameters:(NSDictionary *)parameters
                          arguments:(NSDictionary *)arguments
                      clientAddress:(nullable NSString *)clientAddress;

@end

NS_ASSUME_NONNULL_END
