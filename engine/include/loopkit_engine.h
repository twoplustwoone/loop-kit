#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace loopkit {

constexpr uint32_t kDefaultSampleRate = 48000;
constexpr uint32_t kDefaultBlockFrames = 128;
constexpr uint32_t kFallbackBlockFrames = 256;
constexpr uint32_t kMaxBlockFrames = 256;

enum class SourceId : uint32_t {
  App = 0,
  Mic = 1,
  Count = 2,
};

struct SourceParams {
  float gain = 1.0f;
  bool mute = false;
  bool solo = false;
  bool enabled = true;
};

struct EngineConfig {
  uint32_t sample_rate = kDefaultSampleRate;
  uint32_t max_block_frames = kMaxBlockFrames;
};

struct InputAudioBlock {
  const float* left = nullptr;
  const float* right = nullptr;
  uint32_t frames = 0;
};

struct OutputAudioBlock {
  float* left = nullptr;
  float* right = nullptr;
  uint32_t frames = 0;
};

struct MeterBlock {
  float peak_l = 0.0f;
  float peak_r = 0.0f;
  float rms_l = 0.0f;
  float rms_r = 0.0f;
  bool clipped_l = false;
  bool clipped_r = false;
};

class Engine {
public:
  explicit Engine(const EngineConfig& config = {});

  void setMasterGain(float gain) noexcept;
  [[nodiscard]] float masterGain() const noexcept;

  void setSourceParams(SourceId source, const SourceParams& params) noexcept;
  [[nodiscard]] SourceParams sourceParams(SourceId source) const noexcept;

  void process(const InputAudioBlock& app_in,
               const InputAudioBlock& mic_in,
               const OutputAudioBlock& discord_out,
               const OutputAudioBlock& monitor_out,
               MeterBlock* meters_out) noexcept;

  void processRouted(const InputAudioBlock& broadcast_app_in,
                     const InputAudioBlock& broadcast_mic_in,
                     const InputAudioBlock& monitor_app_in,
                     const InputAudioBlock& monitor_mic_in,
                     const OutputAudioBlock& broadcast_out,
                     const OutputAudioBlock& monitor_out,
                     MeterBlock* broadcast_meters_out,
                     MeterBlock* monitor_meters_out) noexcept;

private:
  [[nodiscard]] bool hasAnySoloEnabled() const noexcept;
  [[nodiscard]] static float softClip(float sample) noexcept;
  [[nodiscard]] static uint32_t frameCountForProcess(const InputAudioBlock& app_in,
                                                     const InputAudioBlock& mic_in,
                                                     const OutputAudioBlock& discord_out,
                                                     const OutputAudioBlock& monitor_out) noexcept;
  [[nodiscard]] static uint32_t sourceIndex(SourceId source) noexcept;

  EngineConfig config_;
  std::array<SourceParams, static_cast<size_t>(SourceId::Count)> source_params_{};
  float master_gain_ = 1.0f;
};

}  // namespace loopkit
