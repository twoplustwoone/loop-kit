import AppKit
import AVFoundation
import Foundation
import LoopKitIPC

@MainActor
final class MicrophoneAuthorizationController {
  var state: String {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .notDetermined: return LKPermissionStateNotRequested
    case .authorized: return LKPermissionStateGranted
    case .denied, .restricted: return LKPermissionStateDenied
    @unknown default: return LKPermissionStateDenied
    }
  }

  func requestAccess() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      return true
    case .notDetermined:
      return await AVCaptureDevice.requestAccess(for: .audio)
    case .denied, .restricted:
      return false
    @unknown default:
      return false
    }
  }

  func openSettings() {
    let microphone = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    )
    let privacy = URL(
      string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
    )
    if let microphone, NSWorkspace.shared.open(microphone) { return }
    if let privacy { NSWorkspace.shared.open(privacy) }
  }
}
