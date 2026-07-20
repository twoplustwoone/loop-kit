#import "AudioOutputRouter.h"

#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/AudioHardware.h>

#include "loopkit_resampler.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <memory>
#include <string>
#include <vector>

namespace {

constexpr uint32_t kRingCapacityFrames = 8192;
constexpr uint32_t kOutputTargetFrames = 1536;

NSString* statusDescription(OSStatus status) {
  const uint32_t code = static_cast<uint32_t>(status);
  return [NSString stringWithFormat:@"OSStatus %d (0x%08X)", static_cast<int32_t>(status), code];
}

bool readDeviceUID(AudioDeviceID deviceID, std::string* outUID) {
  if (outUID == nullptr || deviceID == kAudioObjectUnknown) {
    return false;
  }

  AudioObjectPropertyAddress address{
      .mSelector = kAudioDevicePropertyDeviceUID,
      .mScope = kAudioObjectPropertyScopeGlobal,
      .mElement = kAudioObjectPropertyElementMain,
  };
  if (!AudioObjectHasProperty(deviceID, &address)) {
    return false;
  }

  CFStringRef uidRef = nullptr;
  UInt32 size = sizeof(CFStringRef);
  if (AudioObjectGetPropertyData(deviceID, &address, 0, nullptr, &size, &uidRef) != noErr || uidRef == nullptr) {
    return false;
  }

  NSString* uid = [(__bridge NSString*)uidRef copy];
  CFRelease(uidRef);
  if (uid.length == 0) {
    return false;
  }
  *outUID = std::string([uid UTF8String]);
  return true;
}

std::vector<AudioDeviceID> outputDeviceIDs() {
  AudioObjectPropertyAddress address{
      .mSelector = kAudioHardwarePropertyDevices,
      .mScope = kAudioObjectPropertyScopeGlobal,
      .mElement = kAudioObjectPropertyElementMain,
  };

  UInt32 size = 0;
  const AudioObjectID systemObject = kAudioObjectSystemObject;
  if (AudioObjectGetPropertyDataSize(systemObject, &address, 0, nullptr, &size) != noErr) {
    return {};
  }
  if (size == 0) {
    return {};
  }

  std::vector<AudioDeviceID> ids(size / sizeof(AudioDeviceID));
  if (AudioObjectGetPropertyData(systemObject, &address, 0, nullptr, &size, ids.data()) != noErr) {
    return {};
  }

  std::vector<AudioDeviceID> outputIDs;
  outputIDs.reserve(ids.size());
  for (AudioDeviceID deviceID : ids) {
    AudioObjectPropertyAddress streamAddress{
        .mSelector = kAudioDevicePropertyStreams,
        .mScope = kAudioObjectPropertyScopeOutput,
        .mElement = kAudioObjectPropertyElementMain,
    };
    UInt32 streamSize = 0;
    if (AudioObjectGetPropertyDataSize(deviceID, &streamAddress, 0, nullptr, &streamSize) == noErr && streamSize > 0) {
      outputIDs.push_back(deviceID);
    }
  }

  return outputIDs;
}

bool deviceIDForUID(NSString* uid, AudioDeviceID* outDeviceID) {
  if (uid.length == 0 || outDeviceID == nullptr) {
    return false;
  }
  const std::string wanted([uid UTF8String]);

  for (AudioDeviceID deviceID : outputDeviceIDs()) {
    std::string deviceUID;
    if (readDeviceUID(deviceID, &deviceUID) && deviceUID == wanted) {
      *outDeviceID = deviceID;
      return true;
    }
  }

  return false;
}

bool isDeviceAlive(AudioDeviceID deviceID) {
  if (deviceID == kAudioObjectUnknown) {
    return false;
  }

  AudioObjectPropertyAddress address{
      .mSelector = kAudioDevicePropertyDeviceIsAlive,
      .mScope = kAudioObjectPropertyScopeGlobal,
      .mElement = kAudioObjectPropertyElementMain,
  };
  UInt32 isAlive = 0;
  UInt32 size = sizeof(UInt32);
  if (AudioObjectGetPropertyData(deviceID, &address, 0, nullptr, &size, &isAlive) != noErr) {
    return false;
  }
  return isAlive != 0;
}

bool readDeviceNominalSampleRate(AudioDeviceID deviceID, double* outSampleRate) {
  if (deviceID == kAudioObjectUnknown || outSampleRate == nullptr) {
    return false;
  }

  AudioObjectPropertyAddress address{
      .mSelector = kAudioDevicePropertyNominalSampleRate,
      .mScope = kAudioObjectPropertyScopeGlobal,
      .mElement = kAudioObjectPropertyElementMain,
  };
  if (!AudioObjectHasProperty(deviceID, &address)) {
    return false;
  }

  Float64 rate = 0.0;
  UInt32 size = sizeof(rate);
  if (AudioObjectGetPropertyData(deviceID, &address, 0, nullptr, &size, &rate) != noErr || rate <= 0.0) {
    return false;
  }

  *outSampleRate = static_cast<double>(rate);
  return true;
}

bool readDeviceBufferFrameSizeRange(AudioDeviceID deviceID, AudioValueRange* outRange) {
  if (deviceID == kAudioObjectUnknown || outRange == nullptr) {
    return false;
  }

  AudioObjectPropertyAddress address{
      .mSelector = kAudioDevicePropertyBufferFrameSizeRange,
      .mScope = kAudioObjectPropertyScopeGlobal,
      .mElement = kAudioObjectPropertyElementMain,
  };
  if (!AudioObjectHasProperty(deviceID, &address)) {
    return false;
  }

  AudioValueRange range{};
  UInt32 size = sizeof(range);
  if (AudioObjectGetPropertyData(deviceID, &address, 0, nullptr, &size, &range) != noErr || range.mMaximum <= 0.0) {
    return false;
  }

  *outRange = range;
  return true;
}

uint32_t monitorMaxSliceFrames(AudioDeviceID deviceID, double streamSampleRate, uint32_t requestedFrames) {
  uint32_t maxSliceFrames = std::max<uint32_t>(requestedFrames, 512);

  AudioValueRange frameSizeRange{};
  if (readDeviceBufferFrameSizeRange(deviceID, &frameSizeRange)) {
    maxSliceFrames = std::max<uint32_t>(
        maxSliceFrames,
        static_cast<uint32_t>(std::ceil(frameSizeRange.mMaximum)));
  }

  double deviceSampleRate = 0.0;
  if (streamSampleRate > 0.0 &&
      readDeviceNominalSampleRate(deviceID, &deviceSampleRate) &&
      deviceSampleRate > 0.0) {
    const double scaled = std::ceil((static_cast<double>(maxSliceFrames) * streamSampleRate) / deviceSampleRate);
    maxSliceFrames = std::max<uint32_t>(maxSliceFrames, static_cast<uint32_t>(scaled));
  }

  return std::min<uint32_t>(maxSliceFrames, 8192);
}

}  // namespace

