#include "loopkit_c_api.h"

#include "loopkit_engine.h"

#include <new>

struct lk_engine_t {
  loopkit::Engine engine;

  explicit lk_engine_t(const loopkit::EngineConfig& config) : engine(config) {}
};

namespace {

loopkit::EngineConfig toCppConfig(const lk_engine_config* config) {
  if (config == nullptr) {
    return loopkit::EngineConfig{};
  }
  loopkit::EngineConfig out;
  out.sample_rate = config->sample_rate;
  out.max_block_frames = config->max_block_frames;
  return out;
}

loopkit::SourceId toCppSource(uint32_t source_id) {
  switch (source_id) {
    case LK_SOURCE_APP:
      return loopkit::SourceId::App;
    case LK_SOURCE_MIC:
      return loopkit::SourceId::Mic;
    default:
      return loopkit::SourceId::Count;
  }
}

loopkit::SourceParams toCppSourceParams(lk_source_params params) {
  loopkit::SourceParams out;
  out.gain = params.gain;
  out.mute = params.mute != 0;
  out.solo = params.solo != 0;
  out.enabled = params.enabled != 0;
  return out;
}

loopkit::InputAudioBlock toCppInputBlock(const lk_input_audio_block* block) {
  if (block == nullptr) {
    return loopkit::InputAudioBlock{};
  }
  loopkit::InputAudioBlock out;
  out.left = block->left;
  out.right = block->right;
  out.frames = block->frames;
  return out;
}

loopkit::OutputAudioBlock toCppOutputBlock(const lk_output_audio_block* block) {
  if (block == nullptr) {
    return loopkit::OutputAudioBlock{};
  }
  loopkit::OutputAudioBlock out;
  out.left = block->left;
  out.right = block->right;
  out.frames = block->frames;
  return out;
}

void toCBlock(const loopkit::MeterBlock& in, lk_meter_block* out) {
  if (out == nullptr) {
    return;
  }
  out->peak_l = in.peak_l;
  out->peak_r = in.peak_r;
  out->rms_l = in.rms_l;
  out->rms_r = in.rms_r;
}

}  // namespace

lk_engine_t* lk_engine_create(const lk_engine_config* config) {
  try {
    return new lk_engine_t(toCppConfig(config));
  } catch (const std::bad_alloc&) {
    return nullptr;
  } catch (...) {
    return nullptr;
  }
}

void lk_engine_destroy(lk_engine_t* engine) {
  delete engine;
}

void lk_engine_set_source_params(lk_engine_t* engine, uint32_t source_id, lk_source_params params) {
  if (engine == nullptr) {
    return;
  }
  const loopkit::SourceId source = toCppSource(source_id);
  if (source == loopkit::SourceId::Count) {
    return;
  }
  engine->engine.setSourceParams(source, toCppSourceParams(params));
}

void lk_engine_set_master_gain(lk_engine_t* engine, float gain) {
  if (engine == nullptr) {
    return;
  }
  engine->engine.setMasterGain(gain);
}

void lk_engine_process(lk_engine_t* engine,
                       const lk_input_audio_block* app_in,
                       const lk_input_audio_block* mic_in,
                       const lk_output_audio_block* discord_out,
                       const lk_output_audio_block* monitor_out,
                       lk_meter_block* meters_out) {
  if (engine == nullptr) {
    return;
  }

  const auto cpp_app = toCppInputBlock(app_in);
  const auto cpp_mic = toCppInputBlock(mic_in);
  const auto cpp_discord = toCppOutputBlock(discord_out);
  const auto cpp_monitor = toCppOutputBlock(monitor_out);

  loopkit::MeterBlock cpp_meters{};
  engine->engine.process(cpp_app, cpp_mic, cpp_discord, cpp_monitor,
                         meters_out == nullptr ? nullptr : &cpp_meters);
  if (meters_out != nullptr) {
    toCBlock(cpp_meters, meters_out);
  }
}

void lk_engine_process_routed(lk_engine_t* engine,
                              const lk_input_audio_block* broadcast_app_in,
                              const lk_input_audio_block* broadcast_mic_in,
                              const lk_input_audio_block* monitor_app_in,
                              const lk_input_audio_block* monitor_mic_in,
                              const lk_output_audio_block* broadcast_out,
                              const lk_output_audio_block* monitor_out,
                              lk_meter_block* broadcast_meters_out,
                              lk_meter_block* monitor_meters_out) {
  if (engine == nullptr) {
    return;
  }

  const auto cpp_broadcast_app = toCppInputBlock(broadcast_app_in);
  const auto cpp_broadcast_mic = toCppInputBlock(broadcast_mic_in);
  const auto cpp_monitor_app = toCppInputBlock(monitor_app_in);
  const auto cpp_monitor_mic = toCppInputBlock(monitor_mic_in);
  const auto cpp_broadcast_out = toCppOutputBlock(broadcast_out);
  const auto cpp_monitor_out = toCppOutputBlock(monitor_out);
  loopkit::MeterBlock broadcast_meters{};
  loopkit::MeterBlock monitor_meters{};

  engine->engine.processRouted(
      cpp_broadcast_app,
      cpp_broadcast_mic,
      cpp_monitor_app,
      cpp_monitor_mic,
      cpp_broadcast_out,
      cpp_monitor_out,
      broadcast_meters_out == nullptr ? nullptr : &broadcast_meters,
      monitor_meters_out == nullptr ? nullptr : &monitor_meters);

  if (broadcast_meters_out != nullptr) {
    toCBlock(broadcast_meters, broadcast_meters_out);
  }
  if (monitor_meters_out != nullptr) {
    toCBlock(monitor_meters, monitor_meters_out);
  }
}
