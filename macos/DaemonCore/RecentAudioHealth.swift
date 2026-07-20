import Foundation

struct AudioHealthCounters: Equatable {
  let tapUnderruns: UInt64
  let tapOverruns: UInt64
  let monitorUnderruns: UInt64
  let monitorOverruns: UInt64
  let broadcastUnderruns: UInt64
  let broadcastOverruns: UInt64
}

struct AudioHealthRates: Equatable {
  static let zero = AudioHealthRates(
    tapUnderruns: 0, tapOverruns: 0,
    monitorUnderruns: 0, monitorOverruns: 0,
    broadcastUnderruns: 0, broadcastOverruns: 0
  )

  let tapUnderruns: Double
  let tapOverruns: Double
  let monitorUnderruns: Double
  let monitorOverruns: Double
  let broadcastUnderruns: Double
  let broadcastOverruns: Double

  var hasRecentEvents: Bool {
    tapUnderruns + tapOverruns + monitorUnderruns + monitorOverruns
      + broadcastUnderruns + broadcastOverruns > 0
  }
}

struct RecentAudioHealthTracker {
  private var previousCounters: AudioHealthCounters?
  private var previousDate: Date?

  mutating func sample(counters: AudioHealthCounters, now: Date = Date()) -> AudioHealthRates {
    defer {
      previousCounters = counters
      previousDate = now
    }
    guard let previousCounters, let previousDate else { return .zero }
    let elapsed = now.timeIntervalSince(previousDate)
    guard elapsed > 0 else { return .zero }

    func rate(_ current: UInt64, _ previous: UInt64) -> Double {
      Double(current >= previous ? current - previous : 0) / elapsed
    }
    return AudioHealthRates(
      tapUnderruns: rate(counters.tapUnderruns, previousCounters.tapUnderruns),
      tapOverruns: rate(counters.tapOverruns, previousCounters.tapOverruns),
      monitorUnderruns: rate(counters.monitorUnderruns, previousCounters.monitorUnderruns),
      monitorOverruns: rate(counters.monitorOverruns, previousCounters.monitorOverruns),
      broadcastUnderruns: rate(counters.broadcastUnderruns, previousCounters.broadcastUnderruns),
      broadcastOverruns: rate(counters.broadcastOverruns, previousCounters.broadcastOverruns)
    )
  }
}
