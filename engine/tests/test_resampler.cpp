#include "loopkit_resampler.h"

#include <cmath>
#include <cstdlib>
#include <iostream>
#include <vector>

namespace {

constexpr double kPi = 3.14159265358979323846;

bool near(double actual, double expected, double epsilon) {
  return std::fabs(actual - expected) <= epsilon;
}

void expect(bool condition, const char* message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << "\n";
    std::exit(1);
  }
}

struct ToneGenerator {
  double phase = 0.0;
  double phase_inc = 0.0;

  ToneGenerator(double frequency, double sample_rate) {
    phase_inc = (2.0 * kPi * frequency) / sample_rate;
  }

  float next() {
    const float value = static_cast<float>(std::sin(phase));
    phase += phase_inc;
    if (phase > 2.0 * kPi) {
      phase -= 2.0 * kPi;
    }
    return value;
  }
};

double estimateFrequency(const std::vector<float>& signal, double sample_rate) {
  int crossings = 0;
  for (size_t i = 1; i < signal.size(); ++i) {
    if (signal[i - 1] <= 0.0f && signal[i] > 0.0f) {
      crossings++;
    }
  }
  const double duration = static_cast<double>(signal.size()) / sample_rate;
  if (duration <= 0.0) {
    return 0.0;
  }
  return static_cast<double>(crossings) / duration;
}

void testRateConversion() {
  const double input_rate = 44100.0;
  const double output_rate = 48000.0;
  loopkit::AsyncResampler resampler(input_rate, output_rate, 8192);

  ToneGenerator tone(440.0, input_rate);
  const uint32_t chunk = 256;
  const double seconds = 3.0;
  const uint32_t output_frames = static_cast<uint32_t>(seconds * output_rate);

  std::vector<float> out_l;
  out_l.reserve(output_frames);
  std::vector<float> out_r;
  out_r.reserve(output_frames);

  double output_time = 0.0;
  double input_time = 0.0;
  const double dt_out = static_cast<double>(chunk) / output_rate;

  while (out_l.size() < output_frames) {
    const double next_out_time = output_time + dt_out;
    const double dt_in = next_out_time - input_time;
    const uint32_t input_frames = static_cast<uint32_t>(std::ceil(dt_in * input_rate));

    std::vector<float> in_l(input_frames);
    std::vector<float> in_r(input_frames);
    for (uint32_t i = 0; i < input_frames; ++i) {
      const float sample = tone.next();
      in_l[i] = sample;
      in_r[i] = sample;
    }
    resampler.push(in_l.data(), in_r.data(), input_frames);
    input_time += static_cast<double>(input_frames) / input_rate;

    std::vector<float> tmp_l(chunk);
    std::vector<float> tmp_r(chunk);
    resampler.pop(tmp_l.data(), tmp_r.data(), chunk);

    out_l.insert(out_l.end(), tmp_l.begin(), tmp_l.end());
    out_r.insert(out_r.end(), tmp_r.begin(), tmp_r.end());
    output_time = next_out_time;
  }

  const size_t warmup = static_cast<size_t>(0.5 * output_rate);
  std::vector<float> window(out_l.begin() + warmup, out_l.begin() + warmup + static_cast<size_t>(1.5 * output_rate));
  const double frequency = estimateFrequency(window, output_rate);
  const double error = std::fabs(frequency - 440.0) / 440.0;
  expect(error <= 0.005, "pitch error within 0.5%");
}

