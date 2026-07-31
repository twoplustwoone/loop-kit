#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, LKMicrophonePermissionStatus) {
  LKMicrophonePermissionStatusNotDetermined = 0,
  LKMicrophonePermissionStatusGranted = 1,
  LKMicrophonePermissionStatusDenied = 2,
};

@interface LKMicInputManager : NSObject

- (instancetype)initWithSampleRate:(double)engineSampleRate maxFrames:(uint32_t)maxFrames;

// Reads the current TCC decision without presenting a permission prompt.
- (LKMicrophonePermissionStatus)permissionStatus;

// Activates capture on the device with the given UID. Pass "system.default"
// (or empty) to use the current default input. Returns NO if the device isn't
// found or the AU graph fails to start — call `lastError` for detail.
- (BOOL)activateDeviceWithUID:(NSString*)deviceUID;

- (void)stop;

// Pops up to maxFrames of 48 kHz stereo audio into the caller's buffers.
// Missing samples are zero-filled. Returns the number of real frames written.
- (uint32_t)copyAudioLeft:(float*)left right:(float*)right maxFrames:(uint32_t)maxFrames;

- (NSString*)requestedDeviceUID;
- (NSString*)activeDeviceUID;
- (BOOL)isRunning;
- (double)inputDeviceSampleRate;
- (NSString*)lastError;
- (NSString*)healthWarning;
- (uint64_t)underrunCount;
- (uint64_t)overrunCount;

@end

NS_ASSUME_NONNULL_END
