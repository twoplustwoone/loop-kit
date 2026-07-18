import AppKit
import LoopKitIPC
import LoopKitUI
import SwiftUI

@MainActor
struct ContentView: View {
  @StateObject private var model: LoopKitViewModel
  @State private var sceneNameInput = ""
  @State private var diagnosticsExpanded = true
  @State private var sourceControlsExpanded = true
  @State private var selectedSourceID: String?

  private let startsServices: Bool

  init() {
    _model = StateObject(wrappedValue: LoopKitViewModel())
    startsServices = true
  }

  init(model: LoopKitViewModel, startsServices: Bool) {
    _model = StateObject(wrappedValue: model)
    self.startsServices = startsServices
  }

  var body: some View {
    VStack(spacing: 0) {
      DashboardTopBar(model: model, sourceControlsExpanded: $sourceControlsExpanded)

      HStack(spacing: 0) {
        SourcesSidebar(model: model)
          .frame(width: 250)

        Divider().overlay(LoopKitTheme.rim)

        RoutingWorkspace(
          model: model,
          selectedSourceID: $selectedSourceID,
          sourceControlsExpanded: sourceControlsExpanded
        )

        Divider().overlay(LoopKitTheme.rim)

        MasterSidebar(
          model: model,
          sceneNameInput: $sceneNameInput,
          diagnosticsExpanded: $diagnosticsExpanded
        )
        .frame(width: 292)
      }
    }
    .background(LoopKitTheme.background)
    .foregroundStyle(LoopKitTheme.text)
    .preferredColorScheme(.dark)
    .frame(minWidth: 1080, minHeight: 720)
    .onAppear {
      guard startsServices else { return }
      model.onAppear()
    }
    .onDisappear {
      guard startsServices else { return }
      model.onDisappear()
    }
  }
}

// MARK: - Top bar

private struct DashboardTopBar: View {
  @ObservedObject var model: LoopKitViewModel
  @Binding var sourceControlsExpanded: Bool

  var body: some View {
    HStack(spacing: 14) {
      HStack(spacing: 9) {
        Image(systemName: "infinity")
          .font(.system(size: 18, weight: .bold))
          .foregroundStyle(LoopKitTheme.teal)
        Text("LoopKit")
          .font(.system(size: 18, weight: .bold))
      }

      if let status = model.status {
        LoopKitStatusPill("\(status.sampleRate / 1000)kHz / FLOAT32")
        LoopKitStatusPill("\(status.blockFrames) FRAMES", color: LoopKitTheme.secondaryText)
      } else {
        LoopKitStatusPill("48kHz / FLOAT32", color: LoopKitTheme.secondaryText)
      }

      Spacer()

      connectionStatus

      Button {
        sourceControlsExpanded.toggle()
      } label: {
        Label(sourceControlsExpanded ? "Hide mixer" : "Show mixer", systemImage: "slider.vertical.3")
          .labelStyle(.iconOnly)
          .frame(width: 30, height: 30)
      }
      .buttonStyle(.plain)
      .foregroundStyle(sourceControlsExpanded ? LoopKitTheme.teal : LoopKitTheme.secondaryText)
      .help(sourceControlsExpanded ? "Hide Source controls" : "Show Source controls")

      Button {
        model.retryConnection()
      } label: {
        Image(systemName: "arrow.clockwise")
          .frame(width: 30, height: 30)
      }
      .buttonStyle(.plain)
      .foregroundStyle(LoopKitTheme.secondaryText)
      .help("Reconnect to loopkitd")
    }
    .padding(.horizontal, 20)
    .frame(height: 56)
    .background(LoopKitTheme.surface.opacity(0.96))
    .overlay(alignment: .bottom) { Divider().overlay(LoopKitTheme.rim) }
  }

  @ViewBuilder
  private var connectionStatus: some View {
    switch model.connection {
    case .connected:
      LoopKitStatusPill("CONNECTED", color: LoopKitTheme.signal)
    case .connecting:
      LoopKitStatusPill("CONNECTING", color: LoopKitTheme.warning)
    case .disconnected:
      LoopKitStatusPill("OFFLINE", color: LoopKitTheme.error)
    }
  }
}

