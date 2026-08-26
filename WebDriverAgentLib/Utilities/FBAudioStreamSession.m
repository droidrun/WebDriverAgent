/**
 * Copyright (c) 2026-present, Droidrun.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBAudioStreamSession.h"

#import <mach/mach_time.h>

#import "FBBroadcastProtocol.h"
#import "FBLogger.h"
#import "FBScrcpyPacket.h"
#import "FBTCPSocket.h"

static const NSUInteger FBAudioStreamSampleRate = 48000;
// Smallest per-client send backlog tolerated regardless of the configured bitrate.
static const NSUInteger FBAudioMinPendingBytes = 64 * 1024;

@implementation FBAudioCaptureConfiguration
@end


@interface FBAudioStreamSession () <FBTCPSocketDelegate>

@property (nonatomic) NSMutableArray<nw_connection_t> *listeningClients;
/**
 Bytes handed to the socket per client that have not finished sending. nw_connection_send buffers
 without any backpressure signal, so a client that stops draining is disconnected once its backlog
 exceeds roughly a second of stream - the same outcome the previous GCDAsyncSocket write timeout
 produced. Opus packets are not independently decodable, so dropping them (as the MJPEG server
 does with whole frames) would corrupt the stream rather than degrade it.
 Guarded by @synchronized (self.listeningClients).
 */
@property (nonatomic) NSMapTable<id, NSNumber *> *pendingBytesByClient;
@property (nonatomic, nullable) FBTCPSocket *broadcaster;
@property (atomic, getter=isActive) BOOL active;
/** The OpusHead describing the stream; the extension's real one replaces the synthesized fallback. */
@property (atomic, copy) NSData *currentOpusHead;
/** The OpusHead most recently broadcast as a scrcpy config packet (for change detection). */
@property (nonatomic, nullable, copy) NSData *lastSentOpusHead;
@property (atomic) BOOL streaming;
@property (atomic) uint64_t packetsReceived;
@property (atomic) uint64_t lastPacketAtMs;
@property (atomic, nullable, copy) NSString *lastError;

@end


@implementation FBAudioStreamSession

- (instancetype)initWithIdentifier:(NSUInteger)identifier
                     configuration:(FBAudioCaptureConfiguration *)configuration
{
  if ((self = [super init])) {
    _identifier = identifier;
    _configuration = configuration;
    _listeningClients = [NSMutableArray array];
    _pendingBytesByClient = [NSMapTable mapTableWithKeyOptions:(NSPointerFunctionsOptions)(NSMapTableObjectPointerPersonality | NSMapTableStrongMemory)
                                                  valueOptions:(NSPointerFunctionsOptions)NSMapTableStrongMemory];
    _active = NO;
    _streaming = NO;
    // A synthesized header (pre-skip 0) so scrcpy-framing clients always receive a config packet
    // on connect; the extension's AUDIO_PARAMS replaces it with the encoder's real values.
    _currentOpusHead = FBBroadcastCreateOpusHead((uint8_t)configuration.channels,
                                                 0,
                                                 (uint32_t)FBAudioStreamSampleRate);
  }
  return self;
}

- (BOOL)startWithError:(NSError **)error
{
  self.broadcaster = [[FBTCPSocket alloc] initWithPort:self.configuration.port];
  self.broadcaster.delegate = self;
  // Send small Opus packets immediately instead of letting Nagle coalesce them.
  self.broadcaster.noDelay = YES;
  if (![self.broadcaster startWithError:error]) {
    self.broadcaster = nil;
    return NO;
  }
  self.active = YES;
  return YES;
}

- (void)stop
{
  @synchronized (self) {
    self.active = NO;
    self.streaming = NO;
    if (nil != self.broadcaster) {
      self.broadcaster.delegate = nil;
      [self.broadcaster stop];
      self.broadcaster = nil;
    }
    @synchronized (self.listeningClients) {
      [self.listeningClients removeAllObjects];
      [self.pendingBytesByClient removeAllObjects];
    }
  }
}

- (BOOL)hasClients
{
  @synchronized (self.listeningClients) {
    return self.listeningClients.count > 0;
  }
}

#pragma mark - Broadcast (ReplayKit) source

- (void)ingestBroadcastOpusHead:(NSData *)opusHead
{
  if (opusHead.length == 0) {
    return;
  }
  self.currentOpusHead = opusHead;
  self.lastError = nil;
}

- (void)ingestBroadcastPacket:(NSData *)opusPacket ptsUs:(uint64_t)ptsUs
{
  if (!self.isActive || opusPacket.length == 0) {
    return;
  }
  self.streaming = YES;
  self.packetsReceived += 1;
  self.lastPacketAtMs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / NSEC_PER_MSEC;

  if (self.configuration.framing == FBAudioFramingScrcpy) {
    // Re-broadcast the codec configuration whenever it changed. Like scrcpy itself, config
    // packets carry only the config flag (zero pts) and data packets carry only the pts.
    NSData *opusHead = self.currentOpusHead;
    @synchronized (self) {
      if (nil == self.lastSentOpusHead || ![opusHead isEqualToData:(NSData *)self.lastSentOpusHead]) {
        self.lastSentOpusHead = opusHead;
        [self broadcastData:FBScrcpyPacketCreate(opusHead, FBScrcpyFlagConfig, 0)];
      }
    }
    [self broadcastData:FBScrcpyPacketCreate(opusPacket, 0, ptsUs)];
    return;
  }
  [self broadcastData:opusPacket];
}

