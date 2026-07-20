import Foundation
import LoopKitIPC

enum RoutingSafetyError: LocalizedError {
  case selfCapture(String)
  case echoRiskRequiresApproval(String)
  case broadcastDeviceCannotBeMonitor

  var errorDescription: String? {
    switch self {
    case .selfCapture:
      return "LoopKit cannot capture itself because that would create an audio feedback loop."
    case .echoRiskRequiresApproval(let bundleID):
      return "Sending \(bundleID) back to Broadcast can echo remote callers. Confirm this route before enabling it."
    case .broadcastDeviceCannotBeMonitor:
      return "BlackHole 2ch is the Broadcast device and cannot also be used as Monitor output."
    }
  }
}

enum RoutingSafetyPolicy {
  static let loopKitBundleIDs: Set<String> = [
    "com.twoplustwoone.LoopKit",
    "com.twoplustwoone.LoopKit.agent",
    "com.example.LoopKit.ControlApp",
    "com.example.LoopKit.loopkitd",
  ]

  static let communicationsBundleIDs: Set<String> = [
    "com.hnc.Discord",
    "com.microsoft.teams2",
    "com.tinyspeck.slackmacgap",
    "net.whatsapp.WhatsApp",
    "us.zoom.xos",
  ]

  static func isCommunicationApplication(_ bundleID: String) -> Bool {
    communicationsBundleIDs.contains(bundleID)
  }

  static func defaultDestinations(for source: SourceID) -> Set<RouteDestination> {
    if source == .microphone { return [.broadcast] }
    if let bundleID = source.applicationBundleID,
       isCommunicationApplication(bundleID) {
      return [.monitor]
    }
    return [.monitor, .broadcast]
  }

  static func validateCapturedApplications(_ bundleIDs: [String]) throws {
    if let loopKitID = bundleIDs.first(where: loopKitBundleIDs.contains) {
      throw RoutingSafetyError.selfCapture(loopKitID)
    }
  }

  static func validateRoutes(
    _ routes: [LKXPCRoute],
    echoRiskAcknowledgements: Set<String>
  ) throws {
    for route in routes where route.destinationID == RouteDestination.broadcast.rawValue {
      let source = SourceID(rawValue: route.sourceID)
      guard let bundleID = source.applicationBundleID,
            isCommunicationApplication(bundleID),
            !echoRiskAcknowledgements.contains(bundleID)
      else { continue }
      throw RoutingSafetyError.echoRiskRequiresApproval(bundleID)
    }
  }

  static func validateMonitorDevice(uid: String, broadcastDeviceUID: String) throws {
    if uid == "BlackHole2ch_UID" || (!broadcastDeviceUID.isEmpty && uid == broadcastDeviceUID) {
      throw RoutingSafetyError.broadcastDeviceCannotBeMonitor
    }
  }
}
