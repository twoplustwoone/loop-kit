import Foundation

enum ControlPolicy {
  static func gain(_ value: Double) -> Double {
    if value.isNaN { return 1.0 }
    return min(max(value, 0.0), 8.0)
  }
}
