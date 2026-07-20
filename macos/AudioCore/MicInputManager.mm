#import "MicInputManager.h"

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/AudioHardware.h>

#include "loopkit_resampler.h"

#include <atomic>
#include <chrono>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace {

constexpr double kEngineSampleRate = 48000.0;
constexpr uint32_t kResamplerRingFrames = 16384;
constexpr uint64_t kConfigNotificationSuppressionNanos = 1'000'000'000;
constexpr int64_t kConfigRecoveryDebounceNanos = 250'000'000;

uint64_t monotonicNanos() {
  return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
      std::chrono::steady_clock::now().time_since_epoch()).count());
}

NSString* statusDescription(OSStatus status) {
  return [NSString stringWithFormat:@"OSStatus %d (0x%08X)",
                                     static_cast<int32_t>(status),
                                     static_cast<uint32_t>(status)];
}

bool findInputDeviceIDByUID(NSString* uid, AudioDeviceID* outID) {
  if (outID == nullptr) {
    return false;
  }
  AudioObjectPropertyAddress listAddress{
      .mSelector = kAudioHardwarePropertyDevices,
      .mScope = kAudioObjectPropertyScopeGlobal,
      .mElement = kAudioObjectPropertyElementMain,
  };
  const AudioObjectID system = kAudioObjectSystemObject;
  UInt32 size = 0;
  if (AudioObjectGetPropertyDataSize(system, &listAddress, 0, nullptr, &size) != noErr || size == 0) {
    return false;
  }
  std::vector<AudioDeviceID> ids(size / sizeof(AudioDeviceID));
  if (AudioObjectGetPropertyData(system, &listAddress, 0, nullptr, &size, ids.data()) != noErr) {
    return false;
  }
  for (AudioDeviceID id : ids) {
    AudioObjectPropertyAddress uidAddress{
        .mSelector = kAudioDevicePropertyDeviceUID,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };
    if (!AudioObjectHasProperty(id, &uidAddress)) continue;
    CFStringRef ref = nullptr;
    UInt32 refSize = sizeof(CFStringRef);
    if (AudioObjectGetPropertyData(id, &uidAddress, 0, nullptr, &refSize, &ref) != noErr || ref == nullptr) {
      continue;
    }
    NSString* bridged = (__bridge_transfer NSString*)ref;
    if ([bridged isEqualToString:uid]) {
      // Confirm input-scope stream exists.
      AudioObjectPropertyAddress streams{
          .mSelector = kAudioDevicePropertyStreams,
          .mScope = kAudioObjectPropertyScopeInput,
          .mElement = kAudioObjectPropertyElementMain,
      };
      if (!AudioObjectHasProperty(id, &streams)) continue;
      UInt32 ssize = 0;
      if (AudioObjectGetPropertyDataSize(id, &streams, 0, nullptr, &ssize) != noErr || ssize == 0) {
        continue;
      }
      *outID = id;
      return true;
    }
  }
  return false;
}

AudioDeviceID defaultInputDeviceID() {
  AudioObjectPropertyAddress address{
      .mSelector = kAudioHardwarePropertyDefaultInputDevice,
      .mScope = kAudioObjectPropertyScopeGlobal,
      .mElement = kAudioObjectPropertyElementMain,
  };
  AudioDeviceID id = kAudioObjectUnknown;
  UInt32 size = sizeof(id);
  if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr, &size, &id) != noErr) {
    return kAudioObjectUnknown;
  }
  return id;
}

NSString* deviceUIDForID(AudioDeviceID id) {
  if (id == kAudioObjectUnknown) return nil;
  AudioObjectPropertyAddress address{
      .mSelector = kAudioDevicePropertyDeviceUID,
      .mScope = kAudioObjectPropertyScopeGlobal,
      .mElement = kAudioObjectPropertyElementMain,
  };
  if (!AudioObjectHasProperty(id, &address)) return nil;
  CFStringRef ref = nullptr;
  UInt32 size = sizeof(CFStringRef);
  if (AudioObjectGetPropertyData(id, &address, 0, nullptr, &size, &ref) != noErr || ref == nullptr) {
    return nil;
  }
  return (__bridge_transfer NSString*)ref;
}

}  // namespace

@interface LKMicInputManager () {
  std::mutex stateMutex_;
  std::unique_ptr<loopkit::AsyncResampler> resampler_;
  std::vector<float> scratchLeft_;
  std::vector<float> scratchRight_;
  std::atomic<double> inputSampleRate_;
  std::atomic<bool> running_;
  std::atomic<uint64_t> tapUnderruns_;
  std::atomic<uint64_t> suppressConfigNotificationsUntilNanos_;
  std::atomic<uint64_t> configRecoveryGeneration_;
  uint32_t maxFrames_;
  double engineSampleRate_;
}

@property(nonatomic, strong, nullable) AVAudioEngine* engine;
@property(nonatomic, copy, nullable) NSString* lastErrorMessage;
@property(nonatomic, copy, nullable) NSString* healthWarningMessage;
@property(nonatomic, copy) NSString* requestedUID;
@property(nonatomic, copy) NSString* activeUID;
@property(nonatomic, strong, nullable) id configChangeObserver;
@property(nonatomic, assign) BOOL tapInstalled;

