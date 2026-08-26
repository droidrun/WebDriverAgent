/**
 * Copyright (c) 2026-present, Droidrun.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#import "FBVideoEncoder.h"

NS_ASSUME_NONNULL_BEGIN

/** The framing used for the broadcast byte stream. */
typedef NS_ENUM(NSUInteger, FBVideoFraming) {
  /** Raw Annex-B elementary stream (default): bare NAL units, parameter sets prepended to key frames. */
  FBVideoFramingAnnexB,
  /** scrcpy packet framing: each access unit wrapped as [8B pts+flags][4B size][Annex-B AU]. */
  FBVideoFramingScrcpy,
};

/** The origin of the encoded frames a session is currently serving. */
typedef NS_ENUM(NSUInteger, FBVideoStreamSource) {
  /** Frames are captured via XCTest screenshots and encoded locally (default). */
  FBVideoStreamSourceScreenshot,
  /** Pre-encoded frames are received from the ReplayKit broadcast extension. */
  FBVideoStreamSourceBroadcast,
};

/** Describes a single screen-capture streaming request. */
@interface FBScreenCaptureConfiguration : NSObject

/** The video codec to encode with. */
@property (nonatomic) FBVideoCodec codec;
/** The encoded frame width in pixels. */
@property (nonatomic) NSUInteger width;
/** The encoded frame height in pixels. */
@property (nonatomic) NSUInteger height;
/** The target average bitrate in bits per second. */
@property (nonatomic) NSUInteger bitrate;
/** JPEG compression quality used when capturing XCTest screenshot frames before video encoding. */
@property (nonatomic) CGFloat quality;
/** The capture/encode framerate in frames per second. */
@property (nonatomic) NSUInteger fps;
/** The framing of the broadcast byte stream (raw Annex-B by default). */
@property (nonatomic) FBVideoFraming framing;
/** The TCP port the encoded stream is broadcast on. */
@property (nonatomic) uint16_t port;

/**
 The raw device model identifier (e.g. 'iPhone11,2'), resolved via sysctl. On the simulator the
 simulated device's identifier is returned instead of the host architecture.
 */
+ (NSString *)fb_machineModel;

/**
 The pixel budget (maximum width*height) that is safe for sustained capture on the given device
 model, or 0 when the model has no default cap.
 */
+ (NSUInteger)fb_defaultPixelBudgetForMachineModel:(NSString *)machineModel;

/**
 Scales width/height down (aspect-preserving, rounded down to even values) until
 width*height <= budget. A budget of 0, a size already within budget, or a degenerate size is
 returned unchanged. For budgets >= 4 the returned size never exceeds the budget; the aspect
 ratio may be sacrificed for extreme aspect inputs where the minimum encodable size (2x2) would
 otherwise push the product back over budget. Budgets 1..3 cannot be honored (2x2 = 4 is the
 minimum encodable size) and are rejected at the API boundary before this method is called.
 */
+ (CGSize)fb_sizeForWidth:(NSUInteger)width height:(NSUInteger)height pixelBudget:(NSUInteger)budget;

/**
 Parses the optional 'maxPixels' request argument into a pixel budget.

 @param outBudget On success: the parsed budget (0 = uncapped); the device default when the
                  argument is absent.
 @param maxPixels The raw request argument (nil when absent).
 @param deviceDefault The device-class default budget applied when the argument is absent.
 @return NO when the argument is present but is not a finite, non-negative, integral number
         equal to 0 or of at least 4 (2x2 = 4 is the minimum encodable size).
 */
+ (BOOL)fb_pixelBudget:(NSUInteger *)outBudget fromArgument:(nullable id)maxPixels deviceDefault:(NSUInteger)deviceDefault;

@end

/**
 A single, independently controllable screen-capture stream: one encoder, one TCP broadcaster
 and its own set of clients, identified by a numeric id. Sessions are driven by a shared capture
 loop (see FBVideoStreamManager) that grabs and decodes each screen frame once and fans it out to
 every active session, so multiple codecs/resolutions can be produced from a single capture.
 */
@interface FBVideoStreamSession : NSObject

/** The session identifier assigned by the manager. */
@property (nonatomic, readonly) NSUInteger identifier;
/** The configuration this session was started with. */
@property (nonatomic, readonly) FBScreenCaptureConfiguration *configuration;
/** The origin of the frames this session currently serves. */
@property (atomic, readonly) FBVideoStreamSource activeSource;
/**
 Invoked (with the session identifier) when a key frame is needed while the session serves
 broadcast frames, so the request can be forwarded to the extension's encoder.
 */
@property (nonatomic, nullable, copy) void (^onBroadcastKeyFrameNeeded)(NSUInteger sessionIdentifier);

- (instancetype)initWithIdentifier:(NSUInteger)identifier
                     configuration:(FBScreenCaptureConfiguration *)configuration;

- (instancetype)init NS_UNAVAILABLE;

/**
 Binds the broadcast socket and creates the encoder.

 @param error If there is an error, upon return contains an NSError describing the problem
 @return NO in case of a failure (e.g. the port is in use or the encoder cannot be created)
 */
- (BOOL)startWithError:(NSError **)error;

/** Tears the session down and disconnects its clients. */
- (void)stop;

/** YES if at least one client is currently connected to this session. */
- (BOOL)hasClients;

/** Forces the encoder to emit a key frame as soon as possible. */
- (void)requestKeyFrame;

/**
 Encodes the given (already decoded) screen image if this session has clients and is due for a
 new frame according to its configured framerate. The image is shared across sessions, so this
 method must not mutate it.

 @param image The decoded screen image
 @param nowMs A monotonic timestamp in milliseconds
 */
- (void)maybeEncodeCGImage:(CGImageRef)image atTimeMs:(uint64_t)nowMs;

/**
 YES while this session needs frames from the shared screenshot capture loop, i.e. it is active,
 has at least one client and is not being fed by the broadcast extension.
 */
- (BOOL)requiresLocalFrames;

/** Stores fresh Annex-B parameter sets received from the broadcast extension. */
- (void)ingestBroadcastParameterSets:(NSData *)parameterSets;

/**
 Broadcasts a pre-encoded picture received from the broadcast extension. While the session is
 still on the screenshot source it switches to the broadcast source on the first key frame that
 has parameter sets available (delta frames before that are dropped, so clients always resync
 at an IDR).
 */
- (void)ingestBroadcastFrame:(NSData *)annexBPictureData isKeyFrame:(BOOL)isKeyFrame;

/**
 Reverts the session to the local screenshot source (e.g. because the broadcast stopped) and
 forces the local encoder to open with a key frame so clients can resync without reconnecting.
 */
- (void)detachBroadcastSourceAndForceKeyFrame;

/** @return A dictionary describing this session. */
- (NSDictionary *)toDictionary;

@end

NS_ASSUME_NONNULL_END
