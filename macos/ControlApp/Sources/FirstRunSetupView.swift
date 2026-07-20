import AppKit
import LoopKitIPC
import LoopKitUI
import SwiftUI

@MainActor
struct FirstRunSetupView: View {
  @ObservedObject var model: LoopKitViewModel
  @ObservedObject var helperManager: LoopKitHelperManager
  let onComplete: () -> Void

  @State private var selectedMonitorUID = ""

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider().overlay(LoopKitTheme.rim)
      ScrollView {
        VStack(spacing: 12) {
          setupRow(
            number: 1,
            title: "Background helper",
            detail: helperDetail,
            state: helperState
          ) {
            helperControls
          }

          if helperManager.hasLegacyInstallation {
            setupRow(
              number: 2,
              title: "Legacy developer install",
              detail: "An older com.example helper can conflict with this release.",
              state: .warning
            ) {
              Button("Remove legacy helper") {
                _ = helperManager.removeLegacyInstallation()
                helperManager.refresh()
              }
              .buttonStyle(.bordered)
            }
          }

          setupRow(
            number: 3,
            title: "BlackHole 2ch",
            detail: blackHoleReady
              ? "Broadcast output is connected."
              : "Install BlackHole 2ch separately, then reopen or reconnect LoopKit.",
            state: blackHoleReady ? .ready : .warning
          ) {
            Link("Official BlackHole download", destination: URL(string: "https://existential.audio/blackhole/")!)
              .buttonStyle(.bordered)
          }

          setupRow(
            number: 4,
            title: "Microphone permission",
            detail: microphoneDetail,
            state: microphoneState
          ) {
            Button("Request microphone access") { model.requestMicrophoneAccess() }
              .buttonStyle(.bordered)
              .disabled(model.status?.microphonePermission == LKPermissionStateGranted)
          }

          setupRow(
            number: 5,
            title: "Application audio",
            detail: captureDetail,
            state: captureReady ? .ready : .warning
          ) {
            Button("Refresh") { model.retryConnection() }
              .buttonStyle(.bordered)
          }

          setupRow(
            number: 6,
            title: "Physical Monitor",
            detail: "Choose speakers or headphones. LoopKit will never allow BlackHole here.",
            state: model.monitorDevices.isEmpty ? .warning : .ready
          ) {
            Picker("Monitor", selection: monitorSelection) {
              ForEach(model.monitorDevices, id: \.uid) { device in
                Text(device.name).tag(device.uid)
              }
            }
            .labelsHidden()
            .frame(width: 260)
          }

          setupRow(
            number: 7,
            title: "Receiver application",
            detail: "In Discord, Zoom, or your receiver app, choose BlackHole 2ch as the microphone/input. Keep its output on your physical speakers or headphones.",
            state: .information
          ) { EmptyView() }
        }
        .padding(20)
      }

