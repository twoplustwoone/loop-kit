import Foundation
import LoopKitAudioCore
import LoopKitEngine
import LoopKitIPC

struct DestinationMixMeters {
  let broadcast: lk_meter_block
  let monitor: lk_meter_block
}

final class AudioBlockStorage {
  private final class StereoBlock {
    private var left: [Float]
    private var right: [Float]

    init(capacity: Int) {
      left = [Float](repeating: 0, count: capacity)
      right = [Float](repeating: 0, count: capacity)
    }

    func zero(frames: Int) {
      guard frames > 0 else { return }
      for index in 0..<min(frames, left.count) {
        left[index] = 0
        right[index] = 0
      }
    }

    func mix(into destination: StereoBlock, frames: Int, gain: Float) {
      guard frames > 0 else { return }
      for index in 0..<min(frames, left.count, destination.left.count) {
        destination.left[index] += left[index] * gain
        destination.right[index] += right[index] * gain
      }
    }

    func meter(sourceID: String, frames: Int, gain: Float, active: Bool) -> LKXPCMeter {
      guard active, frames > 0 else {
        return LKXPCMeter(sourceID: sourceID, peakL: 0, peakR: 0, rmsL: 0, rmsR: 0)
      }

      let count = min(frames, left.count)
      var peakL: Float = 0
      var peakR: Float = 0
      var sumSqL: Double = 0
      var sumSqR: Double = 0
      var clippedL = false
      var clippedR = false
      for index in 0..<count {
        let l = left[index] * gain
        let r = right[index] * gain
        peakL = max(peakL, abs(l))
        peakR = max(peakR, abs(r))
        sumSqL += Double(l * l)
        sumSqR += Double(r * r)
        clippedL = clippedL || abs(l) > 0.95
        clippedR = clippedR || abs(r) > 0.95
      }

      return LKXPCMeter(
        sourceID: sourceID,
        peakL: Double(peakL),
        peakR: Double(peakR),
        rmsL: sqrt(sumSqL / Double(count)),
        rmsR: sqrt(sumSqR / Double(count)),
        clippedL: clippedL,
        clippedR: clippedR
      )
    }

    func withPointers<R>(
      _ body: (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>) -> R
    ) -> R {
      left.withUnsafeMutableBufferPointer { leftBuffer in
        right.withUnsafeMutableBufferPointer { rightBuffer in
          body(leftBuffer.baseAddress!, rightBuffer.baseAddress!)
        }
      }
    }
  }

  private let broadcastApp: StereoBlock
  private let monitorApp: StereoBlock
  private let scratch: StereoBlock
  private let microphone: StereoBlock
  private let broadcast: StereoBlock
  private let monitor: StereoBlock

  init(frameCapacity: Int) {
    broadcastApp = StereoBlock(capacity: frameCapacity)
    monitorApp = StereoBlock(capacity: frameCapacity)
    scratch = StereoBlock(capacity: frameCapacity)
    microphone = StereoBlock(capacity: frameCapacity)
    broadcast = StereoBlock(capacity: frameCapacity)
    monitor = StereoBlock(capacity: frameCapacity)
  }

  func prepare(frames: Int) {
    broadcastApp.zero(frames: frames)
    monitorApp.zero(frames: frames)
    broadcast.zero(frames: frames)
    monitor.zero(frames: frames)
    microphone.zero(frames: frames)
  }

  func captureMicrophone(from manager: LKMicInputManager, frames: UInt32) -> UInt32 {
    microphone.withPointers { left, right in
      manager.copyAudioLeft(left, right: right, maxFrames: frames)
    }
  }

  func captureApplication(
    bundleID: String,
    from manager: LKProcessTapManager,
    frames: UInt32
  ) -> UInt32 {
    scratch.zero(frames: Int(frames))
    return scratch.withPointers { left, right in
      manager.copyAudio(forBundleID: bundleID, left: left, right: right, maxFrames: frames)
    }
  }

  func applicationMeter(sourceID: String, frames: Int, gain: Float, active: Bool) -> LKXPCMeter {
    scratch.meter(sourceID: sourceID, frames: frames, gain: gain, active: active)
  }

  func microphoneMeter(sourceID: String, frames: Int, gain: Float, active: Bool) -> LKXPCMeter {
    microphone.meter(sourceID: sourceID, frames: frames, gain: gain, active: active)
  }

  func mixCapturedApplication(frames: Int, gain: Float, broadcast: Bool, monitor: Bool) {
    if broadcast {
      scratch.mix(into: broadcastApp, frames: frames, gain: gain)
    }
    if monitor {
      scratch.mix(into: monitorApp, frames: frames, gain: gain)
    }
  }

  func process(
    engine: OpaquePointer,
    frames: UInt32,
    microphoneBroadcastFrames: UInt32,
    microphoneMonitorFrames: UInt32
  ) -> DestinationMixMeters {
    var broadcastMeter = lk_meter_block(
      peak_l: 0, peak_r: 0, rms_l: 0, rms_r: 0, clipped_l: 0, clipped_r: 0
    )
    var monitorMeter = lk_meter_block(
      peak_l: 0, peak_r: 0, rms_l: 0, rms_r: 0, clipped_l: 0, clipped_r: 0
    )

    broadcastApp.withPointers { broadcastAppL, broadcastAppR in
      monitorApp.withPointers { monitorAppL, monitorAppR in
        microphone.withPointers { microphoneL, microphoneR in
          broadcast.withPointers { broadcastL, broadcastR in
            monitor.withPointers { monitorL, monitorR in
              var broadcastAppInput = lk_input_audio_block(
                left: broadcastAppL, right: broadcastAppR, frames: frames
              )
              var broadcastMicInput = lk_input_audio_block(
                left: microphoneL, right: microphoneR, frames: microphoneBroadcastFrames
              )
              var monitorAppInput = lk_input_audio_block(
                left: monitorAppL, right: monitorAppR, frames: frames
              )
              var monitorMicInput = lk_input_audio_block(
                left: microphoneL, right: microphoneR, frames: microphoneMonitorFrames
              )
              var broadcastOutput = lk_output_audio_block(
                left: broadcastL, right: broadcastR, frames: frames
              )
              var monitorOutput = lk_output_audio_block(
                left: monitorL, right: monitorR, frames: frames
              )
              lk_engine_process_routed(
                engine,
                &broadcastAppInput,
                &broadcastMicInput,
                &monitorAppInput,
                &monitorMicInput,
                &broadcastOutput,
                &monitorOutput,
                &broadcastMeter,
                &monitorMeter
              )
            }
          }
        }
      }
    }

    return DestinationMixMeters(broadcast: broadcastMeter, monitor: monitorMeter)
  }

  @discardableResult
  func enqueueBroadcast(to output: LKAudioOutputRouter, frames: UInt32) -> Bool {
    broadcast.withPointers { left, right in
      output.enqueueLeft(left, right: right, frames: frames)
    }
  }

  @discardableResult
  func enqueueMonitor(to output: LKAudioOutputRouter, frames: UInt32) -> Bool {
    monitor.withPointers { left, right in
      output.enqueueLeft(left, right: right, frames: frames)
    }
  }
}
