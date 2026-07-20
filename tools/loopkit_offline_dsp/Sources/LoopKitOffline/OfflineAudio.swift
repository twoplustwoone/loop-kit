import Foundation
import LoopKitEngine

public enum OfflineAudioError: Error, LocalizedError {
  case malformedWave(String)
  case unsupportedWave(String)
  case invalidAudio(String)
  case engineCreationFailed

  public var errorDescription: String? {
    switch self {
    case .malformedWave(let message), .unsupportedWave(let message), .invalidAudio(let message):
      return message
    case .engineCreationFailed:
      return "Failed to create the LoopKit DSP engine"
    }
  }
}

public struct StereoAudio: Equatable {
  public let sampleRate: Int
  public let left: [Float]
  public let right: [Float]

  public init(sampleRate: Int, left: [Float], right: [Float]) throws {
    guard sampleRate > 0 else {
      throw OfflineAudioError.invalidAudio("Sample rate must be positive")
    }
    guard left.count == right.count else {
      throw OfflineAudioError.invalidAudio("Left and right channels must have the same frame count")
    }
    self.sampleRate = sampleRate
    self.left = left
    self.right = right
  }
}

public struct OfflineMixOptions: Equatable {
  public var sourceGain: Double
  public var masterGain: Double
  public var muted: Bool

  public init(sourceGain: Double = 1.0, masterGain: Double = 1.0, muted: Bool = false) {
    self.sourceGain = sourceGain
    self.masterGain = masterGain
    self.muted = muted
  }
}

public enum OfflineMixer {
  private static let blockFrames = 512

  public static func process(
    _ input: StereoAudio,
    options: OfflineMixOptions = OfflineMixOptions()
  ) throws -> StereoAudio {
    var config = lk_engine_config(
      sample_rate: UInt32(input.sampleRate),
      max_block_frames: UInt32(blockFrames)
    )
    guard let engine = lk_engine_create(&config) else {
      throw OfflineAudioError.engineCreationFailed
    }
    defer { lk_engine_destroy(engine) }

    let app = lk_source_params(
      gain: Float(clampedGain(options.sourceGain)),
      mute: options.muted ? 1 : 0,
      solo: 0,
      enabled: 1
    )
    let disabledMic = lk_source_params(gain: 0, mute: 1, solo: 0, enabled: 0)
    lk_engine_set_source_params(engine, UInt32(LK_SOURCE_APP), app)
    lk_engine_set_source_params(engine, UInt32(LK_SOURCE_MIC), disabledMic)
    lk_engine_set_master_gain(engine, Float(clampedGain(options.masterGain)))

    var outputLeft = [Float](repeating: 0, count: input.left.count)
    var outputRight = [Float](repeating: 0, count: input.right.count)
    let silence = [Float](repeating: 0, count: blockFrames)

    input.left.withUnsafeBufferPointer { inputLeft in
      input.right.withUnsafeBufferPointer { inputRight in
        silence.withUnsafeBufferPointer { silent in
          outputLeft.withUnsafeMutableBufferPointer { outputLeftBuffer in
            outputRight.withUnsafeMutableBufferPointer { outputRightBuffer in
              var offset = 0
              while offset < input.left.count {
                let frames = min(Self.blockFrames, input.left.count - offset)
                var appInput = lk_input_audio_block(
                  left: inputLeft.baseAddress?.advanced(by: offset),
                  right: inputRight.baseAddress?.advanced(by: offset),
                  frames: UInt32(frames)
                )
                var micInput = lk_input_audio_block(
                  left: silent.baseAddress,
                  right: silent.baseAddress,
                  frames: UInt32(frames)
                )
                var broadcastOutput = lk_output_audio_block(
                  left: outputLeftBuffer.baseAddress?.advanced(by: offset),
                  right: outputRightBuffer.baseAddress?.advanced(by: offset),
                  frames: UInt32(frames)
                )
                var monitorOutput = lk_output_audio_block(left: nil, right: nil, frames: 0)
                var meters = lk_meter_block(peak_l: 0, peak_r: 0, rms_l: 0, rms_r: 0, clipped_l: 0, clipped_r: 0)
                lk_engine_process(
                  engine,
                  &appInput,
                  &micInput,
                  &broadcastOutput,
                  &monitorOutput,
                  &meters
                )
                offset += frames
              }
            }
          }
        }
      }
    }

    return try StereoAudio(sampleRate: input.sampleRate, left: outputLeft, right: outputRight)
  }

  private static func clampedGain(_ value: Double) -> Double {
    if value.isNaN { return 1.0 }
    return min(max(value, 0), 8)
  }
}

