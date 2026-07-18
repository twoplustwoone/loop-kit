#import "ProcessTapManager.h"

#import <AppKit/AppKit.h>
#import <CoreAudio/AudioHardware.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstring>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <unordered_map>
#include <vector>

#include "loopkit_resampler.h"

namespace {

constexpr uint32_t kTapPacketFrames = 2048;
constexpr uint32_t kTapResamplerCapacityFrames = 8192;

struct ProcessEntry {
  AudioObjectID processObjectID = kAudioObjectUnknown;
  pid_t pid = 0;
  std::string bundleID;
  std::string displayName;
  bool outputActive = false;
};

struct TapContext {
  std::string bundleID;
  pid_t pid = 0;
  AudioObjectID tapID = kAudioObjectUnknown;
  AudioObjectID aggregateID = kAudioObjectUnknown;
  AudioDeviceIOProcID ioProcID = nullptr;
  std::vector<AudioObjectID> processObjectIDs;
  double tapSampleRate = 48000.0;
  std::unique_ptr<loopkit::AsyncResampler> resampler;
};

std::string toStdString(NSString* value) {
  if (value == nil) {
    return std::string();
  }
  return std::string([value UTF8String]);
}

NSString* toNSString(const std::string& value) {
  return [[NSString alloc] initWithUTF8String:value.c_str()];
}

void zeroOutput(AudioBufferList* output) {
  if (output == nullptr) {
    return;
  }
  for (UInt32 i = 0; i < output->mNumberBuffers; ++i) {
    AudioBuffer& buffer = output->mBuffers[i];
    if (buffer.mData != nullptr && buffer.mDataByteSize > 0) {
      std::memset(buffer.mData, 0, buffer.mDataByteSize);
    }
  }
}

OSStatus tapDeviceIOProc(AudioObjectID inDevice,
                         const AudioTimeStamp* inNow,
                         const AudioBufferList* inInputData,
                         const AudioTimeStamp* inInputTime,
                         AudioBufferList* outOutputData,
                         const AudioTimeStamp* inOutputTime,
                         void* inClientData) {
  (void)inDevice;
  (void)inNow;
  (void)inInputTime;
  (void)inOutputTime;

  auto* context = static_cast<TapContext*>(inClientData);
  if (context == nullptr) {
    zeroOutput(outOutputData);
    return noErr;
  }

  if (context->resampler != nullptr && inInputData != nullptr) {
    if (inInputData->mNumberBuffers >= 2) {
      const AudioBuffer& leftBuffer = inInputData->mBuffers[0];
      const AudioBuffer& rightBuffer = inInputData->mBuffers[1];
      if (leftBuffer.mData != nullptr && rightBuffer.mData != nullptr) {
        const uint32_t leftFrames = leftBuffer.mDataByteSize / static_cast<uint32_t>(sizeof(float));
        const uint32_t rightFrames = rightBuffer.mDataByteSize / static_cast<uint32_t>(sizeof(float));
        const uint32_t totalFrames = std::min(leftFrames, rightFrames);
        const float* left = static_cast<const float*>(leftBuffer.mData);
        const float* right = static_cast<const float*>(rightBuffer.mData);
        for (uint32_t offset = 0; offset < totalFrames; offset += kTapPacketFrames) {
          const uint32_t chunk = std::min(kTapPacketFrames, totalFrames - offset);
          context->resampler->push(left + offset, right + offset, chunk);
        }
      }
    } else if (inInputData->mNumberBuffers == 1) {
      const AudioBuffer& buffer = inInputData->mBuffers[0];
      if (buffer.mData != nullptr && buffer.mNumberChannels > 0) {
        const float* data = static_cast<const float*>(buffer.mData);
        const uint32_t channels = buffer.mNumberChannels;
        const uint32_t totalFrames =
            buffer.mDataByteSize / static_cast<uint32_t>(sizeof(float) * channels);
        std::array<float, kTapPacketFrames> left{};
        std::array<float, kTapPacketFrames> right{};
        for (uint32_t offset = 0; offset < totalFrames; offset += kTapPacketFrames) {
          const uint32_t chunk = std::min(kTapPacketFrames, totalFrames - offset);
          for (uint32_t frame = 0; frame < chunk; ++frame) {
            const uint32_t index = (offset + frame) * channels;
            left[frame] = data[index];
            right[frame] = channels >= 2 ? data[index + 1] : data[index];
          }
          context->resampler->push(left.data(), right.data(), chunk);
        }
      }
    }
  }

  zeroOutput(outOutputData);
  return noErr;
}

std::vector<AudioObjectID> processObjectIDs() {
  AudioObjectPropertyAddress address{
      .mSelector = kAudioHardwarePropertyProcessObjectList,
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

  std::vector<AudioObjectID> ids(size / sizeof(AudioObjectID));
  if (AudioObjectGetPropertyData(systemObject, &address, 0, nullptr, &size, ids.data()) != noErr) {
    return {};
  }
  return ids;
}

bool processPID(AudioObjectID processObjectID, pid_t* outPID) {
  if (outPID == nullptr) {
    return false;
  }
  AudioObjectPropertyAddress address{
      .mSelector = kAudioProcessPropertyPID,
      .mScope = kAudioObjectPropertyScopeGlobal,
      .mElement = kAudioObjectPropertyElementMain,
  };
  UInt32 size = sizeof(pid_t);
  pid_t pid = 0;
  if (AudioObjectGetPropertyData(processObjectID, &address, 0, nullptr, &size, &pid) != noErr) {
    return false;
  }
  *outPID = pid;
  return true;
}

NSString* processBundleID(AudioObjectID processObjectID) {
  AudioObjectPropertyAddress address{
      .mSelector = kAudioProcessPropertyBundleID,
      .mScope = kAudioObjectPropertyScopeGlobal,
      .mElement = kAudioObjectPropertyElementMain,
  };
  CFStringRef bundleRef = nullptr;
  UInt32 size = sizeof(CFStringRef);
  if (AudioObjectGetPropertyData(processObjectID, &address, 0, nullptr, &size, &bundleRef) != noErr ||
      bundleRef == nullptr) {
    return nil;
  }
  NSString* out = [(__bridge NSString*)bundleRef copy];
  CFRelease(bundleRef);
  return out;
}

bool processOutputActive(AudioObjectID processObjectID) {
  AudioObjectPropertyAddress address{
      .mSelector = kAudioProcessPropertyIsRunningOutput,
      .mScope = kAudioObjectPropertyScopeGlobal,
      .mElement = kAudioObjectPropertyElementMain,
  };
  UInt32 running = 0;
  UInt32 size = sizeof(UInt32);
  if (AudioObjectGetPropertyData(processObjectID, &address, 0, nullptr, &size, &running) != noErr) {
    return false;
  }
  return running != 0;
}

bool readTapSampleRate(AudioObjectID tapID, double* outSampleRate) {
  if (outSampleRate == nullptr || tapID == kAudioObjectUnknown) {
    return false;
  }

  AudioObjectPropertyAddress address{
      .mSelector = kAudioTapPropertyFormat,
      .mScope = kAudioObjectPropertyScopeGlobal,
      .mElement = kAudioObjectPropertyElementMain,
  };
  if (!AudioObjectHasProperty(tapID, &address)) {
    return false;
  }

  AudioStreamBasicDescription asbd{};
  UInt32 size = sizeof(asbd);
  if (AudioObjectGetPropertyData(tapID, &address, 0, nullptr, &size, &asbd) != noErr || asbd.mSampleRate <= 0.0) {
    return false;
  }

  *outSampleRate = asbd.mSampleRate;
  return true;
}

NSString* tapUID(AudioObjectID tapID) {
  AudioObjectPropertyAddress address{
      .mSelector = kAudioTapPropertyUID,
      .mScope = kAudioObjectPropertyScopeGlobal,
      .mElement = kAudioObjectPropertyElementMain,
  };
  CFStringRef uidRef = nullptr;
  UInt32 size = sizeof(CFStringRef);
  if (AudioObjectGetPropertyData(tapID, &address, 0, nullptr, &size, &uidRef) != noErr || uidRef == nullptr) {
    return nil;
  }
  NSString* uid = [(__bridge NSString*)uidRef copy];
  CFRelease(uidRef);
  return uid;
}

void destroyTapContext(const std::shared_ptr<TapContext>& context) {
  if (!context) {
    return;
  }

  if (context->aggregateID != kAudioObjectUnknown && context->ioProcID != nullptr) {
    AudioDeviceStop(context->aggregateID, context->ioProcID);
    AudioDeviceDestroyIOProcID(context->aggregateID, context->ioProcID);
    context->ioProcID = nullptr;
  }

  if (context->aggregateID != kAudioObjectUnknown) {
    AudioHardwareDestroyAggregateDevice(context->aggregateID);
    context->aggregateID = kAudioObjectUnknown;
  }

  if (context->tapID != kAudioObjectUnknown) {
    if (@available(macOS 14.2, *)) {
      AudioHardwareDestroyProcessTap(context->tapID);
    }
    context->tapID = kAudioObjectUnknown;
  }
}

}  // namespace

@implementation LKProcessTapAppInfo

- (instancetype)initWithBundleID:(NSString*)bundleID
                     displayName:(NSString*)displayName
                             pid:(int)pid
                         running:(BOOL)running
                    outputActive:(BOOL)outputActive {
  self = [super init];
  if (self == nil) {
    return nil;
  }
  _bundleID = [bundleID copy];
  _displayName = [displayName copy];
  _pid = pid;
  _running = running;
  _outputActive = outputActive;
  return self;
}

@end

@interface LKProcessTapManager () {
  std::mutex stateMutex_;
  uint32_t maxFrames_;
  std::vector<std::string> selectedBundleIDs_;
  std::unordered_map<std::string, std::shared_ptr<TapContext>> tapContexts_;
  std::string lastWarning_;
}
@end

@implementation LKProcessTapManager

- (instancetype)initWithMaxFrames:(uint32_t)maxFrames {
  self = [super init];
  if (self == nil) {
    return nil;
  }
  maxFrames_ = maxFrames == 0 ? kTapPacketFrames : std::min(maxFrames, kTapPacketFrames);
  return self;
}

- (void)dealloc {
  std::lock_guard<std::mutex> lock(stateMutex_);
  for (const auto& pair : tapContexts_) {
    destroyTapContext(pair.second);
  }
  tapContexts_.clear();
}

- (BOOL)isSupported {
  if (@available(macOS 14.2, *)) {
    return YES;
  }
  return NO;
}

- (NSArray<LKProcessTapAppInfo*>*)listApps {
  std::vector<ProcessEntry> processes = [self collectProcesses];

  struct AppAggregate {
    int pid = 0;
    bool running = false;
    bool outputActive = false;
    std::string displayName;
  };

  std::unordered_map<std::string, AppAggregate> byBundle;
  byBundle.reserve(processes.size());
  for (const auto& process : processes) {
    if (process.bundleID.empty()) {
      continue;
    }
    auto& aggregate = byBundle[process.bundleID];
    if (aggregate.displayName.empty()) {
      aggregate.displayName = process.displayName;
      aggregate.pid = process.pid;
    }
    if (aggregate.displayName == process.bundleID && !process.displayName.empty()) {
      aggregate.displayName = process.displayName;
      aggregate.pid = process.pid;
    }
    aggregate.running = true;
    aggregate.outputActive = aggregate.outputActive || process.outputActive;
  }

  NSMutableArray<LKProcessTapAppInfo*>* apps = [NSMutableArray array];
  for (const auto& pair : byBundle) {
    const std::string& bundleID = pair.first;
    const AppAggregate& app = pair.second;
    NSString* bundleNSString = toNSString(bundleID);
    NSString* nameNSString = toNSString(app.displayName.empty() ? bundleID : app.displayName);
    [apps addObject:[[LKProcessTapAppInfo alloc]
                        initWithBundleID:bundleNSString
                             displayName:nameNSString
                                     pid:app.pid
                                 running:app.running
                            outputActive:app.outputActive]];
  }

  [apps sortUsingComparator:^NSComparisonResult(LKProcessTapAppInfo* a, LKProcessTapAppInfo* b) {
    return [a.displayName localizedCaseInsensitiveCompare:b.displayName];
  }];
  return apps;
}

- (void)setSelectedBundleIDs:(NSArray<NSString*>*)bundleIDs {
  std::vector<std::string> next;
  next.reserve(bundleIDs.count);
  for (NSString* bundleID in bundleIDs) {
    if (bundleID.length == 0) {
      continue;
    }
    next.push_back(toStdString(bundleID));
  }
  std::sort(next.begin(), next.end());
  next.erase(std::unique(next.begin(), next.end()), next.end());

  {
    std::lock_guard<std::mutex> lock(stateMutex_);
    selectedBundleIDs_ = std::move(next);
  }
}

- (NSArray<NSString*>*)selectedBundleIDs {
  std::lock_guard<std::mutex> lock(stateMutex_);
  NSMutableArray<NSString*>* out = [NSMutableArray arrayWithCapacity:selectedBundleIDs_.size()];
  for (const auto& bundleID : selectedBundleIDs_) {
    [out addObject:toNSString(bundleID)];
  }
  return out;
}

- (void)reconcile {
  // CoreAudio process discovery can occasionally take tens or hundreds of
  // milliseconds. Keep it outside stateMutex_ so the render path can continue
  // to copy audio from the existing taps while discovery is in flight.
  std::vector<ProcessEntry> processes = [self collectProcesses];

  std::vector<std::string> selected;
  std::unordered_map<std::string, std::shared_ptr<TapContext>> existing;
  {
    std::lock_guard<std::mutex> lock(stateMutex_);
    selected = selectedBundleIDs_;
    existing = tapContexts_;
  }

  std::unordered_map<std::string, std::vector<AudioObjectID>> processMap;
  std::unordered_map<std::string, pid_t> pidMap;
  for (const auto& process : processes) {
    processMap[process.bundleID].push_back(process.processObjectID);
    pidMap[process.bundleID] = process.pid;
  }

  std::unordered_map<std::string, std::shared_ptr<TapContext>> next;
  std::vector<std::shared_ptr<TapContext>> created;
  std::string warning;

  if ([self isSupported]) {
    for (const std::string& bundleID : selected) {
      auto processIt = processMap.find(bundleID);
      if (processIt == processMap.end() || processIt->second.empty()) {
        continue;
      }

      std::vector<AudioObjectID> desiredProcessObjectIDs = processIt->second;
      std::sort(desiredProcessObjectIDs.begin(), desiredProcessObjectIDs.end());

      auto existingIt = existing.find(bundleID);
      if (existingIt != existing.end()) {
        std::vector<AudioObjectID> existingProcessObjectIDs = existingIt->second->processObjectIDs;
        std::sort(existingProcessObjectIDs.begin(), existingProcessObjectIDs.end());
        if (existingProcessObjectIDs == desiredProcessObjectIDs) {
          next[bundleID] = existingIt->second;
          continue;
        }
      }

      std::shared_ptr<TapContext> context = [self createTapForBundle:toNSString(bundleID)
                                                       processObjectIDs:desiredProcessObjectIDs
                                                                    pid:pidMap[bundleID]
                                                                warning:&warning];
      if (context) {
        next[bundleID] = context;
        created.push_back(context);
      }
    }
  } else {
    warning = "Process tap capture requires macOS 14.2+";
  }

  if (warning.empty() && !selected.empty() && next.empty()) {
    warning = "No selected apps are currently available for process tap capture";
  }

  std::vector<std::shared_ptr<TapContext>> retired;
  bool selectionChanged = false;
  {
    std::lock_guard<std::mutex> lock(stateMutex_);
    selectionChanged = selectedBundleIDs_ != selected;
    if (!selectionChanged) {
      for (const auto& pair : tapContexts_) {
        auto nextIt = next.find(pair.first);
        if (nextIt == next.end() || nextIt->second.get() != pair.second.get()) {
          retired.push_back(pair.second);
        }
      }
      tapContexts_ = std::move(next);
      lastWarning_ = warning;
    }
  }

  // CoreAudio tap teardown can block too. It is safe outside the mutex: audio
  // readers retain a shared_ptr to the old context for the duration of a pop.
  if (selectionChanged) {
    for (const auto& context : created) {
      destroyTapContext(context);
    }
    return;
  }
  for (const auto& context : retired) {
    destroyTapContext(context);
  }
}

- (NSUInteger)activeTapCount {
  std::lock_guard<std::mutex> lock(stateMutex_);
  return tapContexts_.size();
}

- (NSString*)lastWarning {
  std::lock_guard<std::mutex> lock(stateMutex_);
  return toNSString(lastWarning_);
}

- (BOOL)isActive {
  std::lock_guard<std::mutex> lock(stateMutex_);
  return !tapContexts_.empty();
}

- (uint64_t)tapUnderruns {
  std::lock_guard<std::mutex> lock(stateMutex_);
  uint64_t total = 0;
  for (const auto& pair : tapContexts_) {
    if (pair.second && pair.second->resampler) {
      total += pair.second->resampler->underruns();
    }
  }
  return total;
}

- (uint64_t)tapOverruns {
  std::lock_guard<std::mutex> lock(stateMutex_);
  uint64_t total = 0;
  for (const auto& pair : tapContexts_) {
    if (pair.second && pair.second->resampler) {
      total += pair.second->resampler->overruns();
    }
  }
  return total;
}

- (double)tapSampleRate {
  std::lock_guard<std::mutex> lock(stateMutex_);
  if (tapContexts_.empty()) {
    return 0.0;
  }
  double rate = 0.0;
  for (const auto& pair : tapContexts_) {
    if (!pair.second) {
      continue;
    }
    if (rate == 0.0) {
      rate = pair.second->tapSampleRate;
    } else if (std::fabs(rate - pair.second->tapSampleRate) > 1.0) {
      return 0.0;
    }
  }
  return rate;
}

- (uint32_t)copyAudioForBundleID:(NSString*)bundleID
                            left:(float*)left
                           right:(float*)right
                       maxFrames:(uint32_t)maxFrames {
  if (bundleID.length == 0 || left == nullptr || right == nullptr || maxFrames == 0) {
    return 0;
  }

  std::shared_ptr<TapContext> context;
  {
    std::lock_guard<std::mutex> lock(stateMutex_);
    auto it = tapContexts_.find(toStdString(bundleID));
    if (it == tapContexts_.end()) {
      return 0;
    }
    context = it->second;
  }

  if (!context) {
    return 0;
  }

  const uint32_t requested = std::min(maxFrames, maxFrames_);
  if (!context->resampler) {
    return 0;
  }
  return context->resampler->pop(left, right, requested);
}

- (std::vector<ProcessEntry>)collectProcesses {
  std::vector<ProcessEntry> out;
  std::vector<AudioObjectID> ids = processObjectIDs();
  out.reserve(ids.size());

  for (AudioObjectID processObjectID : ids) {
    pid_t pid = 0;
    if (!processPID(processObjectID, &pid) || pid <= 0) {
      continue;
    }

    NSString* bundleID = processBundleID(processObjectID);
    if (bundleID.length == 0) {
      continue;
    }

    NSRunningApplication* app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    if (app == nil) {
      continue;
    }
    if (app.activationPolicy != NSApplicationActivationPolicyRegular) {
      continue;
    }
    NSString* name = app.localizedName ?: bundleID;

    ProcessEntry entry;
    entry.processObjectID = processObjectID;
    entry.pid = pid;
    entry.bundleID = toStdString(bundleID);
    entry.displayName = toStdString(name);
    entry.outputActive = processOutputActive(processObjectID);
    out.push_back(std::move(entry));
  }

  return out;
}

- (std::shared_ptr<TapContext>)createTapForBundle:(NSString*)bundleID
                                  processObjectIDs:(const std::vector<AudioObjectID>&)processObjectIDs
                                               pid:(pid_t)pid
                                           warning:(std::string*)warningOut {
  if (@available(macOS 14.2, *)) {
    NSMutableArray<NSNumber*>* processNumbers = [NSMutableArray arrayWithCapacity:processObjectIDs.size()];
    for (AudioObjectID processObjectID : processObjectIDs) {
      [processNumbers addObject:@(processObjectID)];
    }

    CATapDescription* description = [[CATapDescription alloc] initStereoMixdownOfProcesses:processNumbers];
    description.privateTap = YES;
    description.muteBehavior = CATapMuted;
    description.name = [NSString stringWithFormat:@"LoopKit %@", bundleID];

    AudioObjectID tapID = kAudioObjectUnknown;
    OSStatus status = AudioHardwareCreateProcessTap(description, &tapID);
    if (status != noErr || tapID == kAudioObjectUnknown) {
      if (warningOut != nullptr) {
        *warningOut = "Failed to create process tap";
      }
      return nullptr;
    }

    NSString* uid = tapUID(tapID);
    if (uid.length == 0) {
      AudioHardwareDestroyProcessTap(tapID);
      if (warningOut != nullptr) {
        *warningOut = "Failed to read process tap UID";
      }
      return nullptr;
    }

    NSString* aggregateUID = [NSString stringWithFormat:@"com.example.LoopKit.tap.%@", NSUUID.UUID.UUIDString];
    NSDictionary* tapEntry = @{
      [NSString stringWithUTF8String:kAudioSubTapUIDKey]: uid,
      [NSString stringWithUTF8String:kAudioSubTapDriftCompensationKey]: @NO,
    };
    NSDictionary* aggregateDescription = @{
      [NSString stringWithUTF8String:kAudioAggregateDeviceNameKey]: [NSString stringWithFormat:@"LoopKit Tap %@", bundleID],
      [NSString stringWithUTF8String:kAudioAggregateDeviceUIDKey]: aggregateUID,
      [NSString stringWithUTF8String:kAudioAggregateDeviceIsPrivateKey]: @YES,
      [NSString stringWithUTF8String:kAudioAggregateDeviceTapListKey]: @[tapEntry],
      [NSString stringWithUTF8String:kAudioAggregateDeviceTapAutoStartKey]: @NO,
    };

    AudioObjectID aggregateID = kAudioObjectUnknown;
    status = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)aggregateDescription, &aggregateID);
    if (status != noErr || aggregateID == kAudioObjectUnknown) {
      AudioHardwareDestroyProcessTap(tapID);
      if (warningOut != nullptr) {
        *warningOut = "Failed to create aggregate tap device";
      }
      return nullptr;
    }