void testClockDrift() {
  const double input_rate = 44100.0;
  const double output_rate = 48000.0;
  const double ppm = 100.0;
  const double drift_rate = input_rate * (1.0 + ppm / 1'000'000.0);

  loopkit::AsyncResampler resampler(input_rate, output_rate, 8192);
  ToneGenerator tone(440.0, drift_rate);

  const uint32_t chunk = 256;
  const double seconds = 120.0;
  const uint32_t iterations = static_cast<uint32_t>((seconds * output_rate) / chunk);

  double input_fractional = 0.0;
  for (uint32_t i = 0; i < iterations; ++i) {
    const double dt_out = static_cast<double>(chunk) / output_rate;
    const double input_needed = dt_out * drift_rate + input_fractional;
    const uint32_t input_frames = static_cast<uint32_t>(input_needed);
    input_fractional = input_needed - static_cast<double>(input_frames);

    std::vector<float> in_l(input_frames);
    std::vector<float> in_r(input_frames);
    for (uint32_t j = 0; j < input_frames; ++j) {
      const float sample = tone.next();
      in_l[j] = sample;
      in_r[j] = sample;
    }
    resampler.push(in_l.data(), in_r.data(), input_frames);

    std::vector<float> out_l(chunk);
    std::vector<float> out_r(chunk);
    resampler.pop(out_l.data(), out_r.data(), chunk);
  }

  const double fill = resampler.fillRatio();
  expect(fill >= 0.25 && fill <= 0.75, "fill ratio stays within bounds");
}

void testUnderrunHandling() {
  loopkit::AsyncResampler resampler(44100.0, 48000.0, 4096);
  ToneGenerator tone(440.0, 44100.0);

  std::vector<float> in_l(512);
  std::vector<float> in_r(512);
  for (uint32_t i = 0; i < in_l.size(); ++i) {
    const float sample = tone.next();
    in_l[i] = sample;
    in_r[i] = sample;
  }
  resampler.push(in_l.data(), in_r.data(), static_cast<uint32_t>(in_l.size()));

  std::vector<float> out_l(1024);
  std::vector<float> out_r(1024);
  resampler.pop(out_l.data(), out_r.data(), static_cast<uint32_t>(out_l.size()));

  // Drain without pushing more to induce underrun.
  resampler.pop(out_l.data(), out_r.data(), static_cast<uint32_t>(out_l.size()));

  float max_abs = 0.0f;
  for (float value : out_l) {
    max_abs = std::max(max_abs, std::fabs(value));
  }
  expect(max_abs <= 1e-3f, "underrun outputs silence");
  expect(resampler.underruns() > 0, "underrun counter increments");
}

void testOverrunHandling() {
  loopkit::AsyncResampler resampler(44100.0, 48000.0, 4096);
  ToneGenerator tone(440.0, 44100.0);

  const uint32_t chunk = 256;
  for (int i = 0; i < 500; ++i) {
    const uint32_t input_frames = static_cast<uint32_t>(chunk * 1.1);
    std::vector<float> in_l(input_frames);
    std::vector<float> in_r(input_frames);
    for (uint32_t j = 0; j < input_frames; ++j) {
      const float sample = tone.next();
      in_l[j] = sample;
      in_r[j] = sample;
    }
    resampler.push(in_l.data(), in_r.data(), input_frames);

    std::vector<float> out_l(chunk);
    std::vector<float> out_r(chunk);
    resampler.pop(out_l.data(), out_r.data(), chunk);
  }

  expect(resampler.overruns() > 0, "overrun counter increments");
  const double fill = resampler.fillRatio();
  expect(fill <= 1.0, "fill ratio stays valid");
}

void testStereoCoherence() {
  loopkit::AsyncResampler resampler(44100.0, 48000.0, 4096);
  ToneGenerator tone(440.0, 44100.0);

  std::vector<float> in_l(512);
  std::vector<float> in_r(512);
  for (uint32_t i = 0; i < in_l.size(); ++i) {
    const float sample = tone.next();
    in_l[i] = sample;
    in_r[i] = sample;
  }
  resampler.push(in_l.data(), in_r.data(), static_cast<uint32_t>(in_l.size()));

  std::vector<float> out_l(512);
  std::vector<float> out_r(512);
  resampler.pop(out_l.data(), out_r.data(), static_cast<uint32_t>(out_l.size()));

  float max_diff = 0.0f;
  for (size_t i = 0; i < out_l.size(); ++i) {
    max_diff = std::max(max_diff, std::fabs(out_l[i] - out_r[i]));
  }
  expect(max_diff < 1e-4f, "stereo channels remain coherent");
}

}  // namespace

int main() {
  testRateConversion();
  testClockDrift();
  testUnderrunHandling();
  testOverrunHandling();
  testStereoCoherence();
  std::cout << "loopkit_resampler_tests: PASS\n";
  return 0;
}