// MARK: - Sources sidebar

private struct SourcesSidebar: View {
  @ObservedObject var model: LoopKitViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      LoopKitSectionLabel("Sources", subtitle: "Active streams")
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 14)

      Group {
        if model.captureApps.isEmpty {
          EmptySourcesState()
        } else {
          ViewThatFits(in: .vertical) {
            captureRows
            ScrollView { captureRows }
          }
        }
      }
      .padding(.horizontal, 14)

      Divider().overlay(LoopKitTheme.rim).padding(.vertical, 12)

      VStack(alignment: .leading, spacing: 13) {
        devicePicker(
          title: "Microphone input",
          icon: "mic",
          selection: $model.inputDeviceUID,
          devices: model.inputDevices,
          onChange: model.applyInputDevice
        )

        devicePicker(
          title: "Monitor output",
          icon: "headphones",
          selection: $model.monitorDeviceUID,
          devices: model.outputDevices,
          onChange: model.applyMonitorDevice
        )
      }
      .padding(.horizontal, 16)

      Spacer(minLength: 14)

      BroadcastOutputStatus(model: model)
        .padding(14)
    }
    .background(LoopKitTheme.panel.opacity(0.72))
  }

  private var captureRows: some View {
    VStack(spacing: 8) {
      ForEach(model.captureApps, id: \.bundleID) { app in
        CaptureSourceRow(
          app: app,
          meter: model.meter(for: app.sourceID),
          onToggle: { model.setCaptureSelected(bundleID: app.bundleID, isSelected: $0) }
        )
      }
    }
  }

  private func devicePicker(
    title: String,
    icon: String,
    selection: Binding<String>,
    devices: [LKXPCDevice],
    onChange: @escaping (String) -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(title.uppercased(), systemImage: icon)
        .font(LoopKitTheme.mono(9, weight: .medium))
        .tracking(1.1)
        .foregroundStyle(LoopKitTheme.secondaryText)
      Picker("", selection: selection) {
        ForEach(devices, id: \.uid) { device in
          Text(device.name).tag(device.uid)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .frame(maxWidth: .infinity)
      .onChange(of: selection.wrappedValue) { _, newValue in onChange(newValue) }
    }
  }
}

private struct EmptySourcesState: View {
  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: "waveform.slash")
        .font(.title2)
        .foregroundStyle(LoopKitTheme.secondaryText)
      Text("No applications detected")
        .font(.callout.weight(.medium))
      Text("Start audio in an app to make it available for capture.")
        .font(.caption)
        .multilineTextAlignment(.center)
        .foregroundStyle(LoopKitTheme.secondaryText)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 28)
  }
}

private struct CaptureSourceRow: View {
  let app: LKXPCCaptureApp
  let meter: LKXPCMeter?
  let onToggle: (Bool) -> Void

  var body: some View {
    VStack(spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: sourceIcon(app.displayName))
          .frame(width: 20)
          .foregroundStyle(app.selected ? LoopKitTheme.teal : LoopKitTheme.secondaryText)
        VStack(alignment: .leading, spacing: 1) {
          Text(app.displayName)
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
          Text(app.running ? app.bundleID : "Not running")
            .font(LoopKitTheme.mono(8))
            .foregroundStyle(LoopKitTheme.secondaryText.opacity(0.7))
            .lineLimit(1)
        }
        Spacer()
        Toggle("", isOn: Binding(get: { app.selected }, set: onToggle))
          .labelsHidden()
          .toggleStyle(.switch)
          .controlSize(.mini)
          .tint(LoopKitTheme.signal)
      }

      LoopKitStereoMeter(
        left: meter?.peakL ?? 0,
        right: meter?.peakR ?? 0
      )
      .frame(height: 8)
      .opacity(app.selected ? 1 : 0.25)
    }
    .padding(10)
    .background(app.selected ? LoopKitTheme.teal.opacity(0.055) : Color.clear)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(app.selected ? LoopKitTheme.teal.opacity(0.16) : LoopKitTheme.rim, lineWidth: 1)
    }
  }
}

private struct BroadcastOutputStatus: View {
  @ObservedObject var model: LoopKitViewModel

