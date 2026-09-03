/**
 * Copyright (c) 2026-present, Droidrun.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <XCTest/XCTest.h>

#import "FBBroadcastProtocol.h"
#import "FBScrcpyPacket.h"
#import "FBVideoStreamSession.h"

// Mirrors the wire constants consumed by ios-wired/cmd/scrcpy-bridge/h264reader.go.
static const uint64_t kFlagConfig   = (uint64_t)1 << 63;
static const uint64_t kFlagKeyFrame = (uint64_t)1 << 62;
static const uint64_t kPtsMask      = ~(((uint64_t)1 << 63) | ((uint64_t)1 << 62));

@interface FBVideoStreamSessionTests : XCTestCase
@end

@implementation FBVideoStreamSessionTests

// Parses a packet the same way h264reader.go:ReadFrame does, so the test fails if the on-wire
// layout (big-endian 8-byte pts+flags, big-endian 4-byte size, payload) ever drifts.
- (void)parsePacket:(NSData *)packet
            isConfig:(BOOL *)isConfig
          isKeyFrame:(BOOL *)isKeyFrame
                ptsUs:(uint64_t *)ptsUs
             payload:(NSData **)payload
{
  XCTAssertGreaterThanOrEqual(packet.length, 12u, @"A packet must be at least the 12-byte header");
  const uint8_t *bytes = (const uint8_t *)packet.bytes;

  uint64_t ptsAndFlags = 0;
  for (int i = 0; i < 8; i++) {
    ptsAndFlags = (ptsAndFlags << 8) | bytes[i];
  }
  uint32_t size = 0;
  for (int i = 8; i < 12; i++) {
    size = (size << 8) | bytes[i];
  }

  XCTAssertEqual(packet.length, 12u + size, @"The size field must match the payload length");
  *isConfig = (ptsAndFlags & kFlagConfig) != 0;
  *isKeyFrame = (ptsAndFlags & kFlagKeyFrame) != 0;
  *ptsUs = ptsAndFlags & kPtsMask;
  *payload = [packet subdataWithRange:NSMakeRange(12, size)];
}

- (void)testInterFramePacket
{
  NSData *au = [@"picture-bytes" dataUsingEncoding:NSUTF8StringEncoding];
  NSData *packet = FBScrcpyPacketCreate(au, 0, 123456);

  BOOL isConfig = YES, isKeyFrame = YES;
  uint64_t pts = 0;
  NSData *payload = nil;
  [self parsePacket:packet isConfig:&isConfig isKeyFrame:&isKeyFrame ptsUs:&pts payload:&payload];

  XCTAssertFalse(isConfig);
  XCTAssertFalse(isKeyFrame);
  XCTAssertEqual(pts, 123456u);
  XCTAssertEqualObjects(payload, au);
}

- (void)testKeyFramePacket
{
  NSData *au = [@"idr" dataUsingEncoding:NSUTF8StringEncoding];
  NSData *packet = FBScrcpyPacketCreate(au, kFlagKeyFrame, 1000000);

  BOOL isConfig = YES, isKeyFrame = NO;
  uint64_t pts = 0;
  NSData *payload = nil;
  [self parsePacket:packet isConfig:&isConfig isKeyFrame:&isKeyFrame ptsUs:&pts payload:&payload];

  XCTAssertFalse(isConfig);
  XCTAssertTrue(isKeyFrame);
  XCTAssertEqual(pts, 1000000u);
  XCTAssertEqualObjects(payload, au);
}

- (void)testConfigPacket
{
  const uint8_t sps[] = {0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0x00, 0x1f};
  NSData *parameterSets = [NSData dataWithBytes:sps length:sizeof(sps)];
  NSData *packet = FBScrcpyPacketCreate(parameterSets, kFlagConfig, 0);

  BOOL isConfig = NO, isKeyFrame = YES;
  uint64_t pts = 1;
  NSData *payload = nil;
  [self parsePacket:packet isConfig:&isConfig isKeyFrame:&isKeyFrame ptsUs:&pts payload:&payload];

  XCTAssertTrue(isConfig);
  XCTAssertFalse(isKeyFrame);
  XCTAssertEqual(pts, 0u);
  XCTAssertEqualObjects(payload, parameterSets);
}

- (void)testBroadcastTargetSizeFollowsEffectiveFrameOrientation
{
  // ReplayKit keeps a portrait-shaped pixel buffer for this landscape frame
  // and carries the clockwise rotation in RPVideoSampleOrientationKey.
  FBBroadcastDimensions landscape = FBBroadcastTargetDimensions(1278, 588, 1170, 2532, 6);
  XCTAssertEqual(landscape.width, (NSUInteger)1278);
  XCTAssertEqual(landscape.height, (NSUInteger)588);
  FBBroadcastDimensions otherLandscape = FBBroadcastTargetDimensions(1278, 588, 1170, 2532, 8);
  XCTAssertEqual(otherLandscape.width, (NSUInteger)1278);
  XCTAssertEqual(otherLandscape.height, (NSUInteger)588);

  // Enabling portrait lock changes only the orientation attachment. The
  // encoder footprint must cross axes or WebRTC keeps reporting landscape.
  FBBroadcastDimensions portrait = FBBroadcastTargetDimensions(1278, 588, 1170, 2532, 1);
  XCTAssertEqual(portrait.width, (NSUInteger)588);
  XCTAssertEqual(portrait.height, (NSUInteger)1278);
}

- (void)testBroadcastTargetSizeFallsBackToBufferAspectForUnknownOrientation
{
  FBBroadcastDimensions landscape = FBBroadcastTargetDimensions(588, 1278, 2532, 1170, 0);
  XCTAssertEqual(landscape.width, (NSUInteger)1278);
  XCTAssertEqual(landscape.height, (NSUInteger)588);
}

- (void)testBroadcastFrameProtocolPreservesExifOrientationEight
{
  NSData *picture = [@"frame" dataUsingEncoding:NSUTF8StringEncoding];
  NSData *message = FBBroadcastEncodeVideoFrameMessage(42, 123, YES, 8, picture);

  FBBroadcastMessageHeader header;
  NSData *headerData = [message subdataWithRange:NSMakeRange(0, FBBroadcastHeaderLength)];
  XCTAssertTrue(FBBroadcastParseHeader(headerData, &header));
  XCTAssertEqual(header.type, (uint8_t)FBBroadcastMessageTypeVideoFrame);
  XCTAssertEqual(header.sessionId, (uint32_t)42);
  NSData *payload = [message subdataWithRange:NSMakeRange(FBBroadcastHeaderLength, header.payloadLength)];

  uint64_t pts = 0;
  BOOL key = NO;
  uint8_t orientation = 0;
  NSData *decoded = nil;
  XCTAssertTrue(FBBroadcastParseVideoFramePayload(payload, &pts, &key, &orientation, &decoded));
  XCTAssertEqual(pts, (uint64_t)123);
  XCTAssertTrue(key);
  XCTAssertEqual(orientation, (uint8_t)8);
  XCTAssertEqualObjects(decoded, picture);
}

- (void)testBroadcastEncoderReconfigurationRetryBackoffIsBounded
{
  XCTAssertEqual(FBBroadcastReconfigureRetryDelayMs(1), (uint64_t)250);
  XCTAssertEqual(FBBroadcastReconfigureRetryDelayMs(2), (uint64_t)500);
  XCTAssertEqual(FBBroadcastReconfigureRetryDelayMs(3), (uint64_t)1000);
  XCTAssertEqual(FBBroadcastReconfigureRetryDelayMs(4), (uint64_t)2000);
  XCTAssertEqual(FBBroadcastReconfigureRetryDelayMs(5), (uint64_t)4000);
  XCTAssertEqual(FBBroadcastReconfigureRetryDelayMs(6), (uint64_t)5000);
  XCTAssertEqual(FBBroadcastReconfigureRetryDelayMs(100), (uint64_t)5000);
}

- (void)testBroadcastEncoderReconfigurationRetryStartsAfterSlowFailureCompletes
{
  uint64_t attemptStartedAtMs = 1000;
  uint64_t failureCompletedAtMs = 6000;
  uint64_t deadlineMs = FBBroadcastReconfigureRetryDeadlineMs(failureCompletedAtMs, 1);

  XCTAssertEqual(deadlineMs, (uint64_t)6250);
  XCTAssertLessThan(attemptStartedAtMs + FBBroadcastReconfigureRetryDelayMs(1), deadlineMs);
  XCTAssertLessThan(failureCompletedAtMs, deadlineMs);
}

// A large timestamp must survive the flag bits untouched (and vice versa).
- (void)testPtsAndFlagsDoNotCollide
{
  uint64_t bigPts = ((uint64_t)1 << 62) - 1; // largest value that fits in the 62-bit PTS field
  NSData *au = [@"x" dataUsingEncoding:NSUTF8StringEncoding];
  NSData *packet = FBScrcpyPacketCreate(au, kFlagKeyFrame, bigPts);

  BOOL isConfig = YES, isKeyFrame = NO;
  uint64_t pts = 0;
  NSData *payload = nil;
  [self parsePacket:packet isConfig:&isConfig isKeyFrame:&isKeyFrame ptsUs:&pts payload:&payload];

  XCTAssertFalse(isConfig);
  XCTAssertTrue(isKeyFrame);
  XCTAssertEqual(pts, bigPts);
}

- (void)testDefaultPixelBudgetForLegacyIPhones
{
  XCTAssertEqual([FBScreenCaptureConfiguration fb_defaultPixelBudgetForMachineModel:@"iPhone11,2"], (NSUInteger)370944);
  XCTAssertEqual([FBScreenCaptureConfiguration fb_defaultPixelBudgetForMachineModel:@"iPhone11,8"], (NSUInteger)370944);
  XCTAssertEqual([FBScreenCaptureConfiguration fb_defaultPixelBudgetForMachineModel:@"iPhone9,1"], (NSUInteger)370944);
}

- (void)testDefaultPixelBudgetForModernOrUnknownModels
{
  XCTAssertEqual([FBScreenCaptureConfiguration fb_defaultPixelBudgetForMachineModel:@"iPhone12,1"], (NSUInteger)0);
  XCTAssertEqual([FBScreenCaptureConfiguration fb_defaultPixelBudgetForMachineModel:@"iPhone17,3"], (NSUInteger)0);
  XCTAssertEqual([FBScreenCaptureConfiguration fb_defaultPixelBudgetForMachineModel:@"iPad8,1"], (NSUInteger)0);
  XCTAssertEqual([FBScreenCaptureConfiguration fb_defaultPixelBudgetForMachineModel:@"AppleTV11,1"], (NSUInteger)0);
  XCTAssertEqual([FBScreenCaptureConfiguration fb_defaultPixelBudgetForMachineModel:@""], (NSUInteger)0);
  XCTAssertEqual([FBScreenCaptureConfiguration fb_defaultPixelBudgetForMachineModel:@"iPhoneX"], (NSUInteger)0);
}

- (void)testPixelBudgetClampPreservesAspectAndAlignment
{
  CGSize capped = [FBScreenCaptureConfiguration fb_sizeForWidth:562 height:1218 pixelBudget:370944];
  XCTAssertLessThanOrEqual(capped.width * capped.height, 370944.0);
  XCTAssertEqualWithAccuracy(capped.width / capped.height, 562.0 / 1218.0, 0.02);
  XCTAssertEqual(((NSUInteger)capped.width) % 2, (NSUInteger)0);
  XCTAssertEqual(((NSUInteger)capped.height) % 2, (NSUInteger)0);
  XCTAssertGreaterThan(capped.width, 0.0);
}

- (void)testPixelBudgetLeavesSizesWithinBudgetAlone
{
  CGSize size = [FBScreenCaptureConfiguration fb_sizeForWidth:414 height:896 pixelBudget:370944];
  XCTAssertEqual(size.width, 414.0);
  XCTAssertEqual(size.height, 896.0);
}

- (void)testZeroPixelBudgetDisablesClamp
{
  CGSize size = [FBScreenCaptureConfiguration fb_sizeForWidth:5000 height:5000 pixelBudget:0];
  XCTAssertEqual(size.width, 5000.0);
  XCTAssertEqual(size.height, 5000.0);
}

- (void)testMachineModelIsNonNil
{
  XCTAssertNotNil([FBScreenCaptureConfiguration fb_machineModel]);
}

- (void)testPixelBudgetClampSurvivesHugeDimensions
{
  NSUInteger huge = (NSUInteger)1 << 32;
  CGSize capped = [FBScreenCaptureConfiguration fb_sizeForWidth:huge height:huge pixelBudget:370944];
  XCTAssertLessThanOrEqual(capped.width * capped.height, 370944.0);
  XCTAssertGreaterThan(capped.width, 0.0);
}

- (void)testPixelBudgetClampHonorsBudgetForSkinnyDimensions
{
  CGSize capped = [FBScreenCaptureConfiguration fb_sizeForWidth:10000 height:2 pixelBudget:100];
  XCTAssertLessThanOrEqual(capped.width * capped.height, 100.0);
  XCTAssertGreaterThanOrEqual(capped.width, 2.0);
  XCTAssertGreaterThanOrEqual(capped.height, 2.0);
}

- (void)testPixelBudgetClampAtMinimumBudget
{
  CGSize capped = [FBScreenCaptureConfiguration fb_sizeForWidth:5000 height:5000 pixelBudget:4];
  XCTAssertEqual(capped.width, 2.0);
  XCTAssertEqual(capped.height, 2.0);
}

- (void)testPixelBudgetArgumentParsing
{
  NSUInteger budget = 99;
  XCTAssertTrue([FBScreenCaptureConfiguration fb_pixelBudget:&budget fromArgument:nil deviceDefault:370944]);
  XCTAssertEqual(budget, (NSUInteger)370944);
  XCTAssertTrue([FBScreenCaptureConfiguration fb_pixelBudget:&budget fromArgument:@0 deviceDefault:370944]);
  XCTAssertEqual(budget, (NSUInteger)0);
  XCTAssertTrue([FBScreenCaptureConfiguration fb_pixelBudget:&budget fromArgument:@4 deviceDefault:0]);
  XCTAssertEqual(budget, (NSUInteger)4);
  XCTAssertTrue([FBScreenCaptureConfiguration fb_pixelBudget:&budget fromArgument:@370944.0 deviceDefault:0]);
  XCTAssertEqual(budget, (NSUInteger)370944);
}

- (void)testPixelBudgetArgumentParsingRejectsMalformedValues
{
  NSUInteger budget = 0;
  XCTAssertFalse([FBScreenCaptureConfiguration fb_pixelBudget:&budget fromArgument:@"370944" deviceDefault:0]);
  XCTAssertFalse([FBScreenCaptureConfiguration fb_pixelBudget:&budget fromArgument:@(-1) deviceDefault:0]);
  XCTAssertFalse([FBScreenCaptureConfiguration fb_pixelBudget:&budget fromArgument:@(0.5) deviceDefault:0]);
  XCTAssertFalse([FBScreenCaptureConfiguration fb_pixelBudget:&budget fromArgument:@(-0.5) deviceDefault:0]);
  XCTAssertFalse([FBScreenCaptureConfiguration fb_pixelBudget:&budget fromArgument:@(2) deviceDefault:0]);
  XCTAssertFalse([FBScreenCaptureConfiguration fb_pixelBudget:&budget fromArgument:@(NAN) deviceDefault:0]);
  XCTAssertFalse([FBScreenCaptureConfiguration fb_pixelBudget:&budget fromArgument:@(INFINITY) deviceDefault:0]);
  // (double)NSUIntegerMax rounds up to exactly 2^64, which does not fit in NSUInteger; the
  // parser must reject it, not cast it (undefined behavior).
  XCTAssertFalse([FBScreenCaptureConfiguration fb_pixelBudget:&budget fromArgument:@((double)NSUIntegerMax) deviceDefault:0]);
  XCTAssertFalse([FBScreenCaptureConfiguration fb_pixelBudget:&budget fromArgument:@(0x1p64) deviceDefault:0]);
}

@end
