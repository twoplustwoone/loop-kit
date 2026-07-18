#pragma once

#include <atomic>
#include <cstdint>
#include <vector>

namespace loopkit {

class AsyncResampler {
 public:
  AsyncResampler(double input_rate, double output_rate, uint32_t ring_capacity_frames);

  void reset();
  void setRates(double input_rate, double output_rate);
  void push(const float* left, const float* right, uint32_t frames);
  uint32_t pop(float* left, float* right, uint32_t frames);
  uint64_t underruns() const;
  uint64_t overruns() const;
  double fillRatio() const;

 private:
  static uint32_t nextPowerOfTwo(uint32_t value);

  uint32_t capacity_ = 0;
  uint32_t mask_ = 0;
  std::vector<float> left_;
  std::vector<float> right_;

  std::atomic<uint64_t> write_index_{0};
  std::atomic<double> read_index_{0.0};
  std::atomic<uint64_t> underruns_{0};
  std::atomic<uint64_t> overruns_{0};
  std::atomic<double> input_rate_{48000.0};
  std::atomic<double> output_rate_{48000.0};

  double target_fill_ = 0.5;
  double kp_ = 0.02;

  double baseRatio() const;
  double computeRatio(double fill_ratio) const;
};

}  // namespace loopkit