  var body: some View {
    LoopKitPanel {
      HStack(spacing: 9) {
        Image(systemName: model.broadcastOutputReady ? "dot.radiowaves.left.and.right" : "exclamationmark.triangle")
          .foregroundStyle(model.broadcastOutputReady ? LoopKitTheme.teal : LoopKitTheme.error)
        VStack(alignment: .leading, spacing: 2) {
          Text("BLACKHOLE 2CH")
            .font(LoopKitTheme.mono(9, weight: .semibold))
          Text(model.broadcastOutputReady ? "Broadcast ready" : "Broadcast unavailable")
            .font(.caption2)
            .foregroundStyle(LoopKitTheme.secondaryText)
        }
        Spacer()
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString("BlackHole 2ch", forType: .string)
        } label: {
          Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.plain)
        .foregroundStyle(LoopKitTheme.secondaryText)
        .help("Copy Broadcast device name")
      }
      .padding(10)
    }
  }
}

// MARK: - Routing workspace

private struct RoutingWorkspace: View {
  @ObservedObject var model: LoopKitViewModel
  @Binding var selectedSourceID: String?
  let sourceControlsExpanded: Bool

  var body: some View {
    VStack(spacing: 0) {
      RoutingPatchbay(model: model, selectedSourceID: $selectedSourceID)
        .frame(maxWidth: .infinity, maxHeight: .infinity)

      if sourceControlsExpanded {
        Divider().overlay(LoopKitTheme.rim)
        SourceControlsRack(model: model, selectedSourceID: $selectedSourceID)
          .frame(height: 300)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(.easeInOut(duration: 0.18), value: sourceControlsExpanded)
  }
}

private struct RoutingPatchbay: View {
  @ObservedObject var model: LoopKitViewModel
  @Binding var selectedSourceID: String?
  @State private var draggingSourceID: String?
  @State private var dragLocation: CGPoint?
  @State private var hoveredDestinationID: String?

  private var visibleSources: [LKXPCSourceState] { Array(model.sources.prefix(5)) }

  var body: some View {
    GeometryReader { proxy in
      let layout = PatchbayLayout(size: proxy.size, sourceCount: visibleSources.count)

      ZStack {
        LoopKitTheme.background
        PatchbayGrid()

        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
          let pulsePhase = CGFloat(timeline.date.timeIntervalSinceReferenceDate * 28)
          Canvas { context, _ in
            for (index, source) in visibleSources.enumerated() {
              let sourceActive = source.enabled && !source.mute
              if model.hasRoute(sourceID: source.id, destinationID: LKRouteDestinationBroadcast) {
                drawRoute(
                  context: &context,
                  from: layout.sourcePort(index: index),
                  to: layout.broadcastPort,
                  color: model.broadcastOutputReady
                    ? (sourceActive ? LoopKitTheme.teal : LoopKitTheme.secondaryText)
                    : LoopKitTheme.error,
                  opacity: sourceActive ? 0.78 : 0.18,
                  animated: sourceActive,
                  dotted: !sourceActive,
                  pulsePhase: pulsePhase
                )
              }
              if model.hasRoute(sourceID: source.id, destinationID: LKRouteDestinationMonitor) {
                drawRoute(
                  context: &context,
                  from: layout.sourcePort(index: index),
                  to: layout.monitorPort,
                  color: sourceActive ? LoopKitTheme.signal : LoopKitTheme.secondaryText,
                  opacity: sourceActive ? 0.55 : 0.14,
                  animated: sourceActive,
                  dotted: !sourceActive,
                  pulsePhase: pulsePhase
                )
              }
            }

            if let draggingSourceID,
               let index = visibleSources.firstIndex(where: { $0.id == draggingSourceID }),
               let dragLocation {
              drawRoute(
                context: &context,
                from: layout.sourcePort(index: index),
                to: dragLocation,
                color: hoveredDestinationID == nil ? LoopKitTheme.secondaryText : LoopKitTheme.teal,
                opacity: 0.9,
                animated: true,
                dotted: false,
                pulsePhase: pulsePhase
              )
            }
          }
        }

        if visibleSources.isEmpty {
          VStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
              .font(.system(size: 34, weight: .light))
              .foregroundStyle(LoopKitTheme.secondaryText)
            Text("Select an application to build the routing graph")
              .font(.callout)
              .foregroundStyle(LoopKitTheme.secondaryText)
          }
        }

        ForEach(Array(visibleSources.enumerated()), id: \.element.id) { index, source in
          PatchNode(
            title: source.displayName,
            subtitle: source.id == "mic" ? "PHYSICAL INPUT" : "CAPTURE SOURCE",
            icon: source.id == "mic" ? "mic" : sourceIcon(source.displayName),
            meter: model.meter(for: source.id),
            isActive: source.enabled,
            isSelected: selectedSourceID == source.id,
            portOnLeadingEdge: false
          )
          .frame(width: layout.nodeWidth, height: layout.nodeHeight)
          .position(layout.sourceCenter(index: index))
          .onTapGesture { selectedSourceID = source.id }
        }

        PatchNode(
          title: "Monitor",
          subtitle: model.deviceName(uid: model.monitorDeviceUID),
          icon: "headphones",
          meter: nil,
          isActive: model.status?.monitorFallbackActive == false,
          isSelected: false,
          portOnLeadingEdge: true
        )
        .frame(width: layout.nodeWidth, height: layout.nodeHeight)
        .position(layout.monitorCenter)

        PatchNode(
          title: "Broadcast",
          subtitle: "BLACKHOLE 2CH",
          icon: "dot.radiowaves.left.and.right",
          meter: nil,
          isActive: model.broadcastOutputReady,
          isSelected: false,
          portOnLeadingEdge: true
        )
        .frame(width: layout.nodeWidth, height: layout.nodeHeight)
        .position(layout.broadcastCenter)

        ForEach(Array(visibleSources.enumerated()), id: \.element.id) { index, source in
          RoutePort(color: LoopKitTheme.teal, highlighted: draggingSourceID == source.id)
            .position(layout.sourcePort(index: index))
            .gesture(
              DragGesture(minimumDistance: 1, coordinateSpace: .named("routingPatchbay"))
                .onChanged { value in
                  draggingSourceID = source.id
                  dragLocation = value.location
                  hoveredDestinationID = layout.destinationID(near: value.location)
                }
                .onEnded { value in
                  if let destinationID = layout.destinationID(near: value.location) {
                    model.toggleRoute(sourceID: source.id, destinationID: destinationID)
                  }
                  draggingSourceID = nil
                  dragLocation = nil
                  hoveredDestinationID = nil
                }
            )
            .help("Drag to Monitor or Broadcast; repeat to disconnect")
        }

        RoutePort(
          color: LoopKitTheme.signal,
          highlighted: hoveredDestinationID == LKRouteDestinationMonitor
        )
        .position(layout.monitorPort)

        RoutePort(
          color: LoopKitTheme.teal,
          highlighted: hoveredDestinationID == LKRouteDestinationBroadcast
        )
        .position(layout.broadcastPort)

        VStack(alignment: .leading, spacing: 2) {
          Text("ROUTING PATCHBAY")
            .font(LoopKitTheme.mono(10, weight: .semibold))
            .tracking(1.4)
          Text("Drag a source port to a destination · repeat to disconnect")
            .font(.caption)
            .foregroundStyle(LoopKitTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(18)
      }
      .clipped()
      .coordinateSpace(name: "routingPatchbay")
    }
  }

  private func drawRoute(
    context: inout GraphicsContext,
    from start: CGPoint,
    to end: CGPoint,
    color: Color,
    opacity: Double,
    animated: Bool,
    dotted: Bool,
    pulsePhase: CGFloat
  ) {
    var path = Path()
    path.move(to: start)
    let distance = max(60, (end.x - start.x) * 0.48)
    path.addCurve(
      to: end,
      control1: CGPoint(x: start.x + distance, y: start.y),
      control2: CGPoint(x: end.x - distance, y: end.y)
    )
    context.stroke(path, with: .color(color.opacity(opacity * 0.22)), lineWidth: 5)
    let dash: [CGFloat] = dotted ? [2, 5] : (animated ? [10, 8] : [])
    context.stroke(
      path,
      with: .color(color.opacity(opacity)),
      style: StrokeStyle(
        lineWidth: animated ? 2 : 1.2,
        lineCap: .round,
        dash: dash,
        dashPhase: animated ? -pulsePhase : 0
      )
    )
  }
}

private struct PatchbayLayout {
  let size: CGSize
  let sourceCount: Int
  let nodeWidth: CGFloat = 190
  let nodeHeight: CGFloat = 68

  private var sourceX: CGFloat { 30 + nodeWidth / 2 }
  private var destinationX: CGFloat { max(sourceX + 280, size.width - 30 - nodeWidth / 2) }
  private var sourceSpacing: CGFloat {
    min(100, max(76, (size.height - 130) / CGFloat(max(sourceCount, 1))))
  }
  private var sourceTop: CGFloat { max(82, (size.height - sourceSpacing * CGFloat(max(sourceCount - 1, 0))) / 2) }

  func sourceCenter(index: Int) -> CGPoint {
    CGPoint(x: sourceX, y: sourceTop + CGFloat(index) * sourceSpacing)
  }

  func sourcePort(index: Int) -> CGPoint {
    let center = sourceCenter(index: index)
    return CGPoint(x: center.x + nodeWidth / 2, y: center.y)
  }

  var monitorCenter: CGPoint { CGPoint(x: destinationX, y: size.height * 0.38) }
  var broadcastCenter: CGPoint { CGPoint(x: destinationX, y: size.height * 0.62) }
  var monitorPort: CGPoint { CGPoint(x: monitorCenter.x - nodeWidth / 2, y: monitorCenter.y) }
  var broadcastPort: CGPoint { CGPoint(x: broadcastCenter.x - nodeWidth / 2, y: broadcastCenter.y) }

  func destinationID(near point: CGPoint) -> String? {
    let destinations = [
      (LKRouteDestinationMonitor, monitorPort),
      (LKRouteDestinationBroadcast, broadcastPort),
    ]
    return destinations
      .map { destinationID, port in
        (destinationID, hypot(point.x - port.x, point.y - port.y))
      }
      .filter { $0.1 <= 52 }
      .min { $0.1 < $1.1 }?
      .0
  }
}

private struct RoutePort: View {
  let color: Color
  let highlighted: Bool

  var body: some View {
    Circle()
      .fill(LoopKitTheme.background)
      .overlay {
        Circle().stroke(color.opacity(highlighted ? 1 : 0.72), lineWidth: highlighted ? 3 : 1.5)
      }
      .background {
        if highlighted {
          Circle().fill(color.opacity(0.22)).blur(radius: 7)
        }
      }
      .frame(width: 14, height: 14)
      .frame(width: 34, height: 34)
      .contentShape(Circle())
      .animation(.easeOut(duration: 0.12), value: highlighted)
  }
}

private struct PatchbayGrid: View {
  var body: some View {
    Canvas { context, size in
      var path = Path()
      stride(from: CGFloat(0), through: size.width, by: 40).forEach { x in
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: x, y: size.height))
      }
      stride(from: CGFloat(0), through: size.height, by: 40).forEach { y in
        path.move(to: CGPoint(x: 0, y: y))
        path.addLine(to: CGPoint(x: size.width, y: y))
      }
      context.stroke(path, with: .color(Color.white.opacity(0.035)), lineWidth: 1)
    }
  }
}