      Divider().overlay(LoopKitTheme.rim)
      HStack {
        Text("You can reopen setup from the dashboard later.")
          .font(.caption)
          .foregroundStyle(LoopKitTheme.secondaryText)
        Spacer()
        Button("Finish setup") { onComplete() }
          .buttonStyle(.borderedProminent)
          .tint(LoopKitTheme.teal)
      }
      .padding(18)
    }
    .frame(width: 620, height: 720)
    .background(LoopKitTheme.background)
    .foregroundStyle(LoopKitTheme.text)
    .preferredColorScheme(.dark)
    .onAppear {
      helperManager.refresh()
      selectedMonitorUID = model.monitorDeviceUID
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text("SET UP LOOPKIT")
        .font(LoopKitTheme.mono(11, weight: .semibold))
        .tracking(1.5)
        .foregroundStyle(LoopKitTheme.teal)
      Text("A clean signal path in a few steps")
        .font(.system(size: 23, weight: .bold))
      Text("LoopKit keeps BlackHole external and only asks for microphone access when you choose to enable it.")
        .font(.callout)
        .foregroundStyle(LoopKitTheme.secondaryText)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(22)
  }

  private var helperControls: some View {
    HStack {
      switch helperManager.status {
      case .enabled:
        Button("Repair") {
          _ = helperManager.repair()
          model.retryConnection()
        }
      case .requiresApproval:
        Button("Open Login Items") { helperManager.openLoginItemsSettings() }
      default:
        Button("Register helper") {
          _ = helperManager.register()
          model.retryConnection()
        }
      }
    }
    .buttonStyle(.bordered)
  }

  private var helperDetail: String {
    if let error = helperManager.lastError { return error }
    switch helperManager.status {
    case .enabled: return "Registered and enabled."
    case .requiresApproval: return "macOS requires approval in Login Items."
    case .notFound: return "The embedded helper could not be found. Repair the application install."
    case .unavailable(let message): return message
    case .notRegistered: return "Register LoopKit’s embedded audio helper."
    }
  }

  private var helperState: SetupState {
    switch helperManager.status {
    case .enabled: return .ready
    case .requiresApproval: return .warning
    case .notFound, .unavailable: return .fault
    case .notRegistered: return .information
    }
  }

  private var blackHoleReady: Bool { model.status?.broadcastOutputConnected == true }
  private var captureReady: Bool { model.status?.captureMode == LKCaptureModeProcessTap }
  private var captureDetail: String {
    captureReady
      ? "Process Tap capture is available. Select applications from the Sources panel."
      : (model.status?.captureWarning ?? "Waiting for the helper and macOS application-audio capture.")
  }

  private var microphoneDetail: String {
    switch model.status?.microphonePermission {
    case LKPermissionStateGranted: return "Microphone access is enabled."
    case LKPermissionStateDenied: return "Permission is denied. Enable LoopKit in Privacy & Security › Microphone."
    default: return "Optional. LoopKit will not prompt until you click the button."
    }
  }

  private var microphoneState: SetupState {
    switch model.status?.microphonePermission {
    case LKPermissionStateGranted: return .ready
    case LKPermissionStateDenied: return .fault
    default: return .information
    }
  }

  private var monitorSelection: Binding<String> {
    Binding(
      get: {
        if model.monitorDevices.contains(where: { $0.uid == selectedMonitorUID }) {
          return selectedMonitorUID
        }
        return model.monitorDevices.first?.uid ?? ""
      },
      set: { uid in
        selectedMonitorUID = uid
        model.monitorDeviceUID = uid
        model.applyMonitorDevice(uid)
      }
    )
  }

  @ViewBuilder
  private func setupRow<Controls: View>(
    number: Int,
    title: String,
    detail: String,
    state: SetupState,
    @ViewBuilder controls: () -> Controls
  ) -> some View {
    HStack(alignment: .top, spacing: 14) {
      Text(String(format: "%02d", number))
        .font(LoopKitTheme.mono(11, weight: .semibold))
        .foregroundStyle(state.color)
        .frame(width: 28, height: 28)
        .background(state.color.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text(title).font(.headline)
          Spacer()
          Label(state.label, systemImage: state.symbol)
            .font(LoopKitTheme.mono(9, weight: .medium))
            .foregroundStyle(state.color)
        }
        Text(detail)
          .font(.caption)
          .foregroundStyle(LoopKitTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
        controls()
      }
    }
    .padding(14)
    .background(LoopKitTheme.panel)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(LoopKitTheme.rim, lineWidth: 1)
    }
  }
}

private enum SetupState {
  case ready
  case information
  case warning
  case fault

  var label: String {
    switch self {
    case .ready: return "READY"
    case .information: return "ACTION"
    case .warning: return "CHECK"
    case .fault: return "FAULT"
    }
  }

  var symbol: String {
    switch self {
    case .ready: return "checkmark.circle.fill"
    case .information: return "circle.dashed"
    case .warning: return "exclamationmark.triangle.fill"
    case .fault: return "xmark.octagon.fill"
    }
  }

  var color: Color {
    switch self {
    case .ready: return LoopKitTheme.signal
    case .information: return LoopKitTheme.teal
    case .warning: return LoopKitTheme.warning
    case .fault: return LoopKitTheme.error
    }
  }
}
