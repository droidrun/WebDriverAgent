/**
 * Copyright (c) 2026-present, Droidrun.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <XCTest/XCTest.h>

#import "FBBroadcastManager.h"

@interface FBBroadcastLabelsTests : XCTestCase
@end

@implementation FBBroadcastLabelsTests

- (void)testStartBroadcastLabelCoversNonEnglishLanguages
{
  NSArray<NSString *> *labels = [FBBroadcastManager replayKitLabelsForKey:@"CONTROL_CENTER_START_BROADCAST"];
  // iOS 27 kept the key but renamed the button ("Start Broadcast" -> "Start Sharing"), which is
  // exactly why the labels are resolved by key rather than hardcoded.
  XCTAssertTrue([labels containsObject:@"Start Broadcast"] || [labels containsObject:@"Start Sharing"]);
  // The German label does not start with "Start" - the case that broke the old prefix matching.
  XCTAssertTrue([labels containsObject:@"Übertragung starten"] || [labels containsObject:@"Jetzt teilen"]);
  XCTAssertTrue([labels containsObject:@"开始直播"] || [labels containsObject:@"开始共享"]);
  XCTAssertEqual(labels.count, [NSSet setWithArray:labels].count);
}

- (void)testScreenBroadcastingAlertLabelsCoverNonEnglishLanguages
{
  NSArray<NSString *> *okLabels = [FBBroadcastManager replayKitLabelsForKey:@"BROADCAST_FAILED_ALERT_OK_BUTTON"];
  XCTAssertTrue([okLabels containsObject:@"OK"]);
  XCTAssertTrue([okLabels containsObject:@"Tamam"]);
  NSArray<NSString *> *goToAppLabels = [FBBroadcastManager replayKitLabelsForKey:@"BROADCAST_FAILED_ALERT_GO_TO_APP_BUTTON"];
  XCTAssertTrue([goToAppLabels containsObject:@"Go to Application"]);
  XCTAssertTrue([goToAppLabels containsObject:@"Zur App gehen"]);
}

- (void)testUnknownKeyYieldsNoLabels
{
  XCTAssertEqualObjects([FBBroadcastManager replayKitLabelsForKey:@"FB_NO_SUCH_REPLAYKIT_KEY"], @[]);
}

@end
