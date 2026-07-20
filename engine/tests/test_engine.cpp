#include "loopkit_engine.h"

#include <cmath>
#include <cstdlib>
#include <iostream>
#include <vector>

namespace {

bool near(float actual, float expected, float epsilon = 1e-4f) {
  return std::fabs(actual - expected) <= epsilon;
}

void expect(bool condition, const char* message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << "\n";
    std::exit(1);
  }
}

void testGainAndMixing() {
  loopkit::Engine engine;
  loopkit::SourceParams app_params;
  app_params.gain = 0.5f;
  loopkit::SourceParams mic_params;
  mic_params.gain = 1.0f;

  engine.setSourceParams(loopkit::SourceId::App, app_params);
  engine.setSourceParams(loopkit::SourceId::Mic, mic_params);
  engine.setMasterGain(1.0f);

  std::vector<float> app_l{0.4f, -0.2f, 0.6f, 0.0f};
  std::vector<float> app_r{0.1f, -0.1f, 0.3f, 0.0f};
  std::vector<float> mic_l{0.1f, 0.1f, -0.2f, 0.0f};
  std::vector<float> mic_r{0.1f, 0.1f, -0.2f, 0.0f};
  std::vector<float> out_l(4, 0.0f);
  std::vector<float> out_r(4, 0.0f);

  loopkit::InputAudioBlock app_in{app_l.data(), app_r.data(), static_cast<uint32_t>(app_l.size())};
  loopkit::InputAudioBlock mic_in{mic_l.data(), mic_r.data(), static_cast<uint32_t>(mic_l.size())};
  loopkit::OutputAudioBlock discord_out{out_l.data(), out_r.data(), static_cast<uint32_t>(out_l.size())};
  loopkit::OutputAudioBlock monitor_out{nullptr, nullptr, 0};

  loopkit::MeterBlock meters;
  engine.process(app_in, mic_in, discord_out, monitor_out, &meters);

  expect(near(out_l[0], 0.3f), "mixed left frame 0");
  expect(near(out_l[1], 0.0f), "mixed left frame 1");
  expect(near(out_l[2], 0.1f), "mixed left frame 2");
  expect(near(out_r[0], 0.15f), "mixed right frame 0");
  expect(near(out_r[1], 0.05f), "mixed right frame 1");
  expect(near(out_r[2], -0.05f), "mixed right frame 2");
  expect(meters.peak_l >= 0.3f, "peak meter left");
}

void testMuteAndSolo() {
  loopkit::Engine engine;
  loopkit::SourceParams app_params;
  app_params.gain = 1.0f;
  app_params.solo = true;
  loopkit::SourceParams mic_params;
  mic_params.gain = 1.0f;

  engine.setSourceParams(loopkit::SourceId::App, app_params);
  engine.setSourceParams(loopkit::SourceId::Mic, mic_params);

  std::vector<float> app_l{0.5f};
  std::vector<float> app_r{0.5f};
  std::vector<float> mic_l{0.5f};
  std::vector<float> mic_r{0.5f};
  std::vector<float> out_l(1, 0.0f);
  std::vector<float> out_r(1, 0.0f);

  loopkit::InputAudioBlock app_in{app_l.data(), app_r.data(), 1};
  loopkit::InputAudioBlock mic_in{mic_l.data(), mic_r.data(), 1};
  loopkit::OutputAudioBlock out{out_l.data(), out_r.data(), 1};
  loopkit::MeterBlock meters;
  engine.process(app_in, mic_in, out, out, &meters);

  expect(near(out_l[0], 0.5f), "solo excludes non-solo source");

  app_params.solo = false;
  app_params.mute = true;
  mic_params.solo = false;
  mic_params.mute = false;
  engine.setSourceParams(loopkit::SourceId::App, app_params);
  engine.setSourceParams(loopkit::SourceId::Mic, mic_params);
  engine.process(app_in, mic_in, out, out, &meters);
  expect(near(out_l[0], 0.5f), "muted source ignored");
}

