#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Binds to a specific CoreAudio output device and renders a continuous
// stereo float stream into it via AUHAL. One instance per destination — the
// daemon uses one for the user's monitor output (speakers/headphones) and
// another for the Broadcast stream (BlackHole 2ch).
@interface LKAudioOutputRouter : NSObject

// `label` is a short human-readable name used as a prefix in log/error
// strings so the two instances' diagnostics don't collide.
- (instancetype)initWithLabel:(NSString*)label
                   sampleRate:(double)sampleRate
                    maxFrames:(uint32_t)maxFrames;

- (BOOL)activateDeviceWithUID:(NSString*)deviceUID;
- (void)stop;
- (void)enqueueLeft:(const float*)left right:(const float*)right frames:(uint32_t)frames;
- (NSString*)activeDeviceUID;
- (BOOL)isRunning;
- (NSString*)healthWarning;
- (NSString*)lastError;
- (uint64_t)overrunCount;
- (uint64_t)underrunCount;
- (double)deviceSampleRate;

@end

// Transitional typealias so any in-flight references to the old name still
// compile. Remove after one release cycle.
@compatibility_alias LKMonitorOutputManager LKAudioOutputRouter;

NS_ASSUME_NONNULL_END