@interface LKAudioOutputRouter () {
  std::mutex stateMutex_;
  AudioUnit outputUnit_;
  AudioDeviceID activeDeviceID_;
  std::string activeDeviceUID_;
  std::string lastError_;
  std::string label_;
  double sampleRate_;
  uint32_t maxFrames_;
  std::unique_ptr<loopkit::AsyncResampler> resampler_;
  std::vector<float> renderScratchLeft_;
  std::vector<float> renderScratchRight_;
  std::atomic<int32_t> lastRenderError_;
}

- (OSStatus)renderToOutput:(AudioBufferList*)ioData frames:(UInt32)frameCount;
- (void)stopLocked;
- (void)setLastErrorLocked:(NSString*)message;
- (NSString*)labelNS;

@end

static OSStatus monitorOutputRenderCallback(void* inRefCon,
                                            AudioUnitRenderActionFlags* ioActionFlags,
                                            const AudioTimeStamp* inTimeStamp,
                                            UInt32 inBusNumber,
                                            UInt32 inNumberFrames,
                                            AudioBufferList* ioData) {
  (void)ioActionFlags;
  (void)inTimeStamp;
  (void)inBusNumber;

  LKAudioOutputRouter* manager = (__bridge LKAudioOutputRouter*)inRefCon;
  return [manager renderToOutput:ioData frames:inNumberFrames];
}

@implementation LKAudioOutputRouter

- (instancetype)initWithLabel:(NSString*)label
                   sampleRate:(double)sampleRate
                    maxFrames:(uint32_t)maxFrames {
  self = [super init];
  if (self == nil) {
    return nil;
  }
  outputUnit_ = nullptr;
  activeDeviceID_ = kAudioObjectUnknown;
  sampleRate_ = sampleRate > 0 ? sampleRate : 48000.0;
  maxFrames_ = maxFrames == 0 ? 256 : maxFrames;
  label_ = std::string(label.length > 0 ? [label UTF8String] : "Output");
  lastRenderError_.store(noErr, std::memory_order_relaxed);
  return self;
}

