import AVFoundation
import Foundation

struct Options {
  var duration: Double = 5.0
  var frequency: Double = 440.0
  var amplitude: Double = 0.2
  var playTone: Bool = true
}

func parseOptions() -> Options {
  var options = Options()
  var iterator = CommandLine.arguments.dropFirst().makeIterator()
  while let arg = iterator.next() {
    switch arg {
    case "--duration", "-d":
      if let value = iterator.next(), let parsed = Double(value) {
        options.duration = parsed
      }
    case "--frequency", "-f":
      if let value = iterator.next(), let parsed = Double(value) {
        options.frequency = parsed
      }
    case "--amplitude", "-a":
      if let value = iterator.next(), let parsed = Double(value) {
        options.amplitude = parsed
      }
    case "--no-play":
      options.playTone = false
    default:
      break
    }
  }
  return options
}

func estimateFrequency(_ samples: [Float], sampleRate: Double) -> Double {
  guard samples.count > 1 else { return 0.0 }
  var crossings = 0
  for i in 1..<samples.count {
    if samples[i - 1] <= 0 && samples[i] > 0 {
      crossings += 1
    }
  }
  let duration = Double(samples.count) / sampleRate
  guard duration > 0 else { return 0.0 }
  return Double(crossings) / duration
}

func glitchRatio(_ samples: [Float]) -> Double {
  guard samples.count > 1 else { return 0.0 }
  var glitches = 0
  for i in 1..<samples.count {
    if abs(samples[i] - samples[i - 1]) > 0.3 {
      glitches += 1
    }
  }
  return Double(glitches) / Double(samples.count - 1)
}

let options = parseOptions()

let engine = AVAudioEngine()
let input = engine.inputNode
let format = input.outputFormat(forBus: 0)
let sampleRate = format.sampleRate
let totalFrames = Int(options.duration * sampleRate)
let output = engine.outputNode
let outputFormat = output.outputFormat(forBus: 0)
let toneSampleRate = outputFormat.sampleRate
let toneChannels = max(outputFormat.channelCount, 1)
let toneFormat = AVAudioFormat(standardFormatWithSampleRate: toneSampleRate, channels: toneChannels)!

var toneNode: AVAudioSourceNode?
if options.playTone {
  var phase = 0.0
  let amplitude = max(0.0, min(options.amplitude, 1.0))
  let phaseInc = (2.0 * Double.pi * options.frequency) / toneSampleRate

  let node = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
    let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
    for frame in 0..<Int(frameCount) {
      let sample = Float(sin(phase) * amplitude)
      phase += phaseInc
      if phase > 2.0 * Double.pi {
        phase -= 2.0 * Double.pi
      }
      for buffer in abl {
        let ptr = buffer.mData!.assumingMemoryBound(to: Float.self)
        ptr[frame] = sample
      }
    }
    return noErr
  }
  toneNode = node
  engine.attach(node)
  engine.connect(node, to: engine.mainMixerNode, format: toneFormat)
}

var samples: [Float] = []
samples.reserveCapacity(totalFrames)

let bufferSize: AVAudioFrameCount = 1024
input.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in
  guard let channelData = buffer.floatChannelData else { return }
  let channel = channelData[0]
  let frames = Int(buffer.frameLength)
  let remaining = totalFrames - samples.count
  if remaining <= 0 { return }
  let toCopy = min(frames, remaining)
  samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: toCopy))
}

do {
  try engine.start()
} catch {
  fputs("Failed to start audio engine: \(error)\n", stderr)
  exit(1)
}

let start = Date()
while samples.count < totalFrames {
  RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
  if Date().timeIntervalSince(start) > options.duration + 1.0 {
    break
  }
}

engine.stop()
input.removeTap(onBus: 0)
if let node = toneNode {
  engine.detach(node)
}

if samples.isEmpty {
  fputs("No audio captured. Ensure the intended input device (for example, BlackHole 2ch) is selected and permissions are granted.\n", stderr)
  exit(1)
}

let warmup = Int(0.5 * sampleRate)
let analysisStart = min(warmup, samples.count)
let analysisCount = max(0, samples.count - analysisStart)
let analysisSamples = Array(samples[analysisStart..<analysisStart + analysisCount])

let freq = estimateFrequency(analysisSamples, sampleRate: sampleRate)
let glitch = glitchRatio(analysisSamples)

let half = analysisSamples.count / 2
let freqStart = estimateFrequency(Array(analysisSamples.prefix(half)), sampleRate: sampleRate)
let freqEnd = estimateFrequency(Array(analysisSamples.suffix(half)), sampleRate: sampleRate)
let drift = freqStart > 0 ? (freqEnd - freqStart) / freqStart * 100.0 : 0.0

print("LoopKit loopback capture")
print("Duration: \(options.duration)s")
print("Sample rate: \(Int(sampleRate)) Hz")
print("Tone: \(options.playTone ? "on" : "off") \(String(format: "%.1f", options.frequency)) Hz @ \(String(format: "%.2f", options.amplitude))")
print("Estimated frequency: \(String(format: "%.2f", freq)) Hz (target \(options.frequency) Hz)")
print("Glitch ratio: \(String(format: "%.4f", glitch))")
print("Drift (relative %): \(String(format: "%.3f", drift))")

let pitchError = options.frequency > 0 ? abs(freq - options.frequency) / options.frequency : 0.0
let passPitch = pitchError <= 0.005
let passGlitch = glitch <= 0.001

if passPitch && passGlitch {
  print("PASS")
} else {
  print("FAIL")
}