private struct PatchNode: View {
  let title: String
  let subtitle: String
  let icon: String
  let meter: LKXPCMeter?
  let isActive: Bool
  let isSelected: Bool
  let portOnLeadingEdge: Bool

  var body: some View {
    LoopKitPanel {
      HStack(spacing: 11) {
        Image(systemName: icon)
          .font(.system(size: 18, weight: .medium))
          .foregroundStyle(isActive ? LoopKitTheme.teal : LoopKitTheme.secondaryText)
          .frame(width: 24)
        VStack(alignment: .leading, spacing: 5) {
          Text(title)
            .font(LoopKitTheme.mono(12, weight: .semibold))
            .lineLimit(1)
          Text(subtitle)
            .font(LoopKitTheme.mono(8, weight: .medium))
            .tracking(0.8)
            .foregroundStyle(LoopKitTheme.secondaryText)
            .lineLimit(1)
          if meter != nil {
            LoopKitStereoMeter(left: meter?.peakL ?? 0, right: meter?.peakR ?? 0)
              .frame(height: 7)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 14)
    }
    .overlay(alignment: portOnLeadingEdge ? .leading : .trailing) {
      Circle()
        .fill(LoopKitTheme.background)
        .overlay { Circle().stroke(isActive ? LoopKitTheme.teal : LoopKitTheme.secondaryText, lineWidth: 1.5) }
        .frame(width: 12, height: 12)
        .offset(x: portOnLeadingEdge ? -6 : 6)
    }
    .overlay {
      RoundedRectangle(cornerRadius: LoopKitTheme.panelRadius, style: .continuous)
        .stroke(isSelected ? LoopKitTheme.teal.opacity(0.75) : Color.clear, lineWidth: 1.5)
    }
    .opacity(isActive ? 1 : 0.58)
  }
}

private struct SourceControlsRack: View {
  @ObservedObject var model: LoopKitViewModel
  @Binding var selectedSourceID: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        LoopKitSectionLabel("Source controls", subtitle: "Gain, mute and solo")
        Spacer()
        Text("\(model.sources.count) SOURCES")
          .font(LoopKitTheme.mono(9, weight: .medium))
          .foregroundStyle(LoopKitTheme.secondaryText)
      }

      if model.sources.isEmpty {
        Text("Select an app to create Source controls.")
          .font(.callout)
          .foregroundStyle(LoopKitTheme.secondaryText)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ViewThatFits(in: .horizontal) {
          sourceStrips
          ScrollView(.horizontal) {
            sourceStrips
          }
          .scrollIndicators(.hidden)
        }
      }
    }
    .padding(14)
    .background(LoopKitTheme.surface)
  }

  private var sourceStrips: some View {
    HStack(spacing: 10) {
      ForEach(model.sources, id: \.id) { source in
        LoopKitSourceStrip(
          name: source.displayName,
          icon: source.id == "mic" ? "mic" : sourceIcon(source.displayName),
          gain: sourceBinding(source, keyPath: \.gain),
          isMuted: sourceBinding(source, keyPath: \.mute),
          isSolo: sourceBinding(source, keyPath: \.solo),
          isEnabled: sourceBinding(source, keyPath: \.enabled),
          peakLeft: model.meter(for: source.id)?.peakL ?? 0,
          peakRight: model.meter(for: source.id)?.peakR ?? 0,
          onEditingChanged: { editing in
            model.interactingSourceID = editing ? source.id : nil
            if !editing { model.applySource(source) }
          }
        )
        .overlay {
          RoundedRectangle(cornerRadius: LoopKitTheme.panelRadius, style: .continuous)
            .stroke(selectedSourceID == source.id ? LoopKitTheme.teal.opacity(0.7) : Color.clear, lineWidth: 1.5)
        }
        .onTapGesture { selectedSourceID = source.id }
      }
    }
  }

  private func sourceBinding<Value>(
    _ source: LKXPCSourceState,
    keyPath: ReferenceWritableKeyPath<LKXPCSourceState, Value>
  ) -> Binding<Value> {
    Binding(
      get: { source[keyPath: keyPath] },
      set: { value in
        source[keyPath: keyPath] = value
        model.applySource(source)
      }
    )
  }
}

