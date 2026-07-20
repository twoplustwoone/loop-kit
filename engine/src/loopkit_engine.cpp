#include "loopkit_engine.h"

#include <algorithm>
#include <cmath>
#include <limits>

#if defined(__SSE__) || defined(__x86_64__) || defined(_M_X64)
#include <xmmintrin.h>
#include <pmmintrin.h>
#endif

namespace loopkit {

namespace {

constexpr float kMinGain = 0.0f;
constexpr float kMaxGain = 8.0f;
constexpr float kSaturationThreshold = 0.95f;
constexpr float kSaturationHeadroom = 1.0f - kSaturationThreshold;

// Flush denormals to zero on the realtime audio path. Denormals can cost
// orders of magnitude more CPU and are never audible; always undesirable here.
class DenormalFlushGuard {
public:
  DenormalFlushGuard() noexcept {
#if defined(__SSE__) || defined(__x86_64__) || defined(_M_X64)
    prev_mxcsr_ = _mm_getcsr();
    _mm_setcsr(prev_mxcsr_ | 0x8040u);  // FTZ (bit 15) + DAZ (bit 6)
#elif defined(__aarch64__)
    uint64_t fpcr = 0;
    __asm__ volatile("mrs %0, fpcr" : "=r"(fpcr));
    prev_fpcr_ = fpcr;
    __asm__ volatile("msr fpcr, %0" : : "r"(fpcr | (1ull << 24)));  // FZ bit
#endif
  }

  ~DenormalFlushGuard() noexcept {
#if defined(__SSE__) || defined(__x86_64__) || defined(_M_X64)
    _mm_setcsr(prev_mxcsr_);
#elif defined(__aarch64__)
    __asm__ volatile("msr fpcr, %0" : : "r"(prev_fpcr_));
#endif
  }

