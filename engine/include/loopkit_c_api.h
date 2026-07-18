#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct lk_engine_t lk_engine_t;

enum {
  LK_SOURCE_APP = 0,
  LK_SOURCE_MIC = 1,
};

typedef struct lk_engine_config {
  uint32_t sample_rate;
  uint32_t max_block_frames;
} lk_engine_config;

typedef struct lk_source_params {
  float gain;
  uint8_t mute;
  uint8_t solo;
  uint8_t enabled;
} lk_source_params;

typedef struct lk_input_audio_block {
  const float* left;
  const float* right;
  uint32_t frames;
} lk_input_audio_block;

typedef struct lk_output_audio_block {
  float* left;
  float* right;
  uint32_t frames;
} lk_output_audio_block;

typedef struct lk_meter_block {
  float peak_l;
  float peak_r;
  float rms_l;
  float rms_r;
} lk_meter_block;

lk_engine_t* lk_engine_create(const lk_engine_config* config);
void lk_engine_destroy(lk_engine_t* engine);

void lk_engine_set_source_params(lk_engine_t* engine, uint32_t source_id, lk_source_params params);
void lk_engine_set_master_gain(lk_engine_t* engine, float gain);

void lk_engine_process(lk_engine_t* engine,
                       const lk_input_audio_block* app_in,
                       const lk_input_audio_block* mic_in,
                       const lk_output_audio_block* discord_out,
                       const lk_output_audio_block* monitor_out,
                       lk_meter_block* meters_out);

void lk_engine_process_routed(lk_engine_t* engine,
                              const lk_input_audio_block* broadcast_app_in,
                              const lk_input_audio_block* broadcast_mic_in,
                              const lk_input_audio_block* monitor_app_in,
                              const lk_input_audio_block* monitor_mic_in,
                              const lk_output_audio_block* broadcast_out,
                              const lk_output_audio_block* monitor_out,
                              lk_meter_block* broadcast_meters_out,
                              lk_meter_block* monitor_meters_out);

#ifdef __cplusplus
}  // extern "C"
#endif