// Legacy init — keeps older callers compiling via the compatibility alias.
- (instancetype)initWithSampleRate:(double)sampleRate maxFrames:(uint32_t)maxFrames {
  return [self initWithLabel:@"Monitor" sampleRate:sampleRate maxFrames:maxFrames];
}

- (NSString*)labelNS {
  return [NSString stringWithUTF8String:label_.c_str()];
}

- (double)deviceSampleRate {
  if (activeDeviceID_ == kAudioObjectUnknown) return 0.0;
  double rate = 0.0;
  if (!readDeviceNominalSampleRate(activeDeviceID_, &rate)) return 0.0;
  return rate;
}

- (void)dealloc {
  std::lock_guard<std::mutex> lock(stateMutex_);
  [self stopLocked];
}

- (BOOL)activateDeviceWithUID:(NSString*)deviceUID {
  if (deviceUID.length == 0) {
    std::lock_guard<std::mutex> lock(stateMutex_);
    [self setLastErrorLocked:[NSString stringWithFormat:@"%@ output device UID is empty", [self labelNS]]];
    return NO;
  }

  AudioDeviceID targetDeviceID = kAudioObjectUnknown;
  if (!deviceIDForUID(deviceUID, &targetDeviceID)) {
    std::lock_guard<std::mutex> lock(stateMutex_);
    [self setLastErrorLocked:[NSString stringWithFormat:@"%@ output device %@ not found", [self labelNS], deviceUID]];
    return NO;
  }

  std::lock_guard<std::mutex> lock(stateMutex_);
  if (outputUnit_ != nullptr && targetDeviceID == activeDeviceID_ && isDeviceAlive(activeDeviceID_)) {
    return YES;
  }

  [self stopLocked];

  AudioComponentDescription description{};
  description.componentType = kAudioUnitType_Output;
  description.componentSubType = kAudioUnitSubType_HALOutput;
  description.componentManufacturer = kAudioUnitManufacturer_Apple;

  AudioComponent component = AudioComponentFindNext(nullptr, &description);
  if (component == nullptr) {
    [self setLastErrorLocked:@"Failed to find HAL output audio component"];
    return NO;
  }

  AudioUnit unit = nullptr;
  OSStatus status = AudioComponentInstanceNew(component, &unit);
  if (status != noErr || unit == nullptr) {
    [self setLastErrorLocked:[NSString stringWithFormat:@"Failed to create output audio unit (%@)", statusDescription(status)]];
    return NO;
  }

  UInt32 enableOutput = 1;
  status = AudioUnitSetProperty(unit,
                                kAudioOutputUnitProperty_EnableIO,
                                kAudioUnitScope_Output,
                                0,
                                &enableOutput,
                                sizeof(enableOutput));
  if (status != noErr) {
    AudioComponentInstanceDispose(unit);
    [self setLastErrorLocked:[NSString stringWithFormat:@"Failed to enable output IO (%@)", statusDescription(status)]];
    return NO;
  }

  UInt32 disableInput = 0;
  status = AudioUnitSetProperty(unit,
                                kAudioOutputUnitProperty_EnableIO,
                                kAudioUnitScope_Input,
                                1,
                                &disableInput,
                                sizeof(disableInput));
  if (status != noErr) {
    AudioComponentInstanceDispose(unit);
    [self setLastErrorLocked:[NSString stringWithFormat:@"Failed to disable input IO (%@)", statusDescription(status)]];
    return NO;
  }

  status = AudioUnitSetProperty(unit,
                                kAudioOutputUnitProperty_CurrentDevice,
                                kAudioUnitScope_Global,
                                0,
                                &targetDeviceID,
                                sizeof(targetDeviceID));
  if (status != noErr) {
    AudioComponentInstanceDispose(unit);
    [self setLastErrorLocked:[NSString stringWithFormat:@"Failed to bind %@ output device (%@)", [self labelNS], statusDescription(status)]];
    return NO;
  }

  AudioStreamBasicDescription asbd{};
  double deviceSampleRate = sampleRate_;
  (void)readDeviceNominalSampleRate(targetDeviceID, &deviceSampleRate);
  asbd.mSampleRate = deviceSampleRate;
  asbd.mFormatID = kAudioFormatLinearPCM;
  asbd.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
  asbd.mBitsPerChannel = 32;
  asbd.mChannelsPerFrame = 2;
  asbd.mFramesPerPacket = 1;
  asbd.mBytesPerFrame = sizeof(float) * asbd.mChannelsPerFrame;
  asbd.mBytesPerPacket = sizeof(float) * asbd.mChannelsPerFrame;

  status = AudioUnitSetProperty(unit,
                                kAudioUnitProperty_StreamFormat,
                                kAudioUnitScope_Input,
                                0,
                                &asbd,
                                sizeof(asbd));
  if (status != noErr) {
    AudioComponentInstanceDispose(unit);
    [self setLastErrorLocked:[NSString stringWithFormat:@"Failed to set %@ stream format (%@)", [self labelNS], statusDescription(status)]];
    return NO;
  }

  // Keep this comfortably above the hardware callback size, including sample-rate conversion.
  UInt32 maxSliceFrames = monitorMaxSliceFrames(targetDeviceID, deviceSampleRate, maxFrames_);
  status = AudioUnitSetProperty(unit,
                                kAudioUnitProperty_MaximumFramesPerSlice,
                                kAudioUnitScope_Global,
                                0,
                                &maxSliceFrames,
                                sizeof(maxSliceFrames));
  if (status != noErr) {
    AudioComponentInstanceDispose(unit);
    [self setLastErrorLocked:[NSString stringWithFormat:@"Failed to set max slice frames (%@)", statusDescription(status)]];
    return NO;
  }

  AURenderCallbackStruct callback{};
  callback.inputProc = monitorOutputRenderCallback;
  callback.inputProcRefCon = (__bridge void*)self;
  status = AudioUnitSetProperty(unit,
                                kAudioUnitProperty_SetRenderCallback,
                                kAudioUnitScope_Input,
                                0,
                                &callback,
                                sizeof(callback));
  if (status != noErr) {
    AudioComponentInstanceDispose(unit);
    [self setLastErrorLocked:[NSString stringWithFormat:@"Failed to set %@ render callback (%@)", [self labelNS], statusDescription(status)]];
    return NO;
  }

  status = AudioUnitInitialize(unit);
  if (status != noErr) {
    AudioComponentInstanceDispose(unit);
    [self setLastErrorLocked:[NSString stringWithFormat:@"Failed to initialize %@ output unit (%@)", [self labelNS], statusDescription(status)]];
    return NO;
  }

  resampler_ = std::make_unique<loopkit::AsyncResampler>(sampleRate_, deviceSampleRate, kRingCapacityFrames);
  resampler_->setTargetFillFrames(kOutputTargetFrames);
  resampler_->setMaxRateCorrection(0.005);
  renderScratchLeft_.assign(maxSliceFrames, 0.0f);
  renderScratchRight_.assign(maxSliceFrames, 0.0f);
  std::array<float, kOutputTargetFrames> silence{};
  (void)resampler_->push(silence.data(), silence.data(), kOutputTargetFrames);

  status = AudioOutputUnitStart(unit);
  if (status != noErr) {
    AudioUnitUninitialize(unit);
    AudioComponentInstanceDispose(unit);
    [self setLastErrorLocked:[NSString stringWithFormat:@"Failed to start %@ output (%@)", [self labelNS], statusDescription(status)]];
    return NO;
  }

  std::string uid;
  if (!readDeviceUID(targetDeviceID, &uid)) {
    uid = std::string([deviceUID UTF8String]);
  }

  outputUnit_ = unit;
  activeDeviceID_ = targetDeviceID;
  activeDeviceUID_ = uid;
  lastError_.clear();
  lastRenderError_.store(noErr, std::memory_order_relaxed);
  return YES;
}