  DenormalFlushGuard(const DenormalFlushGuard&) = delete;
  DenormalFlushGuard& operator=(const DenormalFlushGuard&) = delete;

private:
#if defined(__SSE__) || defined(__x86_64__) || defined(_M_X64)
  unsigned int prev_mxcsr_ = 0;
#elif defined(__aarch64__)
  uint64_t prev_fpcr_ = 0;
#endif
};

float clampGain(float gain) noexcept {
  if (std::isnan(gain)) {
    return 1.0f;
  }
  return std::clamp(gain, kMinGain, kMaxGain);
}

bool blockIsUsable(const InputAudioBlock& block) noexcept {
  return block.frames > 0 && block.left != nullptr && block.right != nullptr;
}

bool blockIsUsable(const OutputAudioBlock& block) noexcept {
  return block.frames > 0 && block.left != nullptr && block.right != nullptr;
}

}  // namespace

Engine::Engine(const EngineConfig& config) : config_(config) {
  config_.sample_rate = config_.sample_rate == 0 ? kDefaultSampleRate : config_.sample_rate;
  if (config_.max_block_frames == 0 || config_.max_block_frames > kMaxBlockFrames) {
    config_.max_block_frames = kMaxBlockFrames;
  }

  source_params_[sourceIndex(SourceId::App)] = SourceParams{};
  source_params_[sourceIndex(SourceId::Mic)] = SourceParams{};
}

void Engine::setMasterGain(float gain) noexcept {
  master_gain_ = clampGain(gain);
}

float Engine::masterGain() const noexcept {
  return master_gain_;
}

void Engine::setSourceParams(SourceId source, const SourceParams& params) noexcept {
  const auto idx = sourceIndex(source);
  if (idx >= source_params_.size()) {
    return;
  }

  source_params_[idx] = params;
  source_params_[idx].gain = clampGain(params.gain);
}

SourceParams Engine::sourceParams(SourceId source) const noexcept {
  const auto idx = sourceIndex(source);
  if (idx >= source_params_.size()) {
    return SourceParams{};
  }
  return source_params_[idx];
}

void Engine::process(const InputAudioBlock& app_in,
                     const InputAudioBlock& mic_in,
                     const OutputAudioBlock& discord_out,
                     const OutputAudioBlock& monitor_out,
                     MeterBlock* meters_out) noexcept {
  DenormalFlushGuard denormal_guard;

  const uint32_t frame_count = frameCountForProcess(app_in, mic_in, discord_out, monitor_out);
  if (frame_count == 0) {
    if (meters_out != nullptr) {
      *meters_out = MeterBlock{};
    }
    return;
  }

  const bool app_usable = blockIsUsable(app_in);
  const bool mic_usable = blockIsUsable(mic_in);
  const bool discord_usable = blockIsUsable(discord_out);
  const bool monitor_usable = blockIsUsable(monitor_out);

  const auto app_params = source_params_[sourceIndex(SourceId::App)];
  const auto mic_params = source_params_[sourceIndex(SourceId::Mic)];
  const bool solo_active = hasAnySoloEnabled();

  auto sourceEnabled = [solo_active](const SourceParams& params) noexcept {
    if (!params.enabled || params.mute) {
      return false;
    }
    if (solo_active && !params.solo) {
      return false;
    }
    return true;
  };

  const bool app_enabled = sourceEnabled(app_params);
  const bool mic_enabled = sourceEnabled(mic_params);

  float peak_l = 0.0f;
  float peak_r = 0.0f;
  double sum_squares_l = 0.0;
  double sum_squares_r = 0.0;
  bool clipped_l = false;
  bool clipped_r = false;

  for (uint32_t frame = 0; frame < frame_count; ++frame) {
    float mix_l = 0.0f;
    float mix_r = 0.0f;

    if (app_enabled && app_usable) {
      mix_l += app_in.left[frame] * app_params.gain;
      mix_r += app_in.right[frame] * app_params.gain;
    }

    if (mic_enabled && mic_usable) {
      mix_l += mic_in.left[frame] * mic_params.gain;
      mix_r += mic_in.right[frame] * mic_params.gain;
    }

    mix_l *= master_gain_;
    mix_r *= master_gain_;

    clipped_l = clipped_l || std::abs(mix_l) > kSaturationThreshold;
    clipped_r = clipped_r || std::abs(mix_r) > kSaturationThreshold;

    mix_l = softClip(mix_l);
    mix_r = softClip(mix_r);

    if (discord_usable) {
      discord_out.left[frame] = mix_l;
      discord_out.right[frame] = mix_r;
    }

    if (monitor_usable) {
      monitor_out.left[frame] = mix_l;
      monitor_out.right[frame] = mix_r;
    }

    const float abs_l = std::abs(mix_l);
    const float abs_r = std::abs(mix_r);
    peak_l = std::max(peak_l, abs_l);
    peak_r = std::max(peak_r, abs_r);
    sum_squares_l += static_cast<double>(mix_l) * mix_l;
    sum_squares_r += static_cast<double>(mix_r) * mix_r;
  }

  if (meters_out != nullptr) {
    meters_out->peak_l = peak_l;
    meters_out->peak_r = peak_r;
    meters_out->rms_l =
        static_cast<float>(std::sqrt(sum_squares_l / static_cast<double>(frame_count)));
    meters_out->rms_r =
        static_cast<float>(std::sqrt(sum_squares_r / static_cast<double>(frame_count)));
    meters_out->clipped_l = clipped_l;
    meters_out->clipped_r = clipped_r;
  }
}

void Engine::processRouted(const InputAudioBlock& broadcast_app_in,
                           const InputAudioBlock& broadcast_mic_in,
                           const InputAudioBlock& monitor_app_in,
                           const InputAudioBlock& monitor_mic_in,
                           const OutputAudioBlock& broadcast_out,
                           const OutputAudioBlock& monitor_out,
                           MeterBlock* broadcast_meters_out,
                           MeterBlock* monitor_meters_out) noexcept {
  process(
      broadcast_app_in,
      broadcast_mic_in,
      broadcast_out,
      OutputAudioBlock{},
      broadcast_meters_out);
  process(
      monitor_app_in,
      monitor_mic_in,
      OutputAudioBlock{},
      monitor_out,
      monitor_meters_out);
}

bool Engine::hasAnySoloEnabled() const noexcept {
  for (const SourceParams& params : source_params_) {
    if (params.enabled && params.solo && !params.mute) {
      return true;
    }
  }
  return false;
}

float Engine::softClip(float sample) noexcept {
  const float abs_value = std::abs(sample);
  if (abs_value <= kSaturationThreshold) {
    return sample;
  }

  // Identity below the threshold, unit slope at the join, and an asymptote
  // at full scale. This keeps overload continuous and monotonic instead of
  // folding samples back toward zero.
  const float excess = abs_value - kSaturationThreshold;
  const float saturated = kSaturationThreshold
      + kSaturationHeadroom * (1.0f - std::exp(-excess / kSaturationHeadroom));
  return std::copysign(std::min(saturated, 1.0f), sample);
}

uint32_t Engine::frameCountForProcess(const InputAudioBlock& app_in,
                                      const InputAudioBlock& mic_in,
                                      const OutputAudioBlock& discord_out,
                                      const OutputAudioBlock& monitor_out) noexcept {
  uint32_t frame_count = std::numeric_limits<uint32_t>::max();
  bool has_count = false;

  auto include_count = [&](uint32_t frames) {
    if (frames == 0) {
      return;
    }
    has_count = true;
    frame_count = std::min(frame_count, frames);
  };

  include_count(app_in.frames);
  include_count(mic_in.frames);
  include_count(discord_out.frames);
  include_count(monitor_out.frames);

  return has_count ? frame_count : 0;
}

uint32_t Engine::sourceIndex(SourceId source) noexcept {
  return static_cast<uint32_t>(source);
}

}  // namespace loopkit