@end

@implementation LKMicInputManager

- (instancetype)initWithSampleRate:(double)engineSampleRate maxFrames:(uint32_t)maxFrames {
  self = [super init];
  if (self == nil) return nil;
  engineSampleRate_ = engineSampleRate > 0 ? engineSampleRate : kEngineSampleRate;
  maxFrames_ = maxFrames;
  inputSampleRate_.store(engineSampleRate_, std::memory_order_relaxed);
  running_.store(false, std::memory_order_relaxed);
  tapUnderruns_.store(0, std::memory_order_relaxed);
  suppressConfigNotificationsUntilNanos_.store(0, std::memory_order_relaxed);
  configRecoveryGeneration_.store(0, std::memory_order_relaxed);
  resampler_ = std::make_unique<loopkit::AsyncResampler>(engineSampleRate_, engineSampleRate_, kResamplerRingFrames);
  scratchLeft_.assign(maxFrames_ * 4, 0.0f);
  scratchRight_.assign(maxFrames_ * 4, 0.0f);
  _requestedUID = @"system.default";
  _activeUID = @"system.default";
  _tapInstalled = NO;
  return self;
}

- (void)dealloc {
  [self stop];
  if (_configChangeObserver) {
    [[NSNotificationCenter defaultCenter] removeObserver:_configChangeObserver];
    _configChangeObserver = nil;
  }
}

- (BOOL)requestPermissionSync {
  __block BOOL granted = NO;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio
                           completionHandler:^(BOOL allowed) {
                             granted = allowed;
                             dispatch_semaphore_signal(sem);
                           }];
  // Wait up to 60 s for the user to respond to the TCC prompt (Apple's UI
  // doesn't time out). Return NO if the semaphore never fires.
  if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC)) != 0) {
    return NO;
  }
  return granted;
}

- (BOOL)activateDeviceWithUID:(NSString*)deviceUID {
  std::lock_guard<std::mutex> lock(stateMutex_);
  self.requestedUID = (deviceUID.length == 0) ? @"system.default" : deviceUID;
  [self teardownLocked];

  AudioDeviceID deviceID = kAudioObjectUnknown;
  if ([self.requestedUID isEqualToString:@"system.default"]) {
    deviceID = defaultInputDeviceID();
  } else if (!findInputDeviceIDByUID(self.requestedUID, &deviceID)) {
    self.lastErrorMessage = [NSString stringWithFormat:@"Input device with UID '%@' not found", self.requestedUID];
    return NO;
  }
  if (deviceID == kAudioObjectUnknown) {
    self.lastErrorMessage = @"No input device available";
    return NO;
  }

  self.engine = [[AVAudioEngine alloc] init];
  suppressConfigNotificationsUntilNanos_.store(
      monotonicNanos() + kConfigNotificationSuppressionNanos,
      std::memory_order_release);
  AVAudioInputNode* input = self.engine.inputNode;
  AudioUnit au = input.audioUnit;
  if (au == nullptr) {
    self.lastErrorMessage = @"AVAudioEngine input node has no underlying audio unit";
    self.engine = nil;
    return NO;
  }

  OSStatus status = AudioUnitSetProperty(au,
                                         kAudioOutputUnitProperty_CurrentDevice,
                                         kAudioUnitScope_Global,
                                         0,
                                         &deviceID,
                                         sizeof(deviceID));
  if (status != noErr) {
    self.lastErrorMessage = [NSString stringWithFormat:@"Failed to bind input device: %@", statusDescription(status)];
    self.engine = nil;
    return NO;
  }

  AVAudioFormat* inputFormat = [input inputFormatForBus:0];
  if (inputFormat == nil || inputFormat.sampleRate <= 0) {
    self.lastErrorMessage = @"Unable to read input format";
    self.engine = nil;
    return NO;
  }

  const double rate = inputFormat.sampleRate;
  inputSampleRate_.store(rate, std::memory_order_relaxed);
  resampler_->setRates(rate, engineSampleRate_);
  resampler_->reset();

  const uint32_t channelCount = inputFormat.channelCount > 0 ? inputFormat.channelCount : 1;

  __weak LKMicInputManager* weakSelf = self;
  [input installTapOnBus:0
              bufferSize:1024
                  format:inputFormat
                   block:^(AVAudioPCMBuffer* _Nonnull buffer, AVAudioTime* _Nonnull when) {
                     (void)when;
                     LKMicInputManager* strongSelf = weakSelf;
                     if (strongSelf == nil) return;
                     [strongSelf handleTapBuffer:buffer channelCount:channelCount];
                   }];
  self.tapInstalled = YES;

  NSError* engineError = nil;
  if (![self.engine startAndReturnError:&engineError]) {
    self.lastErrorMessage = engineError.localizedDescription ?: @"AVAudioEngine start failed";
    [input removeTapOnBus:0];
    self.tapInstalled = NO;
    self.engine = nil;
    return NO;
  }

  self.activeUID = deviceUIDForID(deviceID) ?: self.requestedUID;
  running_.store(true, std::memory_order_release);
  self.lastErrorMessage = nil;
  self.healthWarningMessage = nil;

  [self installConfigChangeObserver];
  return YES;
}