- (void)stop {
  std::lock_guard<std::mutex> lock(stateMutex_);
  [self stopLocked];
}

- (BOOL)enqueueLeft:(const float*)left right:(const float*)right frames:(uint32_t)frames {
  if (left == nullptr || right == nullptr || frames == 0) {
    return NO;
  }
  if (resampler_ == nullptr || !resampler_->push(left, right, frames)) {
    std::lock_guard<std::mutex> lock(stateMutex_);
    if (lastError_.empty()) {
      [self setLastErrorLocked:[NSString stringWithFormat:@"%@ output queue overrun", [self labelNS]]];
    }
    return NO;
  }
  return YES;
}

- (NSString*)activeDeviceUID {
  std::lock_guard<std::mutex> lock(stateMutex_);
  if (activeDeviceUID_.empty()) {
    return @"";
  }
  return [NSString stringWithUTF8String:activeDeviceUID_.c_str()];
}

- (BOOL)isRunning {
  std::lock_guard<std::mutex> lock(stateMutex_);
  return outputUnit_ != nullptr && activeDeviceID_ != kAudioObjectUnknown;
}

- (NSString*)healthWarning {
  std::lock_guard<std::mutex> lock(stateMutex_);
  if (outputUnit_ == nullptr || activeDeviceID_ == kAudioObjectUnknown) {
    return @"Monitor output is not running";
  }

  if (!isDeviceAlive(activeDeviceID_)) {
    return @"Monitor output device is unavailable";
  }

  const int32_t renderError = lastRenderError_.exchange(noErr, std::memory_order_relaxed);
  if (renderError != noErr) {
    return [NSString stringWithFormat:@"%@ output render error (%@)", [self labelNS], statusDescription(renderError)];
  }

  return @"";
}