void testLimiterAndMeters() {
  loopkit::Engine engine;
  engine.setMasterGain(4.0f);

  std::vector<float> app_l{1.0f, -1.0f};
  std::vector<float> app_r{1.0f, -1.0f};
  std::vector<float> zeros{0.0f, 0.0f};
  std::vector<float> out_l(2, 0.0f);
  std::vector<float> out_r(2, 0.0f);

  loopkit::InputAudioBlock app_in{app_l.data(), app_r.data(), 2};
  loopkit::InputAudioBlock mic_in{zeros.data(), zeros.data(), 2};
  loopkit::OutputAudioBlock out{out_l.data(), out_r.data(), 2};
  loopkit::MeterBlock meters;
  engine.process(app_in, mic_in, out, out, &meters);

  expect(std::fabs(out_l[0]) <= 1.0f, "soft clipping upper bound");
  expect(std::fabs(out_l[1]) <= 1.0f, "soft clipping lower bound");
  expect(meters.peak_l <= 1.0f, "peak meter bound");
  expect(meters.rms_l > 0.0f, "rms meter non-zero");
  expect(meters.clipped_l, "pre-limiter clipping reported on left");
  expect(meters.clipped_r, "pre-limiter clipping reported on right");
}

float processSample(float sample, loopkit::MeterBlock* meters = nullptr) {
  loopkit::Engine engine;
  const float zero = 0.0f;
  float output = 0.0f;
  loopkit::InputAudioBlock app{&sample, &sample, 1};
  loopkit::InputAudioBlock mic{&zero, &zero, 1};
  loopkit::OutputAudioBlock out{&output, &output, 1};
  loopkit::MeterBlock local_meters;
  engine.process(app, mic, out, {}, meters == nullptr ? &local_meters : meters);
  return output;
}

void testSaturationCurveIsContinuousAndMonotonic() {
  expect(near(processSample(0.94f), 0.94f), "saturation preserves quiet samples");
  expect(near(processSample(0.95f), 0.95f), "saturation preserves threshold sample");

  const float left = processSample(0.95f - 1e-5f);
  const float right = processSample(0.95f + 1e-5f);
  expect(std::fabs(right - left) < 3e-5f, "saturation is continuous at threshold");

  float previous = processSample(0.0f);
  for (int step = 1; step <= 8000; ++step) {
    const float input = static_cast<float>(step) / 1000.0f;
    const float output = processSample(input);
    expect(output + 1e-6f >= previous, "positive saturation sweep is monotonic");
    expect(output <= 1.0f, "positive saturation sweep stays in range");
    expect(near(processSample(-input), -output, 1e-5f), "saturation has odd symmetry");
    previous = output;
  }

  loopkit::MeterBlock below;
  (void)processSample(0.95f, &below);
  expect(!below.clipped_l && !below.clipped_r, "threshold sample does not clip");
  loopkit::MeterBlock above;
  (void)processSample(0.951f, &above);
  expect(above.clipped_l && above.clipped_r, "over-threshold sample reports clipping");
}

void testNaNAndOutOfRangeGainClamped() {
  loopkit::Engine engine;
  loopkit::SourceParams p;
  p.gain = std::nanf("");
  engine.setSourceParams(loopkit::SourceId::App, p);
  expect(near(engine.sourceParams(loopkit::SourceId::App).gain, 1.0f),
         "NaN gain reset to 1.0");

  p.gain = 1e9f;
  engine.setSourceParams(loopkit::SourceId::App, p);
  expect(engine.sourceParams(loopkit::SourceId::App).gain <= 8.0f,
         "Gigantic gain clamped to upper bound");

  p.gain = -3.0f;
  engine.setSourceParams(loopkit::SourceId::App, p);
  expect(engine.sourceParams(loopkit::SourceId::App).gain >= 0.0f,
         "Negative gain clamped to 0");
}

void testSoloMuteEnabledPermutations() {
  // Cover every 2x2x2x2 combination of {enabled, mute, solo} across app + mic
  // and confirm the active-source predicate behaves sensibly.
  for (int appEnabled = 0; appEnabled <= 1; ++appEnabled) {
    for (int appMute = 0; appMute <= 1; ++appMute) {
      for (int appSolo = 0; appSolo <= 1; ++appSolo) {
        for (int micSolo = 0; micSolo <= 1; ++micSolo) {
          loopkit::Engine engine;
          loopkit::SourceParams app;
          app.gain = 1.0f;
          app.enabled = appEnabled != 0;
          app.mute = appMute != 0;
          app.solo = appSolo != 0;
          loopkit::SourceParams mic;
          mic.gain = 1.0f;
          mic.enabled = true;
          mic.mute = false;
          mic.solo = micSolo != 0;

          engine.setSourceParams(loopkit::SourceId::App, app);
          engine.setSourceParams(loopkit::SourceId::Mic, mic);

          std::vector<float> app_l{0.5f};
          std::vector<float> mic_l{0.25f};
          std::vector<float> app_r{0.5f};
          std::vector<float> mic_r{0.25f};
          std::vector<float> out_l(1, 0.0f);
          std::vector<float> out_r(1, 0.0f);

          loopkit::InputAudioBlock ain{app_l.data(), app_r.data(), 1};
          loopkit::InputAudioBlock min_{mic_l.data(), mic_r.data(), 1};
          loopkit::OutputAudioBlock o{out_l.data(), out_r.data(), 1};
          loopkit::MeterBlock meters;
          engine.process(ain, min_, o, o, &meters);

          const bool anySolo = (appEnabled != 0 && appMute == 0 && appSolo != 0) || micSolo != 0;
          const bool appActive = appEnabled != 0 && appMute == 0 && (!anySolo || appSolo != 0);
          const bool micActive = (!anySolo || micSolo != 0);

          float expected = 0.0f;
          if (appActive) expected += 0.5f;
          if (micActive) expected += 0.25f;

          expect(near(out_l[0], expected, 1e-4f),
                 "solo/mute/enabled permutation produces expected mix");
        }
      }
    }
  }
}

