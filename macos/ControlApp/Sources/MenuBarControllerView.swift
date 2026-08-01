import LoopKitIPC
import LoopKitUI
import SwiftUI

@MainActor
struct MenuBarControllerView: View {
  @ObservedObject var model: LoopKitViewModel
  @Environment(\.openWindow) private var openWindow
  @AppStorage("LoopKitFirstRunSetupComplete") private var setupComplete = true
  @State private var monitorPickerPresented = false

  private let startsServices: Bool

  init(model: LoopKitViewModel, startsServices: Bool = true) {
    self.model = model
    self.startsServices = startsServices
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider().overlay(LoopKitTheme.rim)

      ViewThatFits(in: .vertical) {
        controllerSections
        ScrollView { controllerSections }
      }

      Divider().overlay(LoopKitTheme.rim)
      footer
    }
    .frame(width: 360, height: 480)
    .background(LoopKitTheme.panel)
    .foregroundStyle(LoopKitTheme.text)
    .preferredColorScheme(.dark)
    .onAppear {
      guard startsServices else { return }
      model.onAppear()
    }
    .onDisappear {
      guard startsServices else { return }
      model.onDisappear()
    }
  }

  private var controllerSections: some View {
    VStack(alignment: .leading, spacing: 16) {
      masterOutput
      monitorOutput
      activeCaptures
      scenes
    }
    .padding(18)
  }

  private var header: some View {
    HStack(spacing: 9) {
      Image("LoopKitMenuTemplate")
        .renderingMode(.template)
        .resizable()
        .scaledToFit()
        .frame(width: 22, height: 22)
        .foregroundStyle(LoopKitTheme.teal)
      Text("LoopKit")
        .font(.system(size: 18, weight: .bold))
      Spacer()
      LoopKitStatusPill(connectionLabel, color: connectionColor)
      Button {
        openDashboard()
      } label: {
        Image(systemName: "gearshape")
          .font(.system(size: 15, weight: .semibold))
          .frame(width: 28, height: 28)
      }
      .buttonStyle(.plain)
      .foregroundStyle(LoopKitTheme.secondaryText)
      .help("Open dashboard")
    }
    .padding(.horizontal, 18)
    .frame(height: 58)
    .background(LoopKitTheme.surface.opacity(0.45))
  }

  private var masterOutput: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack {
        compactLabel("MASTER OUTPUT")
        Spacer()
        Text(loopKitDecibelString(model.masterGain))
          .font(LoopKitTheme.mono(11, weight: .medium))
          .foregroundStyle(LoopKitTheme.teal)
      }

      LoopKitHorizontalFader(
        value: Binding(
          get: { model.masterGain },
          set: { model.masterGain = $0 }
        ),
        in: 0...2,
        onEditingChanged: { editing in
          if !editing { model.applyMasterGain() }
        }
      )
    }
  }

  private var monitorOutput: some View {
    VStack(alignment: .leading, spacing: 8) {
      compactLabel("MONITOR OUTPUT")
      LoopKitPanel {
        Button {
          monitorPickerPresented.toggle()
        } label: {
          HStack(spacing: 11) {
            Image(systemName: "headphones")
              .font(.system(size: 19))
              .foregroundStyle(LoopKitTheme.secondaryText)
            VStack(alignment: .leading, spacing: 2) {
              Text(model.deviceName(uid: model.monitorDeviceUID))
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
              Text("48kHz · OUTPUT")
                .font(LoopKitTheme.mono(8))
                .foregroundStyle(LoopKitTheme.secondaryText)
            }
            Spacer()
            Image(systemName: "chevron.down")
              .font(.caption.weight(.semibold))
              .foregroundStyle(LoopKitTheme.secondaryText)
          }
          .padding(11)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $monitorPickerPresented, arrowEdge: .bottom) {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(model.monitorDevices, id: \.uid) { device in
              Button {
                model.monitorDeviceUID = device.uid
                model.applyMonitorDevice(device.uid)
                monitorPickerPresented = false
              } label: {
                HStack {
                  Text(device.name)
                  Spacer()
                  if device.uid == model.monitorDeviceUID {
                    Image(systemName: "checkmark").foregroundStyle(LoopKitTheme.teal)
                  }
                }
                .frame(width: 240, alignment: .leading)
                .padding(7)
              }
              .buttonStyle(.plain)
            }
          }
          .padding(8)
          .background(LoopKitTheme.panel)
          .preferredColorScheme(.dark)
        }
      }
    }
  }

  private var activeCaptures: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        compactLabel("ACTIVE CAPTURES")
        Spacer()
        Text("\(selectedCaptureApps.count) APPS")
          .font(LoopKitTheme.mono(9, weight: .medium))
          .foregroundStyle(LoopKitTheme.teal)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(LoopKitTheme.teal.opacity(0.10))
          .clipShape(Capsule())
      }

      if selectedCaptureApps.isEmpty {
        Text("No applications are selected for capture.")
          .font(.caption)
          .foregroundStyle(LoopKitTheme.secondaryText)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 10)
      } else {
        VStack(spacing: 7) {
          ForEach(selectedCaptureApps.prefix(5), id: \.bundleID) { app in
            MenuCaptureRow(
              app: app,
              meter: model.meter(for: app.sourceID),
              isClipping: model.isClipping(app.sourceID),
              onToggle: { model.setCaptureSelected(bundleID: app.bundleID, isSelected: $0) }
            )
          }
        }
      }
    }
  }

  private var scenes: some View {
    VStack(alignment: .leading, spacing: 9) {
      compactLabel("SCENES")
      if model.scenes.isEmpty {
        Text("Save scenes from the dashboard for one-click access here.")
          .font(.caption)
          .foregroundStyle(LoopKitTheme.secondaryText)
      } else {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
          ForEach(model.scenes.prefix(4), id: \.self) { scene in
            Button {
              model.selectedSceneName = scene
              model.loadSelectedScene()
            } label: {
              Text(scene)
                .font(LoopKitTheme.mono(10, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .background(model.selectedSceneName == scene ? LoopKitTheme.teal.opacity(0.14) : LoopKitTheme.panelHigh)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                  RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(model.selectedSceneName == scene ? LoopKitTheme.teal.opacity(0.55) : LoopKitTheme.rim, lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
  }

  private var footer: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(model.connection == .connected ? LoopKitTheme.signal : LoopKitTheme.error)
        .frame(width: 6, height: 6)
      Text(engineSummary)
        .font(LoopKitTheme.mono(9))
        .foregroundStyle(LoopKitTheme.secondaryText)
      Spacer()
      Button("Setup…") {
        setupComplete = false
        openDashboard()
      }
      .buttonStyle(.plain)
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(LoopKitTheme.secondaryText)
      Button("Open Dashboard") { openDashboard() }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(LoopKitTheme.teal)
    }
    .padding(.horizontal, 18)
    .frame(height: 48)
    .background(LoopKitTheme.surface.opacity(0.55))
  }

  private var selectedCaptureApps: [LKXPCCaptureApp] {
    model.captureApps.filter(\.selected)
  }

  private var connectionLabel: String {
    switch model.connection {
    case .connected: return "LIVE"
    case .connecting: return "WAIT"
    case .disconnected: return "OFF"
    }
  }

  private var connectionColor: Color {
    switch model.connection {
    case .connected: return LoopKitTheme.signal
    case .connecting: return LoopKitTheme.warning
    case .disconnected: return LoopKitTheme.error
    }
  }

  private var engineSummary: String {
    guard let status = model.status else { return "Engine: waiting" }
    return "Engine: \(status.sampleRate / 1000)kHz · \(status.blockFrames)f"
  }

  private func compactLabel(_ text: String) -> some View {
    Text(text)
      .font(LoopKitTheme.mono(9, weight: .semibold))
      .tracking(1.1)
      .foregroundStyle(LoopKitTheme.secondaryText)
  }

  private func openDashboard() {
    openWindow(id: "dashboard")
    NSApp.activate(ignoringOtherApps: true)
  }
}

private struct MenuCaptureRow: View {
  let app: LKXPCCaptureApp
  let meter: LKXPCMeter?
  let isClipping: Bool
  let onToggle: (Bool) -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: SourcePresentation.symbol(for: app.displayName))
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(LoopKitTheme.teal)
        .frame(width: 30, height: 30)
        .background(LoopKitTheme.teal.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

      VStack(alignment: .leading, spacing: 5) {
        HStack {
          Text(app.displayName)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
          Spacer()
          Text(levelLabel)
            .font(LoopKitTheme.mono(8))
            .foregroundStyle(LoopKitTheme.secondaryText)
        }
        LoopKitStereoMeter(
          left: meter?.peakL ?? 0,
          right: meter?.peakR ?? 0,
          isClipping: isClipping
        )
          .frame(height: 7)
      }

      Button { onToggle(!app.selected) } label: {
        ZStack(alignment: app.selected ? .trailing : .leading) {
          Capsule()
            .fill(app.selected ? LoopKitTheme.signal.opacity(0.55) : LoopKitTheme.panelHigh)
            .frame(width: 36, height: 18)
          Circle()
            .fill(app.selected ? LoopKitTheme.teal : LoopKitTheme.secondaryText)
            .frame(width: 14, height: 14)
            .padding(2)
        }
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Capture \(app.displayName)")
      .accessibilityValue(app.selected ? "On" : "Off")
    }
  }

  private var levelLabel: String {
    let peak = max(meter?.peakL ?? 0, meter?.peakR ?? 0)
    guard peak > 0 else { return "-inf" }
    return String(format: "%.0f dB", 20 * log10(peak))
  }
}

#if DEBUG
#Preview("Menu Bar Controller") {
  MenuBarControllerView(model: .demoModel(), startsServices: false)
}
#endif