// MARK: - Master sidebar

private struct MasterSidebar: View {
  @ObservedObject var model: LoopKitViewModel
  @Binding var sceneNameInput: String
  @Binding var diagnosticsExpanded: Bool

  private var masterPeakLeft: Double { model.meters.values.map(\.peakL).max() ?? 0 }
  private var masterPeakRight: Double { model.meters.values.map(\.peakR).max() ?? 0 }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
        HStack(alignment: .top) {
          LoopKitSectionLabel("Master mixer", subtitle: "Broadcast + Monitor")
          Spacer()
          LoopKitStatusPill(String(format: "%.2fx", model.masterGain))
        }

        HStack(alignment: .center, spacing: 16) {
          LoopKitStereoMeter(left: masterPeakLeft, right: masterPeakRight, isVertical: true)
            .frame(width: 34, height: 210)

          LoopKitVerticalFader(
            value: Binding(
              get: { model.masterGain },
              set: { model.masterGain = $0 }
            ),
            onEditingChanged: { editing in
              if !editing { model.applyMasterGain() }
            }
          )
          .frame(width: 68, height: 210)

          VStack(alignment: .leading) {
            Text("+6")
            Spacer()
            Text("0")
            Spacer()
            Text("-12")
            Spacer()
            Text("-36")
            Spacer()
            Text("-inf")
          }
          .font(LoopKitTheme.mono(8))
          .foregroundStyle(LoopKitTheme.secondaryText)

          Spacer()
        }
        .frame(maxWidth: .infinity)