void testFiniteOutputOnExtremeInput() {
  // Denormal inputs (post-P1.1) and clipped inputs both must produce finite
  // output. Deliberately crafts subnormal and infinity-like inputs to confirm
  // the FTZ guard + soft clipper keep the pipeline well-behaved.
  loopkit::Engine engine;
  engine.setMasterGain(1.0f);

  std::vector<float> extreme_l{1e-40f, 1e-40f, 1.5f, -1.5f};
  std::vector<float> extreme_r = extreme_l;
  std::vector<float> zeros(4, 0.0f);
  std::vector<float> out_l(4, 0.0f);
  std::vector<float> out_r(4, 0.0f);

  loopkit::InputAudioBlock app_in{extreme_l.data(), extreme_r.data(), 4};
  loopkit::InputAudioBlock mic_in{zeros.data(), zeros.data(), 4};
  loopkit::OutputAudioBlock out{out_l.data(), out_r.data(), 4};
  loopkit::MeterBlock meters;
  engine.process(app_in, mic_in, out, out, &meters);

  for (float v : out_l) {
    expect(std::isfinite(v), "output is finite under denormal/clipped input");
  }
  expect(meters.peak_l <= 1.0f, "peak meter stays in [0,1]");
  expect(std::isfinite(meters.rms_l), "rms meter is finite");
}

void testIndependentDestinationInputs() {
  loopkit::Engine engine;
  std::vector<float> broadcast_app{0.4f};
  std::vector<float> monitor_app{0.1f};
  std::vector<float> mic{0.2f};
  std::vector<float> broadcast_l(1, 0.0f);
  std::vector<float> broadcast_r(1, 0.0f);
  std::vector<float> monitor_l(1, 0.0f);
  std::vector<float> monitor_r(1, 0.0f);

  loopkit::InputAudioBlock broadcast_app_in{broadcast_app.data(), broadcast_app.data(), 1};
  loopkit::InputAudioBlock broadcast_mic_in{mic.data(), mic.data(), 1};
  loopkit::InputAudioBlock monitor_app_in{monitor_app.data(), monitor_app.data(), 1};
  loopkit::InputAudioBlock disconnected_mic{};
  loopkit::OutputAudioBlock broadcast_out{broadcast_l.data(), broadcast_r.data(), 1};
  loopkit::OutputAudioBlock monitor_out{monitor_l.data(), monitor_r.data(), 1};
  loopkit::MeterBlock broadcast_meters;
  loopkit::MeterBlock monitor_meters;

  engine.processRouted(
      broadcast_app_in,
      broadcast_mic_in,
      monitor_app_in,
      disconnected_mic,
      broadcast_out,
      monitor_out,
      &broadcast_meters,
      &monitor_meters);

  expect(near(broadcast_l[0], 0.6f), "broadcast uses its routed app and mic inputs");
  expect(near(monitor_l[0], 0.1f), "monitor excludes a disconnected mic route");
  expect(broadcast_meters.peak_l > monitor_meters.peak_l, "destination meters are independent");
}

}  // namespace

int main() {
  testGainAndMixing();
  testMuteAndSolo();
  testLimiterAndMeters();
  testSaturationCurveIsContinuousAndMonotonic();
  testNaNAndOutOfRangeGainClamped();
  testSoloMuteEnabledPermutations();
  testFiniteOutputOnExtremeInput();
  testIndependentDestinationInputs();
  std::cout << "loopkit_engine_tests: PASS\n";
  return 0;
}