- (void)installConfigChangeObserver {
  if (self.configChangeObserver != nil) return;
  __weak LKMicInputManager* weakSelf = self;
  self.configChangeObserver = [[NSNotificationCenter defaultCenter]
      addObserverForName:AVAudioEngineConfigurationChangeNotification
                  object:self.engine
                   queue:[NSOperationQueue mainQueue]
              usingBlock:^(NSNotification* _Nonnull note) {
                (void)note;
                LKMicInputManager* strongSelf = weakSelf;
                if (strongSelf == nil) return;
                if (monotonicNanos() < strongSelf->suppressConfigNotificationsUntilNanos_.load(std::memory_order_acquire)) {
                  return;
                }
                NSString* uid = strongSelf.requestedUID;
                strongSelf.healthWarningMessage = @"Audio configuration changed — reattaching input";
                const uint64_t generation = strongSelf->configRecoveryGeneration_.fetch_add(
                    1, std::memory_order_acq_rel) + 1;
                dispatch_after(
                    dispatch_time(DISPATCH_TIME_NOW, kConfigRecoveryDebounceNanos),
                    dispatch_get_main_queue(),
                    ^{
                      LKMicInputManager* manager = weakSelf;
                      if (manager == nil) return;
                      if (manager->configRecoveryGeneration_.load(std::memory_order_acquire) != generation) return;
                      if (monotonicNanos() < manager->suppressConfigNotificationsUntilNanos_.load(std::memory_order_acquire)) return;
                      [manager activateDeviceWithUID:uid];
                    });
              }];
}

- (void)teardownLocked {
  configRecoveryGeneration_.fetch_add(1, std::memory_order_acq_rel);
  if (self.configChangeObserver != nil) {
    [[NSNotificationCenter defaultCenter] removeObserver:self.configChangeObserver];
    self.configChangeObserver = nil;
  }
  if (self.engine != nil) {
    if (self.tapInstalled) {
      [self.engine.inputNode removeTapOnBus:0];
      self.tapInstalled = NO;
    }
    [self.engine stop];
    self.engine = nil;
  }
  running_.store(false, std::memory_order_release);
  if (resampler_) resampler_->reset();
}

- (void)stop {
  std::lock_guard<std::mutex> lock(stateMutex_);
  [self teardownLocked];
  self.activeUID = @"system.default";
}

- (void)handleTapBuffer:(AVAudioPCMBuffer*)buffer channelCount:(uint32_t)channelCount {
  const AVAudioFrameCount frames = buffer.frameLength;
  if (frames == 0) return;

  if (scratchLeft_.size() < frames) {
    scratchLeft_.assign(frames, 0.0f);
    scratchRight_.assign(frames, 0.0f);
  }

  float* const left = scratchLeft_.data();
  float* const right = scratchRight_.data();
  const float* const* channelData = buffer.floatChannelData;
  if (channelData == nullptr) {
    // Format mismatch — zero and push to keep the resampler's clock steady.
    std::fill_n(left, frames, 0.0f);
    std::fill_n(right, frames, 0.0f);
  } else if (channelCount == 1) {
    const float* src = channelData[0];
    for (AVAudioFrameCount i = 0; i < frames; ++i) {
      left[i] = src[i];
      right[i] = src[i];
    }
  } else {
    const float* lSrc = channelData[0];
    const float* rSrc = channelData[1];
    std::copy_n(lSrc, frames, left);
    std::copy_n(rSrc, frames, right);
  }

  (void)resampler_->push(left, right, static_cast<uint32_t>(frames));
}

- (uint32_t)copyAudioLeft:(float*)left right:(float*)right maxFrames:(uint32_t)maxFrames {
  if (left == nullptr || right == nullptr || maxFrames == 0) return 0;
  if (!running_.load(std::memory_order_acquire)) {
    std::fill_n(left, maxFrames, 0.0f);
    std::fill_n(right, maxFrames, 0.0f);
    return 0;
  }
  return resampler_->pop(left, right, maxFrames);
}

- (NSString*)requestedDeviceUID {
  return self.requestedUID;
}

- (NSString*)activeDeviceUID {
  return self.activeUID;
}

- (BOOL)isRunning {
  return running_.load(std::memory_order_acquire);
}

- (double)inputDeviceSampleRate {
  return inputSampleRate_.load(std::memory_order_relaxed);
}

- (NSString*)lastError {
  return self.lastErrorMessage ?: @"";
}

- (NSString*)healthWarning {
  return self.healthWarningMessage ?: @"";
}

- (uint64_t)underrunCount {
  return resampler_ ? resampler_->underruns() : 0;
}

- (uint64_t)overrunCount {
  return resampler_ ? resampler_->overruns() : 0;
}

@end
