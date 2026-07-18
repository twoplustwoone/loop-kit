#include "loopkit_resampler.h"

#include <algorithm>
#include <cmath>

namespace loopkit {

namespace {

double clamp(double value, double lo, double hi) {
  return std::max(lo, std::min(value, hi));
}

}  // namespace

uint32_t AsyncResampler::nextPowerOfTwo(uint32_t value) {
  if (value == 0) {
    return 1;
  }
  value--;
  value |= value >> 1;
  value |= value >> 2;
  value |= value >> 4;
  value |= value >> 8;
  value |= value >> 16;
  return value + 1;
}

AsyncResampler::AsyncResampler(double input_rate, double output_rate, uint32_t ring_capacity_frames) {
  const uint32_t capacity = nextPowerOfTwo(std::max<uint32_t>(ring_capacity_frames, 64));
  capacity_ = capacity;
  mask_ = capacity_ - 1;
  left_.resize(capacity_);
  right_.resize(capacity_);
  input_rate_.store(input_rate > 0.0 ? input_rate : 48000.0, std::memory_order_relaxed);
  output_rate_.store(output_rate > 0.0 ? output_rate : 48000.0, std::memory_order_relaxed);
  reset();
}

void AsyncResampler::reset() {
  write_index_.store(0, std::memory_order_relaxed);
  read_index_.store(0.0, std::memory_order_relaxed);
  underruns_.store(0, std::memory_order_relaxed);
  overruns_.store(0, std::memory_order_relaxed);
}

void AsyncResampler::setRates(double input_rate, double output_rate) {
  if (input_rate > 0.0) {
    input_rate_.store(input_rate, std::memory_order_relaxed);
  }
  if (output_rate > 0.0) {
    output_rate_.store(output_rate, std::memory_order_relaxed);
  }
}

void AsyncResampler::push(const float* left, const float* right, uint32_t frames) {
  if (left == nullptr || right == nullptr || frames == 0 || capacity_ == 0) {
    return;
  }

  uint64_t write = write_index_.load(std::memory_order_relaxed);
  double read = read_index_.load(std::memory_order_acquire);
  if (read > static_cast<double>(write)) {
    read = static_cast<double>(write);
  }

  if (frames >= capacity_) {
    const uint32_t keep = capacity_;
    left += (frames - keep);
    right += (frames - keep);
    frames = keep;
    read = static_cast<double>(write);
    overruns_.fetch_add(1, std::memory_order_relaxed);
  } else {
    const double used = static_cast<double>(write) - read;
    if (used + static_cast<double>(frames) > static_cast<double>(capacity_)) {
      const double drop = used + static_cast<double>(frames) - static_cast<double>(capacity_);
      read += drop;
      overruns_.fetch_add(1, std::memory_order_relaxed);
    }
  }

  read_index_.store(read, std::memory_order_release);

  for (uint32_t i = 0; i < frames; ++i) {
    const uint32_t index = static_cast<uint32_t>((write + i) & mask_);
    left_[index] = left[i];
    right_[index] = right[i];
  }
  write_index_.store(write + frames, std::memory_order_release);
}

uint32_t AsyncResampler::pop(float* left, float* right, uint32_t frames) {
  if (left == nullptr || right == nullptr || frames == 0 || capacity_ == 0) {
    return 0;
  }

  uint64_t write = write_index_.load(std::memory_order_acquire);
  double read = read_index_.load(std::memory_order_relaxed);
  if (read < 0.0) {
    read = 0.0;
  }

  uint32_t produced = 0;
  for (; produced < frames; ++produced) {
    const double available = static_cast<double>(write) - read;
    if (available < 1.0) {
      for (uint32_t i = produced; i < frames; ++i) {
        left[i] = 0.0f;
        right[i] = 0.0f;
      }
      underruns_.fetch_add(1, std::memory_order_relaxed);
      break;
    }

    const double fill_ratio = clamp(available / static_cast<double>(capacity_), 0.0, 1.0);
    const double ratio = computeRatio(fill_ratio);

    const uint64_t i0 = static_cast<uint64_t>(read);
    uint64_t i1 = i0 + 1;
    if (i1 >= write) {
      i1 = i0;
    }

    const float frac = static_cast<float>(read - static_cast<double>(i0));
    const uint32_t index0 = static_cast<uint32_t>(i0 & mask_);
    const uint32_t index1 = static_cast<uint32_t>(i1 & mask_);

    const float l0 = left_[index0];
    const float r0 = right_[index0];
    const float l1 = left_[index1];
    const float r1 = right_[index1];

    left[produced] = l0 + (l1 - l0) * frac;
    right[produced] = r0 + (r1 - r0) * frac;

    read += ratio;
  }

  read_index_.store(read, std::memory_order_release);
  return frames;
}

uint64_t AsyncResampler::underruns() const {
  return underruns_.load(std::memory_order_relaxed);
}

uint64_t AsyncResampler::overruns() const {
  return overruns_.load(std::memory_order_relaxed);
}

double AsyncResampler::fillRatio() const {
  const uint64_t write = write_index_.load(std::memory_order_acquire);
  const double read = read_index_.load(std::memory_order_relaxed);
  if (capacity_ == 0) {
    return 0.0;
  }
  const double available = static_cast<double>(write) - read;
  return clamp(available / static_cast<double>(capacity_), 0.0, 1.0);
}

double AsyncResampler::baseRatio() const {
  const double input = input_rate_.load(std::memory_order_relaxed);
  const double output = output_rate_.load(std::memory_order_relaxed);
  if (input <= 0.0 || output <= 0.0) {
    return 1.0;
  }
  return input / output;
}

double AsyncResampler::computeRatio(double fill_ratio) const {
  const double base = baseRatio();
  const double error = fill_ratio - target_fill_;
  const double adjust = clamp(1.0 + kp_ * error, 0.995, 1.005);
  return base * adjust;
}

}  // namespace loopkit
