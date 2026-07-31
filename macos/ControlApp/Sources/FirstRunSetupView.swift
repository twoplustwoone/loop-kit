import AppKit
import LoopKitIPC
import LoopKitUI
import SwiftUI

@MainActor
struct FirstRunSetupView: View {
  @ObservedObject var model: LoopKitViewModel
  let onComplete: () -> Void

  @State private var selectedMonitorUID = ""
  @State private var selectedTestBundleID = ""

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider().overlay(LoopKitTheme.rim)
      ScrollView {
        VStack(spacing: 12) {
          setupRow(number: 1, title: "Audio service", detail: serviceDetail, state: serviceState) {
            if case .disconnected = model.connection {
              HStack {
                Button("Restart Audio Service") { model.retryConnection() }
                if model.legacyMigrationError != nil {
                  Button("Open Login Items") { model.openLoginItemsSettings() }
                }
              }
              .buttonStyle(.bordered)
            }
          }

          setupRow(
            number: 2,
            title: "BlackHole 2ch",
            detail: blackHoleReady
              ? "Broadcast output is connected."
              : "Install BlackHole 2ch separately, then refresh LoopKit.",
            state: blackHoleReady ? .ready : .warning
          ) {
            HStack {
              Link("Official BlackHole download", destination: URL(string: "https://existential.audio/blackhole/")!)
              Button("Refresh") { model.retryConnection() }
            }
            .buttonStyle(.bordered)
          }

          setupRow(
            number: 3,
            title: "Microphone permission (optional)",
            detail: microphonePresentation.detail,
            state: microphonePresentation.state
          ) {
            switch microphonePresentation.microphoneAction {
            case .request:
              Button("Request microphone access") { model.requestMicrophoneAccess() }
                .buttonStyle(.bordered)
            case .openSettings:
              Button("Open Microphone Settings") { model.openMicrophoneSettings() }
                .buttonStyle(.bordered)
            case .none:
              Text("Enabled")
                .font(LoopKitTheme.mono(10, weight: .semibold))
                .foregroundStyle(LoopKitTheme.signal)
            }
          }

          setupRow(
            number: 4,
            title: "Application audio test (optional)",
            detail: applicationAudioPresentation.detail,
            state: applicationAudioPresentation.state
          ) {
            VStack(alignment: .leading, spacing: 8) {
              Picker("Application", selection: $selectedTestBundleID) {
                Text("Choose a running application").tag("")
                ForEach(runningCaptureApps, id: \.bundleID) { app in
                  Text(app.displayName).tag(app.bundleID)
                }
              }
              .labelsHidden()
              .frame(width: 280)

              HStack {
                Button(testButtonTitle) { startApplicationAudioTest() }
                  .disabled(selectedTestBundleID.isEmpty || selectedTestApp?.selected == true)
                Button("Refresh applications") { model.refreshCaptureApplications() }
              }
              .buttonStyle(.bordered)
            }
          }

          setupRow(
            number: 5,
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
            number: 6,
            title: "Receiver application",
            detail: "In Discord, Zoom, or your receiver app, choose BlackHole 2ch as the microphone/input. Keep its output on your physical speakers or headphones.",
            state: .information
          ) { EmptyView() }
        }
        .padding(20)
      }

      Divider().overlay(LoopKitTheme.rim)
      HStack {
        Text("Optional steps can be completed later from Setup.")
          .font(.caption)
          .foregroundStyle(LoopKitTheme.secondaryText)
        Spacer()
        Button("Close setup") { onComplete() }
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
      selectedMonitorUID = model.monitorDeviceUID
      selectedTestBundleID = model.captureApps.first(where: \.selected)?.bundleID ?? ""
      model.refreshMicrophoneAuthorizationAfterActivation()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      model.refreshMicrophoneAuthorizationAfterActivation()
    }
    .onChange(of: model.captureApps.map(\.bundleID)) {
      guard selectedTestBundleID.isEmpty else { return }
      selectedTestBundleID = model.captureApps.first(where: \.selected)?.bundleID ?? ""
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
      Text("LoopKit keeps BlackHole external. Microphone and application-audio tests are optional.")
        .font(.callout)
        .foregroundStyle(LoopKitTheme.secondaryText)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(22)
  }

  private var serviceDetail: String {
    if let error = model.legacyMigrationError { return error }
    switch model.connection {
    case .connected:
      if model.status?.runtimeLifecycle == LKRuntimeLifecycleFailed {
        return model.status?.errorMessage ?? "The audio service failed to initialize."
      }
      return model.status?.runtimeLifecycle == LKRuntimeLifecycleStarting
        ? "Starting LoopKit’s app-owned audio service."
        : "The app-owned audio service is ready. It stops when you quit LoopKit."
    case .connecting:
      return "Starting LoopKit’s app-owned audio service."
    case .disconnected(let reason):
      return reason
    }
  }

  private var serviceState: SetupState {
    switch model.connection {
    case .connected:
      return model.status?.runtimeLifecycle == LKRuntimeLifecycleFailed ? .fault : .ready
    case .connecting:
      return .information
    case .disconnected:
      return .fault
    }
  }

  private var blackHoleReady: Bool { model.status?.broadcastOutputConnected == true }

  private var microphonePresentation: LoopKitSetupPresentation.Row {
    let permission: LoopKitSetupPresentation.MicrophonePermission
    switch model.foregroundMicrophonePermission {
    case LKPermissionStateGranted: permission = .granted
    case LKPermissionStateDenied: permission = .denied
    default: permission = .notRequested
    }
    return LoopKitSetupPresentation.microphone(
      permission: permission,
      inputName: permission == .granted ? model.deviceName(uid: model.inputDeviceUID) : nil
    )
  }

  private var applicationAudioPresentation: LoopKitSetupPresentation.Row {
    LoopKitSetupPresentation.applicationAudio(
      serviceReady: model.connection == .connected,
      captureAvailable: model.status?.captureMode == LKCaptureModeProcessTap,
      selectedCount: model.captureApps.filter(\.selected).count,
      activeTapCount: model.status?.activeTapCount ?? 0,
      warning: model.status?.captureWarning
    )
  }

  private var runningCaptureApps: [LKXPCCaptureApp] {
    model.captureApps.filter(\.running)
  }

  private var selectedTestApp: LKXPCCaptureApp? {
    model.captureApps.first { $0.bundleID == selectedTestBundleID }
  }

  private var testButtonTitle: String {
    selectedTestApp?.selected == true ? "Selected" : "Start test"
  }

  private func startApplicationAudioTest() {
    guard !selectedTestBundleID.isEmpty else { return }
    model.setCaptureSelected(bundleID: selectedTestBundleID, isSelected: true)
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

private typealias SetupState = LoopKitSetupPresentation.State

private extension LoopKitSetupPresentation.State {
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