    std::shared_ptr<TapContext> context = std::make_shared<TapContext>();
    context->bundleID = toStdString(bundleID);
    context->pid = pid;
    context->tapID = tapID;
    context->aggregateID = aggregateID;
    context->processObjectIDs = processObjectIDs;
    double tapSampleRate = 48000.0;
    if (readTapSampleRate(tapID, &tapSampleRate)) {
      context->tapSampleRate = tapSampleRate;
    } else {
      context->tapSampleRate = 48000.0;
    }
    context->resampler = std::make_unique<loopkit::AsyncResampler>(
        context->tapSampleRate,
        48000.0,
        kTapResamplerCapacityFrames);

    status = AudioDeviceCreateIOProcID(aggregateID, tapDeviceIOProc, context.get(), &context->ioProcID);
    if (status != noErr || context->ioProcID == nullptr) {
      destroyTapContext(context);
      if (warningOut != nullptr) {
        *warningOut = "Failed to create IO callback for process tap";
      }
      return nullptr;
    }

    status = AudioDeviceStart(aggregateID, context->ioProcID);
    if (status != noErr) {
      destroyTapContext(context);
      if (warningOut != nullptr) {
        *warningOut = "Failed to start process tap capture";
      }
      return nullptr;
    }

    return context;
  }

  if (warningOut != nullptr) {
    *warningOut = "Process tap capture requires macOS 14.2+";
  }
  return nullptr;
}

@end