- (void)detachBroadcastSource
{
  self.streaming = NO;
}

- (void)markBroadcastError:(NSString *)message
{
  self.streaming = NO;
  self.lastError = message;
}

// Roughly one second of the configured stream, mirroring the write timeout the GCDAsyncSocket
// implementation used to disconnect slow clients with.
- (NSUInteger)maxPendingBytesPerClient
{
  return MAX(self.configuration.bitrate / 8, FBAudioMinPendingBytes);
}

// Caller must hold @synchronized (self.listeningClients).
- (void)sendData:(NSData *)data toClient:(nw_connection_t)client
{
  NSUInteger pending = [self.pendingBytesByClient objectForKey:client].unsignedIntegerValue;
  if (pending > self.maxPendingBytesPerClient) {
    [FBLogger logFmt:@"Audio capture session %@: dropping a client that is not draining its socket (%@ bytes pending)",
     @(self.identifier), @(pending)];
    [self.listeningClients removeObject:client];
    [self.pendingBytesByClient removeObjectForKey:client];
    // -didClientDisconnect: follows from the cancellation and cleans up anything left.
    nw_connection_cancel(client);
    return;
  }
  [self.pendingBytesByClient setObject:@(pending + data.length) forKey:client];
  NSUInteger sentLength = data.length;
  __weak typeof(self) weakSelf = self;
  [self.broadcaster writeData:data toClient:client completion:^(BOOL didSucceed) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (nil == strongSelf) {
      return;
    }
    @synchronized (strongSelf.listeningClients) {
      NSUInteger stillPending = [strongSelf.pendingBytesByClient objectForKey:client].unsignedIntegerValue;
      if (stillPending > sentLength) {
        [strongSelf.pendingBytesByClient setObject:@(stillPending - sentLength) forKey:client];
      } else {
        [strongSelf.pendingBytesByClient removeObjectForKey:client];
      }
    }
  }];
}

- (void)broadcastData:(NSData *)data
{
  if (data.length == 0) {
    return;
  }
  @synchronized (self.listeningClients) {
    // Copied because -sendData:toClient: can remove a stalled client from the array.
    for (nw_connection_t client in self.listeningClients.copy) {
      [self sendData:data toClient:client];
    }
  }
}

#pragma mark - <FBTCPSocketDelegate>

- (void)didClientConnect:(nw_connection_t)newClient
{
  [FBLogger logFmt:@"Audio capture session %@: client connected", @(self.identifier)];
  @synchronized (self.listeningClients) {
    if (![self.listeningClients containsObject:newClient]) {
      [self.listeningClients addObject:newClient];
    }
    // Hand the codec configuration to the new client so it can start decoding immediately.
    // lastSentOpusHead is deliberately not updated: it tracks what was broadcast to the whole
    // client set, and marking it sent here would skip the changed-config broadcast that earlier
    // clients still need (the new client just receives the same config twice, which is harmless).
    if (self.configuration.framing == FBAudioFramingScrcpy) {
      [self sendData:FBScrcpyPacketCreate(self.currentOpusHead, FBScrcpyFlagConfig, 0) toClient:newClient];
    }
  }
}

- (void)client:(nw_connection_t)client didReceiveData:(NSData *)data
{
  // The stream is push-only; client payloads are ignored. FBTCPSocket keeps the receive loop
  // running on its own, which is what surfaces disconnects.
}

- (void)didClientDisconnect:(nw_connection_t)client
{
  @synchronized (self.listeningClients) {
    [self.listeningClients removeObject:client];
    [self.pendingBytesByClient removeObjectForKey:client];
  }
  [FBLogger logFmt:@"Audio capture session %@: client disconnected", @(self.identifier)];
}

#pragma mark - Status

- (NSDictionary *)toDictionary
{
  NSUInteger clientCount;
  @synchronized (self.listeningClients) {
    clientCount = self.listeningClients.count;
  }
  uint64_t lastPacketAtMs = self.lastPacketAtMs;
  NSString *lastError = self.lastError;
  return @{
    @"id": @(self.identifier),
    @"codec": FBBroadcastCodecOpus,
    @"framing": self.configuration.framing == FBAudioFramingScrcpy ? @"scrcpy" : @"raw",
    @"sampleRate": @(FBAudioStreamSampleRate),
    @"channels": @(self.configuration.channels),
    @"bitrate": @(self.configuration.bitrate),
    @"port": @(self.configuration.port),
    @"clients": @(clientCount),
    @"streaming": @(self.streaming),
    @"source": self.streaming ? @"replaykit" : @"none",
    @"packetsReceived": @(self.packetsReceived),
    @"lastPacketAtMs": lastPacketAtMs > 0 ? @(lastPacketAtMs) : NSNull.null,
    @"lastError": lastError ?: NSNull.null,
  };
}

@end
