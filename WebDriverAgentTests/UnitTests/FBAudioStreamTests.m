/**
 * Copyright (c) 2026-present, Droidrun.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <XCTest/XCTest.h>

#import <AudioToolbox/AudioToolbox.h>
#import <arpa/inet.h>
#import <sys/socket.h>
#import <unistd.h>

#import "FBAudioStreamSession.h"
#import "FBBroadcastProtocol.h"

typedef struct {
  const float *samples;
  UInt32 totalFrames;
  UInt32 framesProvided;
  UInt32 channels;
} FBAudioStreamTestsFeedState;

static OSStatus FBAudioStreamTestsFeed(AudioConverterRef inConverter,
                                       UInt32 *ioNumberDataPackets,
                                       AudioBufferList *ioData,
                                       AudioStreamPacketDescription **outDescription,
                                       void *inUserData)
{
  FBAudioStreamTestsFeedState *state = (FBAudioStreamTestsFeedState *)inUserData;
  UInt32 available = state->totalFrames - state->framesProvided;
  if (available == 0) {
    *ioNumberDataPackets = 0;
    return 1; // out of data
  }
  UInt32 provide = MIN(*ioNumberDataPackets, available);
  ioData->mNumberBuffers = 1;
  ioData->mBuffers[0].mNumberChannels = state->channels;
  ioData->mBuffers[0].mData = (void *)(state->samples + (size_t)state->framesProvided * state->channels);
  ioData->mBuffers[0].mDataByteSize = provide * state->channels * sizeof(float);
  state->framesProvided += provide;
  *ioNumberDataPackets = provide;
  return noErr;
}

@interface FBAudioStreamTests : XCTestCase
@end

@implementation FBAudioStreamTests

// The OpusHead for mono/pre-skip 312/48 kHz must match the reference bytes documented in
// scrcpy's Streamer.fixOpusConfigPacket (the part it extracts as decoder extradata).
- (void)testOpusHeadMatchesScrcpyReferenceBytes
{
  const uint8_t expected[19] = {
    0x4F, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61, 0x64, // "OpusHead"
    0x01,                                           // version
    0x01,                                           // channels
    0x38, 0x01,                                     // pre-skip 312 (LE)
    0x80, 0xBB, 0x00, 0x00,                         // input sample rate 48000 (LE)
    0x00, 0x00,                                     // output gain
    0x00,                                           // mapping family
  };
  NSData *head = FBBroadcastCreateOpusHead(1, 312, 48000);
  XCTAssertEqualObjects(head, [NSData dataWithBytes:expected length:sizeof(expected)]);
}

- (void)testOpusHeadFieldPlacement
{
  NSData *head = FBBroadcastCreateOpusHead(2, 0x0102, 44100);
  XCTAssertEqual(head.length, 19u);
  const uint8_t *bytes = (const uint8_t *)head.bytes;
  XCTAssertEqual(0, memcmp(bytes, "OpusHead", 8));
  XCTAssertEqual(bytes[8], 1);
  XCTAssertEqual(bytes[9], 2);
  // Little-endian fields.
  XCTAssertEqual(bytes[10], 0x02);
  XCTAssertEqual(bytes[11], 0x01);
  XCTAssertEqual(bytes[12], 0x44); // 44100 = 0x0000AC44
  XCTAssertEqual(bytes[13], 0xAC);
  XCTAssertEqual(bytes[14], 0x00);
  XCTAssertEqual(bytes[15], 0x00);
  XCTAssertEqual(bytes[18], 0);
}

- (void)testAudioFrameMessageRoundTrip
{
  NSData *packet = [@"opus-packet-bytes" dataUsingEncoding:NSUTF8StringEncoding];
  uint32_t sessionId = 3 | FBBroadcastAudioSessionIdFlag;
  NSData *message = FBBroadcastEncodeAudioFrameMessage(sessionId, 1234567, packet);

  FBBroadcastMessageHeader header;
  XCTAssertTrue(FBBroadcastParseHeader([message subdataWithRange:NSMakeRange(0, FBBroadcastHeaderLength)], &header));
  XCTAssertEqual(header.type, FBBroadcastMessageTypeAudioFrame);
  XCTAssertEqual(header.sessionId, sessionId);
  XCTAssertEqual(header.payloadLength, message.length - FBBroadcastHeaderLength);

  NSData *payload = [message subdataWithRange:NSMakeRange(FBBroadcastHeaderLength, header.payloadLength)];
  uint64_t ptsUs = 0;
  NSData *parsedPacket = nil;
  XCTAssertTrue(FBBroadcastParseAudioFramePayload(payload, &ptsUs, &parsedPacket));
  XCTAssertEqual(ptsUs, 1234567u);
  XCTAssertEqualObjects(parsedPacket, packet);
}

- (void)testAudioFramePayloadTooShortIsRejected
{
  uint64_t ptsUs = 0;
  NSData *packet = nil;
  XCTAssertFalse(FBBroadcastParseAudioFramePayload([NSData dataWithBytes:"short" length:5], &ptsUs, &packet));
}

- (void)testAudioSessionIdFlagDoesNotClipIdentifiers
{
  uint32_t wireId = (uint32_t)7 | FBBroadcastAudioSessionIdFlag;
  XCTAssertTrue(wireId & FBBroadcastAudioSessionIdFlag);
  XCTAssertEqual(wireId & ~FBBroadcastAudioSessionIdFlag, 7u);
}

// Drives the same AudioConverter configuration FBExtAudioPipeline uses, so an OS/SDK losing
// kAudioFormatOpus encode support fails loudly here instead of silently on a device.
- (void)testOpusEncoderProducesPackets
{
  const UInt32 sampleRate = 48000;
  const UInt32 channels = 2;

  AudioStreamBasicDescription inFormat = {0};
  inFormat.mSampleRate = sampleRate;
  inFormat.mFormatID = kAudioFormatLinearPCM;
  inFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
  inFormat.mChannelsPerFrame = channels;
  inFormat.mBitsPerChannel = 32;
  inFormat.mBytesPerFrame = channels * sizeof(float);
  inFormat.mFramesPerPacket = 1;
  inFormat.mBytesPerPacket = inFormat.mBytesPerFrame;

  AudioStreamBasicDescription outFormat = {0};
  outFormat.mSampleRate = sampleRate;
  outFormat.mFormatID = kAudioFormatOpus;
  outFormat.mChannelsPerFrame = channels;
  outFormat.mFramesPerPacket = 960;

  AudioConverterRef converter = NULL;
  OSStatus status = AudioConverterNew(&inFormat, &outFormat, &converter);
  XCTAssertEqual(status, noErr, @"kAudioFormatOpus encoding is unavailable");
  if (status != noErr) {
    return;
  }

  NSMutableData *pcm = [NSMutableData dataWithLength:sampleRate * channels * sizeof(float)];
  float *samples = (float *)pcm.mutableBytes;
  for (UInt32 i = 0; i < sampleRate; i++) {
    float value = sinf(2.0f * (float)M_PI * 440.0f * (float)i / (float)sampleRate) * 0.5f;
    samples[i * channels] = value;
    samples[i * channels + 1] = value;
  }
  FBAudioStreamTestsFeedState state = { samples, sampleRate, 0, channels };

  NSMutableData *packetBuffer = [NSMutableData dataWithLength:1500];
  NSUInteger packets = 0;
  for (;;) {
    AudioBufferList outList = {0};
    outList.mNumberBuffers = 1;
    outList.mBuffers[0].mNumberChannels = channels;
    outList.mBuffers[0].mData = packetBuffer.mutableBytes;
    outList.mBuffers[0].mDataByteSize = (UInt32)packetBuffer.length;
    AudioStreamPacketDescription description = {0};
    UInt32 packetCount = 1;
    status = AudioConverterFillComplexBuffer(converter, FBAudioStreamTestsFeed, &state,
                                             &packetCount, &outList, &description);
    if (packetCount == 0) {
      break;
    }
    packets += 1;
    XCTAssertGreaterThan(description.mDataByteSize > 0 ? description.mDataByteSize : outList.mBuffers[0].mDataByteSize, 0u);
    if (status != noErr) {
      break;
    }
  }
  AudioConverterDispose(converter);
  // 48000 frames at 960 frames per packet.
  XCTAssertEqualWithAccuracy((double)packets, 50.0, 2.0);
}

@end


// End-to-end coverage of the broadcast socket itself, over a real TCP connection. The packet
// builders are unit-tested above; what these pin down is the delivery path - that a connecting
// client is handed the codec config before anything else and that payloads reach the wire with
// their scrcpy framing intact. The consuming client (mobilerun-ios) parses exactly this and
// treats a zero-length or misframed packet as a fatal stream error, so the byte layout below is
// a contract, not an implementation detail.
@interface FBAudioStreamSocketTests : XCTestCase
@property (nonatomic) FBAudioStreamSession *session;
@property (nonatomic) int clientFD;
@end

@implementation FBAudioStreamSocketTests

- (void)setUp
{
  [super setUp];
  self.clientFD = -1;
  FBAudioCaptureConfiguration *configuration = [FBAudioCaptureConfiguration new];
  configuration.bitrate = 64000;
  configuration.channels = 1;
  configuration.framing = FBAudioFramingScrcpy;
  configuration.port = 0; // let the system assign one
  self.session = [[FBAudioStreamSession alloc] initWithIdentifier:1 configuration:configuration];
  NSError *error;
  XCTAssertTrue([self.session startWithError:&error], @"%@", error);
}

- (void)tearDown
{
  if (self.clientFD >= 0) {
    close(self.clientFD);
    self.clientFD = -1;
  }
  [self.session stop];
  self.session = nil;
  [super tearDown];
}

- (uint16_t)listeningPort
{
  return [[self.session valueForKeyPath:@"broadcaster.port"] unsignedShortValue];
}

- (BOOL)connectClient
{
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) {
    return NO;
  }
  struct timeval tv = { .tv_sec = 5, .tv_usec = 0 };
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
  struct sockaddr_in addr = { .sin_family = AF_INET, .sin_port = htons(self.listeningPort) };
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (0 != connect(fd, (struct sockaddr *)&addr, sizeof(addr))) {
    close(fd);
    return NO;
  }
  self.clientFD = fd;
  return YES;
}

// Reads exactly `length` bytes, or returns nil once the deadline passes.
- (NSData *)readExactly:(NSUInteger)length
{
  NSMutableData *received = [NSMutableData data];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
  while (received.length < length && deadline.timeIntervalSinceNow > 0) {
    uint8_t chunk[4096];
    ssize_t n = recv(self.clientFD, chunk, MIN(sizeof(chunk), length - received.length), 0);
    if (n <= 0) {
      break;
    }
    [received appendBytes:chunk length:(NSUInteger)n];
  }
  return received.length == length ? received : nil;
}

// Reads one scrcpy packet: [8B flags|pts][4B size][size B payload].
- (BOOL)readPacketWithMeta:(uint64_t *)outMeta payload:(NSData **)outPayload
{
  NSData *header = [self readExactly:12];
  if (nil == header) {
    return NO;
  }
  uint64_t meta = CFSwapInt64BigToHost(*(const uint64_t *)header.bytes);
  uint32_t size = CFSwapInt32BigToHost(*(const uint32_t *)((const uint8_t *)header.bytes + 8));
  // A zero-length packet is a fatal parse error for the client - it must never be emitted.
  if (0 == size) {
    XCTFail(@"the server emitted a zero-length packet");
    return NO;
  }
  NSData *payload = [self readExactly:size];
  if (nil == payload) {
    return NO;
  }
  *outMeta = meta;
  *outPayload = payload;
  return YES;
}

- (void)testConnectingClientReceivesOpusHeadConfigFirst
{
  XCTAssertTrue([self connectClient]);

  uint64_t meta = 0;
  NSData *payload = nil;
  XCTAssertTrue([self readPacketWithMeta:&meta payload:&payload], @"no config packet arrived");
  // Bit 63 marks config; bit 62 (key frame) must not be set on the same packet, since the client
  // classifies config and key exclusively and never forwards a config packet.
  XCTAssertTrue((meta & (1ULL << 63)) != 0, @"the first packet must be flagged as config");
  XCTAssertTrue((meta & (1ULL << 62)) == 0, @"config packets must not also carry the key flag");
  XCTAssertEqual(meta & ((1ULL << 62) - 1), 0ULL, @"config packets carry a zero pts");
  // OpusHead magic, as produced by FBBroadcastCreateOpusHead.
  XCTAssertGreaterThanOrEqual(payload.length, (NSUInteger)8);
  XCTAssertEqualObjects([payload subdataWithRange:NSMakeRange(0, 8)],
                        [@"OpusHead" dataUsingEncoding:NSASCIIStringEncoding]);
}

- (void)testIngestedPacketReachesTheClientWithItsPtsAndNoFlags
{
  XCTAssertTrue([self connectClient]);

  uint64_t meta = 0;
  NSData *payload = nil;
  XCTAssertTrue([self readPacketWithMeta:&meta payload:&payload], @"no config packet arrived");

  uint8_t opusBytes[] = {0xF8, 0x01, 0x02, 0x03};
  NSData *opusPacket = [NSData dataWithBytes:opusBytes length:sizeof(opusBytes)];
  [self.session ingestBroadcastPacket:opusPacket ptsUs:123456];

  // Skip any further config packets, exactly as the client does: the first ingest re-broadcasts
  // the OpusHead because -didClientConnect: deliberately leaves lastSentOpusHead unset, so a
  // client that joined mid-stream still gets the config that later joiners would suppress.
  do {
    XCTAssertTrue([self readPacketWithMeta:&meta payload:&payload], @"no data packet arrived");
  } while ((meta & (1ULL << 63)) != 0);
  XCTAssertEqual(meta & ((1ULL << 62) - 1), 123456ULL, @"the pts must survive the wire");
  XCTAssertEqualObjects(payload, opusPacket);
}

@end