        scenes
        warnings
        diagnostics
    }
    .padding(18)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(LoopKitTheme.panel.opacity(0.72))
  }

  private var scenes: some View {
    VStack(alignment: .leading, spacing: 10) {
      LoopKitSectionLabel("Scenes")

      if model.scenes.isEmpty {
        Text("No saved scenes")
          .font(.caption)
          .foregroundStyle(LoopKitTheme.secondaryText)
      } else {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
          ForEach(Array(model.scenes.enumerated()), id: \.element) { index, scene in
            Button {
              model.selectedSceneName = scene
              model.loadSelectedScene()
            } label: {
              VStack(alignment: .leading, spacing: 3) {
                Text(String(format: "%02d", index + 1))
                  .foregroundStyle(LoopKitTheme.teal)
                Text(scene)
                  .lineLimit(1)
              }
              .font(LoopKitTheme.mono(10, weight: .medium))
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(9)
              .background(model.selectedSceneName == scene ? LoopKitTheme.teal.opacity(0.12) : LoopKitTheme.panelHigh.opacity(0.72))
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

      HStack(spacing: 6) {
        TextField("New scene", text: $sceneNameInput)
          .textFieldStyle(.plain)
          .font(LoopKitTheme.mono(10))
          .padding(8)
          .background(LoopKitTheme.track)
          .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        Button {
          model.saveCurrentScene(name: sceneNameInput)
        } label: {
          Image(systemName: "plus")
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .background(LoopKitTheme.teal.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .foregroundStyle(LoopKitTheme.teal)
        .keyboardShortcut("s", modifiers: .command)
      }
    }
  }

  @ViewBuilder
  private var warnings: some View {
    let messages = [
      model.captureWarning,
      model.monitorWarning,
      model.inputWarning,
      model.broadcastOutputWarning,
      model.lastActionMessage
    ].compactMap { $0 }.filter { !$0.isEmpty }

    if !messages.isEmpty {
      VStack(alignment: .leading, spacing: 7) {
        ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
          HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(LoopKitTheme.warning)
            Text(message)
              .font(.caption)
              .foregroundStyle(LoopKitTheme.secondaryText)
          }
        }
      }
      .padding(10)
      .background(LoopKitTheme.warning.opacity(0.06))
      .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
  }

  private var diagnostics: some View {
    DisclosureGroup(isExpanded: $diagnosticsExpanded) {
      if let status = model.status {
        VStack(spacing: 6) {
          diagnosticRow("Capture", status.captureMode == LKCaptureModeProcessTap ? "Process Tap" : "Unavailable")
          diagnosticRow("Active taps", "\(status.activeTapCount)")
          diagnosticRow("Tap U/O", "\(status.tapUnderruns) / \(status.tapOverruns)")
          diagnosticRow("Monitor U/O", "\(status.monitorUnderruns) / \(status.monitorOverruns)")
          diagnosticRow("Broadcast U/O", "\(status.broadcastUnderruns) / \(status.broadcastOverruns)")
        }
        .padding(.top, 9)
      } else {
        Text("Waiting for daemon telemetry")
          .font(.caption)
          .foregroundStyle(LoopKitTheme.secondaryText)
          .padding(.top, 8)
      }
    } label: {
      Text("DIAGNOSTICS")
        .font(LoopKitTheme.mono(10, weight: .semibold))
        .tracking(1.1)
    }
  }

  private func diagnosticRow(_ title: String, _ value: String) -> some View {
    HStack {
      Text(title).foregroundStyle(LoopKitTheme.secondaryText)
      Spacer()
      Text(value).foregroundStyle(LoopKitTheme.teal)
    }
    .font(LoopKitTheme.mono(9))
  }
}

private func sourceIcon(_ name: String) -> String {
  let normalized = name.lowercased()
  if normalized.contains("spotify") || normalized.contains("music") { return "music.note" }
  if normalized.contains("safari") || normalized.contains("chrome") || normalized.contains("browser") { return "globe" }
  if normalized.contains("discord") || normalized.contains("slack") { return "bubble.left.and.bubble.right" }
  if normalized.contains("zoom") || normalized.contains("meet") { return "video" }
  return "waveform"
}

#if DEBUG
extension LoopKitViewModel {
  static func demoModel() -> LoopKitViewModel {
    let model = LoopKitViewModel()
    model.connection = .connected
    model.masterGain = 0.82
    model.monitorDeviceUID = "preview.monitor"
    model.inputDeviceUID = "preview.mic"
    model.outputDevices = [LKXPCDevice(uid: "preview.monitor", name: "Studio Display", isDefault: true)]
    model.inputDevices = [LKXPCDevice(uid: "preview.mic", name: "Scarlett 2i2 USB", isDefault: true)]

    let apps = [
      ("com.spotify.client", "Spotify", 0.68),
      ("com.apple.Safari", "Safari", 0.34),
      ("com.hnc.Discord", "Discord", 0.08)
    ]
    model.captureApps = apps.map { bundleID, name, _ in
      LKXPCCaptureApp(
        bundleID: bundleID,
        displayName: name,
        pid: 42,
        running: true,
        selected: true,
        sourceID: "app:\(bundleID)"
      )
    }
    model.sources = apps.map { bundleID, name, _ in
      LKXPCSourceState(
        id: "app:\(bundleID)",
        displayName: name,
        gain: 1,
        mute: false,
        solo: false,
        enabled: true
      )
    } + [
      LKXPCSourceState(id: "mic", displayName: "Physical Mic", gain: 0.9, mute: false, solo: false, enabled: true)
    ]
    model.routes = [
      LKXPCRoute(sourceID: "app:com.spotify.client", destinationID: LKRouteDestinationMonitor),
      LKXPCRoute(sourceID: "app:com.spotify.client", destinationID: LKRouteDestinationBroadcast),
      LKXPCRoute(sourceID: "app:com.apple.Safari", destinationID: LKRouteDestinationMonitor),
      LKXPCRoute(sourceID: "app:com.hnc.Discord", destinationID: LKRouteDestinationBroadcast),
      LKXPCRoute(sourceID: "mic", destinationID: LKRouteDestinationMonitor),
      LKXPCRoute(sourceID: "mic", destinationID: LKRouteDestinationBroadcast),
    ]
    model.meters = Dictionary(uniqueKeysWithValues: apps.map { bundleID, _, level in
      let sourceID = "app:\(bundleID)"
      return (sourceID, LKXPCMeter(sourceID: sourceID, peakL: level, peakR: level * 0.92, rmsL: level * 0.72, rmsR: level * 0.68))
    })
    model.scenes = ["Default", "Streaming", "Recording", "Monitor"]
    model.selectedSceneName = "Default"
    model.broadcastOutputReady = true
    model.status = LKXPCStatus(
      daemonOnline: true,
      sampleRate: 48_000,
      blockFrames: 512,
      captureMode: LKCaptureModeProcessTap,
      activeTapCount: 3,
      activeMonitorDeviceUID: "preview.monitor",
      monitorDeviceSampleRate: 48_000,
      micInputDeviceSampleRate: 48_000,
      activeInputDeviceUID: "preview.mic",
      broadcastOutputConnected: true,
      activeBroadcastDeviceUID: "BlackHole2ch_UID",
      broadcastOutputSampleRate: 48_000
    )
    return model
  }
}

#Preview("Obsidian Studio Dashboard") {
  ContentView(model: .demoModel(), startsServices: false)
    .frame(width: 1400, height: 900)
}
#endif
