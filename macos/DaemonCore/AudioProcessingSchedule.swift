import Foundation

struct AudioScheduleDecision: Equatable {
  let blockCount: Int
  let discontinuity: Bool
}

struct AudioProcessingSchedule {
  let sampleRate: UInt64
  let blockFrames: UInt64
  let leadFrames: UInt64
  let maxCatchUpBlocks: Int

  private(set) var discontinuities: UInt64 = 0
  private var startNanos: UInt64?
  private var renderedFrames: UInt64 = 0

  init(sampleRate: UInt64, blockFrames: UInt64, leadFrames: UInt64, maxCatchUpBlocks: Int) {
    self.sampleRate = sampleRate
    self.blockFrames = blockFrames
    self.leadFrames = leadFrames
    self.maxCatchUpBlocks = maxCatchUpBlocks
  }

  mutating func reset() {
    startNanos = nil
    renderedFrames = 0
    discontinuities = 0
  }

  mutating func advance(nowNanos: UInt64) -> AudioScheduleDecision {
    if startNanos == nil {
      startNanos = nowNanos
    }
    guard let startNanos else {
      return AudioScheduleDecision(blockCount: 0, discontinuity: false)
    }

    let elapsedNanos = nowNanos >= startNanos ? nowNanos - startNanos : 0
    let elapsedFrames = UInt64(
      (Double(elapsedNanos) / 1_000_000_000.0) * Double(sampleRate)
    )
    let targetFrame = elapsedFrames + leadFrames
    let dueFrames = targetFrame > renderedFrames ? targetFrame - renderedFrames : 0
    let dueBlocks = Int(dueFrames / blockFrames)
    let blockCount = min(dueBlocks, maxCatchUpBlocks)
    renderedFrames &+= UInt64(blockCount) * blockFrames

    guard dueBlocks > maxCatchUpBlocks else {
      return AudioScheduleDecision(blockCount: blockCount, discontinuity: false)
    }

    discontinuities &+= 1
    self.startNanos = nowNanos
    renderedFrames = leadFrames
    return AudioScheduleDecision(blockCount: blockCount, discontinuity: true)
  }
}