public enum WaveFile {
  public static func read(from url: URL) throws -> StereoAudio {
    let data = try Data(contentsOf: url)
    guard data.count >= 12,
          fourCC(data, at: 0) == "RIFF",
          fourCC(data, at: 8) == "WAVE" else {
      throw OfflineAudioError.malformedWave("Input is not a RIFF/WAVE file")
    }

    var format: UInt16?
    var channels: UInt16?
    var sampleRate: UInt32?
    var bitsPerSample: UInt16?
    var audioData: Data?
    var offset = 12

    while offset + 8 <= data.count {
      let chunkID = fourCC(data, at: offset)
      let chunkSize = Int(readUInt32(data, at: offset + 4))
      let payloadStart = offset + 8
      let payloadEnd = payloadStart + chunkSize
      guard payloadEnd <= data.count else {
        throw OfflineAudioError.malformedWave("WAVE chunk extends beyond the file")
      }

      if chunkID == "fmt " {
        guard chunkSize >= 16 else {
          throw OfflineAudioError.malformedWave("WAVE format chunk is too short")
        }
        format = readUInt16(data, at: payloadStart)
        channels = readUInt16(data, at: payloadStart + 2)
        sampleRate = readUInt32(data, at: payloadStart + 4)
        bitsPerSample = readUInt16(data, at: payloadStart + 14)
      } else if chunkID == "data" {
        audioData = data.subdata(in: payloadStart..<payloadEnd)
      }

      offset = payloadEnd + (chunkSize & 1)
    }

    guard let format, let channels, let sampleRate, let bitsPerSample, let audioData else {
      throw OfflineAudioError.malformedWave("WAVE file is missing format or audio data")
    }
    guard channels == 1 || channels == 2 else {
      throw OfflineAudioError.unsupportedWave("Only mono and stereo WAVE files are supported")
    }

    let bytesPerSample = Int(bitsPerSample / 8)
    guard bytesPerSample > 0 else {
      throw OfflineAudioError.malformedWave("Invalid WAVE bit depth")
    }
    let bytesPerFrame = bytesPerSample * Int(channels)
    guard audioData.count % bytesPerFrame == 0 else {
      throw OfflineAudioError.malformedWave("WAVE audio data is not frame-aligned")
    }

    let frameCount = audioData.count / bytesPerFrame
    var left = [Float](repeating: 0, count: frameCount)
    var right = [Float](repeating: 0, count: frameCount)
    for frame in 0..<frameCount {
      let base = frame * bytesPerFrame
      left[frame] = try sample(data: audioData, offset: base, format: format, bits: bitsPerSample)
      if channels == 2 {
        right[frame] = try sample(
          data: audioData,
          offset: base + bytesPerSample,
          format: format,
          bits: bitsPerSample
        )
      } else {
        right[frame] = left[frame]
      }
    }

    return try StereoAudio(sampleRate: Int(sampleRate), left: left, right: right)
  }

  public static func write(_ audio: StereoAudio, to url: URL) throws {
    let dataBytes = audio.left.count * 2 * MemoryLayout<Float>.size
    var data = Data()
    appendFourCC("RIFF", to: &data)
    appendUInt32(UInt32(36 + dataBytes), to: &data)
    appendFourCC("WAVE", to: &data)
    appendFourCC("fmt ", to: &data)
    appendUInt32(16, to: &data)
    appendUInt16(3, to: &data) // IEEE float
    appendUInt16(2, to: &data)
    appendUInt32(UInt32(audio.sampleRate), to: &data)
    appendUInt32(UInt32(audio.sampleRate * 2 * MemoryLayout<Float>.size), to: &data)
    appendUInt16(UInt16(2 * MemoryLayout<Float>.size), to: &data)
    appendUInt16(32, to: &data)
    appendFourCC("data", to: &data)
    appendUInt32(UInt32(dataBytes), to: &data)
    for frame in audio.left.indices {
      appendUInt32(audio.left[frame].bitPattern, to: &data)
      appendUInt32(audio.right[frame].bitPattern, to: &data)
    }
    try data.write(to: url, options: .atomic)
  }

  private static func sample(
    data: Data,
    offset: Int,
    format: UInt16,
    bits: UInt16
  ) throws -> Float {
    if format == 1 && bits == 16 {
      return Float(Int16(bitPattern: readUInt16(data, at: offset))) / 32_768.0
    }
    if format == 3 && bits == 32 {
      return Float(bitPattern: readUInt32(data, at: offset))
    }
    throw OfflineAudioError.unsupportedWave(
      "Supported WAVE encodings are 16-bit PCM and 32-bit IEEE float"
    )
  }

  private static func fourCC(_ data: Data, at offset: Int) -> String {
    guard offset >= 0, offset + 4 <= data.count else { return "" }
    return String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
  }

  private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
    data.withUnsafeBytes { raw in
      UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }
  }

  private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
    data.withUnsafeBytes { raw in
      UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }
  }

  private static func appendFourCC(_ value: String, to data: inout Data) {
    data.append(contentsOf: value.utf8)
  }

  private static func appendUInt16(_ value: UInt16, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
  }

  private static func appendUInt32(_ value: UInt32, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
  }
}
