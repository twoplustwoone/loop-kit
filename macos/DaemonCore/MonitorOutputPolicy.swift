import Foundation

struct MonitorOutputDevice: Equatable {
  let uid: String
  let name: String
}

struct MonitorOutputDecision: Equatable {
  let activeUID: String?
  let fallbackActive: Bool
  let warning: String?

  var succeeded: Bool { activeUID != nil }
}

enum MonitorOutputPolicy {
  /// Selects and activates a Monitor device. The activation closure is the seam:
  /// production supplies the CoreAudio adapter and tests supply an in-memory adapter.
  static func activate(
    requestedUID: String,
    devices: [MonitorOutputDevice],
    defaultUID: String?,
    allowFallback: Bool,
    activation: (String) -> String?
  ) -> MonitorOutputDecision {
    let targetUID: String?
    if requestedUID == "system.default" {
      targetUID = defaultUID ?? devices.first?.uid
    } else {
      targetUID = requestedUID
    }

    guard let targetUID else {
      return MonitorOutputDecision(
        activeUID: nil,
        fallbackActive: false,
        warning: "No Monitor device is available"
      )
    }

    let primaryError = activation(targetUID)
    if primaryError == nil {
      return MonitorOutputDecision(activeUID: targetUID, fallbackActive: false, warning: nil)
    }

    let normalizedPrimaryError = primaryError ?? "Failed to open Monitor \(targetUID)"
    guard allowFallback, let defaultUID, defaultUID != targetUID else {
      return MonitorOutputDecision(activeUID: nil, fallbackActive: false, warning: normalizedPrimaryError)
    }

    let fallbackError = activation(defaultUID)
    if fallbackError == nil {
      let name = devices.first(where: { $0.uid == defaultUID })?.name ?? defaultUID
      return MonitorOutputDecision(
        activeUID: defaultUID,
        fallbackActive: true,
        warning: "Monitor issue (\(normalizedPrimaryError)). Using default Monitor \(name)"
      )
    }

    let normalizedFallbackError = fallbackError ?? "Failed to open Monitor \(defaultUID)"
    return MonitorOutputDecision(
      activeUID: nil,
      fallbackActive: false,
      warning: "Monitor issue (\(normalizedPrimaryError)); default Monitor failed (\(normalizedFallbackError))"
    )
  }
}