- (NSString*)lastError {
  std::lock_guard<std::mutex> lock(stateMutex_);
  if (lastError_.empty()) {
    return @"";
  }
  return [NSString stringWithUTF8String:lastError_.c_str()];
}

- (uint64_t)overrunCount {
  return resampler_ == nullptr ? 0 : resampler_->overruns();
}

- (uint64_t)underrunCount {
  return resampler_ == nullptr ? 0 : resampler_->underruns();
}

- (uint32_t)bufferedFrames {
  return resampler_ == nullptr ? 0 : resampler_->bufferedFrames();
}

- (double)queueFillRatio {
  return resampler_ == nullptr ? 0.0 : resampler_->fillRatio();
}

- (OSStatus)renderToOutput:(AudioBufferList*)ioData frames:(UInt32)frameCount {
  if (ioData == nullptr || frameCount == 0) {
    return noErr;
  }

  if (ioData->mNumberBuffers >= 2) {
    AudioBuffer& leftBuffer = ioData->mBuffers[0];
    AudioBuffer& rightBuffer = ioData->mBuffers[1];
    float* left = static_cast<float*>(leftBuffer.mData);
    float* right = static_cast<float*>(rightBuffer.mData);
    if (left != nullptr && right != nullptr && resampler_ != nullptr) {
      resampler_->pop(left, right, frameCount);
    } else {
      if (leftBuffer.mData != nullptr && leftBuffer.mDataByteSize > 0) {
        std::memset(leftBuffer.mData, 0, leftBuffer.mDataByteSize);
      }
      if (rightBuffer.mData != nullptr && rightBuffer.mDataByteSize > 0) {
        std::memset(rightBuffer.mData, 0, rightBuffer.mDataByteSize);
      }
    }
    leftBuffer.mDataByteSize = frameCount * sizeof(float);
    rightBuffer.mDataByteSize = frameCount * sizeof(float);
  } else if (ioData->mNumberBuffers == 1) {
    AudioBuffer& buffer = ioData->mBuffers[0];
    float* out = static_cast<float*>(buffer.mData);
    const uint32_t channels = std::max<uint32_t>(buffer.mNumberChannels, 1);
    if (out != nullptr && resampler_ != nullptr && frameCount <= renderScratchLeft_.size()) {
      resampler_->pop(renderScratchLeft_.data(), renderScratchRight_.data(), frameCount);
      for (uint32_t frame = 0; frame < frameCount; ++frame) {
        if (channels == 1) {
          out[frame] = (renderScratchLeft_[frame] + renderScratchRight_[frame]) * 0.5f;
        } else {
          out[frame * channels] = renderScratchLeft_[frame];
          out[frame * channels + 1] = renderScratchRight_[frame];
          for (uint32_t channel = 2; channel < channels; ++channel) {
            out[frame * channels + channel] = 0.0f;
          }
        }
      }
    } else if (buffer.mDataByteSize > 0) {
      std::memset(buffer.mData, 0, buffer.mDataByteSize);
    }
    buffer.mDataByteSize = frameCount * channels * sizeof(float);
  } else {
    for (UInt32 index = 0; index < ioData->mNumberBuffers; ++index) {
      AudioBuffer& buffer = ioData->mBuffers[index];
      if (buffer.mData != nullptr && buffer.mDataByteSize > 0) {
        std::memset(buffer.mData, 0, buffer.mDataByteSize);
      }
    }
  }

  return noErr;
}

- (void)stopLocked {
  if (outputUnit_ != nullptr) {
    AudioOutputUnitStop(outputUnit_);
    AudioUnitUninitialize(outputUnit_);
    AudioComponentInstanceDispose(outputUnit_);
    outputUnit_ = nullptr;
  }
  activeDeviceID_ = kAudioObjectUnknown;
  activeDeviceUID_.clear();
  resampler_.reset();
  renderScratchLeft_.clear();
  renderScratchRight_.clear();
}

- (void)setLastErrorLocked:(NSString*)message {
  if (message.length == 0) {
    lastError_.clear();
    return;
  }
  lastError_ = std::string([message UTF8String]);
}

@end
