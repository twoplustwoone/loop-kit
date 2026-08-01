import Foundation

public enum LoopKitSetupPresentation {
  public enum RefreshAction: Equatable {
    case reloadData
    case wait
    case restartService(retryLegacyMigration: Bool)
  }

  public enum State: Equatable {
    case ready
    case information
    case warning
    case fault
  }

  public enum MicrophonePermission: Equatable {
    case notRequested
    case granted
    case denied
  }

  public enum MicrophoneAction: Equatable {
    case request
    case openSettings
    case none
  }

  public struct Row: Equatable {
    public let detail: String
    public let state: State
    public let microphoneAction: MicrophoneAction

    public init(
      detail: String,
      state: State,
      microphoneAction: MicrophoneAction = .none
    ) {
      self.detail = detail
      self.state = state
      self.microphoneAction = microphoneAction
    }
  }

  public static func microphone(
    permission: MicrophonePermission,
    inputName: String?
  ) -> Row {
    switch permission {
    case .notRequested:
      return Row(
        detail: "Optional. LoopKit asks only when you choose to enable microphone capture.",
        state: .information,
        microphoneAction: .request
      )
    case .granted:
      let suffix = inputName.map { " Current input: \($0)." } ?? ""
      return Row(detail: "Microphone access is enabled.\(suffix)", state: .ready)
    case .denied:
      return Row(
        detail: "Access is off. Enable LoopKit in Privacy & Security › Microphone.",
        state: .fault,
        microphoneAction: .openSettings
      )
    }
  }

  public static func applicationAudio(
    serviceReady: Bool,
    captureAvailable: Bool,
    selectedCount: Int,
    activeTapCount: Int,
    warning: String?
  ) -> Row {
    guard serviceReady else {
      return Row(detail: "Waiting for the LoopKit audio service.", state: .warning)
    }
    guard captureAvailable else {
      return Row(
        detail: warning ?? "Application-audio capture is unavailable on this Mac.",
        state: .fault
      )
    }
    if let warning, !warning.isEmpty {
      return Row(detail: warning, state: .fault)
    }
    if selectedCount == 0 {
      return Row(
        detail: "Ready to test. Choose a running application below, or skip this optional step.",
        state: .information
      )
    }
    if activeTapCount > 0 {
      return Row(
        detail: "Application audio is capturing. This source will remain selected after setup.",
        state: .ready
      )
    }
    return Row(
      detail: "Starting the Process Tap. Approve macOS system-audio recording if prompted.",
      state: .warning
    )
  }

  /// A routine refresh must not tear down a healthy audio service. Reconnection
  /// is recovery behavior reserved for an actual connection or migration fault.
  public static func refreshAction(
    serviceConnected: Bool,
    serviceConnecting: Bool,
    legacyMigrationFailed: Bool
  ) -> RefreshAction {
    if serviceConnected {
      return .reloadData
    }
    if serviceConnecting {
      return .wait
    }
    return .restartService(retryLegacyMigration: legacyMigrationFailed)
  }
}

public enum LoopKitLegacyAgentMigrationPolicy {
  public enum Status: Equatable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
    case unknown
  }

  public enum Action: Equatable {
    case unregister
    case proceed
    case block
  }

  public static func action(for status: Status) -> Action {
    switch status {
    case .enabled, .requiresApproval:
      return .unregister
    case .notRegistered, .notFound:
      return .proceed
    case .unknown:
      return .block
    }
  }
}
