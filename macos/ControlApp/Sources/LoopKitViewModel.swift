import Foundation
import SwiftUI
import LoopKitIPC

/// @MainActor so all @Published writes happen on the main thread and we can
/// safely read state from SwiftUI without ceremony.
@MainActor
final class LoopKitViewModel: ObservableObject {
  @Published var masterGain: Double = 1.0
  @Published var monitorDeviceUID: String = "system.default"
  @Published var inputDeviceUID: String = "system.default"
  @Published var outputDevices: [LKXPCDevice] = []
  @Published var inputDevices: [LKXPCDevice] = []
  @Published var captureApps: [LKXPCCaptureApp] = []
  @Published var sources: [LKXPCSourceState] = []
  @Published var routes: [LKXPCRoute] = []
  @Published var meters: [String: LKXPCMeter] = [:]
  @Published private(set) var clippingSourceIDs: Set<String> = []
  @Published var status: LKXPCStatus?
  @Published var scenes: [String] = []
  @Published var selectedSceneName: String = ""
  @Published var captureWarning: String?
  @Published var monitorWarning: String?
  @Published var inputWarning: String?
  @Published var broadcastOutputWarning: String?
  @Published var broadcastOutputReady: Bool = false
  @Published var connection: LoopKitConnectionState = .connecting
  @Published var lastActionMessage: String?
  /// Suppresses differential source-list updates while the user is
  /// actively dragging a control, so SwiftUI bindings aren't torn down
  /// mid-gesture.
  @Published var interactingSourceID: String?

  private let daemon = LoopKitDaemonClient()
  private var activeSurfaceCount = 0
  private var startupTask: Task<Void, Never>?
  private var pollingTask: Task<Void, Never>?
  private var meterTask: Task<Void, Never>?
  /// UIDs of monitor-device pickers we've just pushed to the daemon, so
  /// the echoed status update doesn't re-fire `applyMonitorDevice`.
  private var pendingMonitorEcho: String?
  private var pendingInputEcho: String?
  private var clipHoldUntil: [String: Date] = [:]

  // MARK: Lifecycle

  func onAppear() {
    activeSurfaceCount += 1
    guard activeSurfaceCount == 1 else { return }

    startupTask?.cancel()
    startupTask = Task {
      await daemon.setStateObserver { [weak self] state in
        Task { @MainActor in
          self?.connection = state
        }
      }
      await daemon.reconnect()
      await reloadDevices()
      await reloadInputDevices()
      await reloadCaptureApps()
      await reloadSources()
      await reloadRoutes()
      await reloadScenes()
      await refreshStatus()
      guard !Task.isCancelled, activeSurfaceCount > 0 else { return }
      startStatusPolling()
      startMeterPolling()
    }
  }

  func onDisappear() {
    activeSurfaceCount = max(0, activeSurfaceCount - 1)
    guard activeSurfaceCount == 0 else { return }
    startupTask?.cancel()
    startupTask = nil
    pollingTask?.cancel()
    pollingTask = nil
    meterTask?.cancel()
    meterTask = nil
  }

  // MARK: User actions

  func applyMasterGain() {
    Task {
      let result = await daemon.setMasterGain(masterGain)
      if !result.success {
        lastActionMessage = result.message ?? "Failed to set master gain"
      }
    }
  }

  func applySource(_ source: LKXPCSourceState) {
    // Reflect locally first so the UI doesn't wait on a round-trip.
    if let index = sources.firstIndex(where: { $0.id == source.id }) {
      sources[index] = source
    }
    Task {
      let result = await daemon.setSource(source)
      let toggleResult = await daemon.setSourceToggles(
        source.id,
        mute: source.mute,
        solo: source.solo,
        enabled: source.enabled
      )
      if !result.success {
        lastActionMessage = result.message ?? "Failed to set source params"
      } else if !toggleResult.success {
        lastActionMessage = toggleResult.message ?? "Failed to set source toggles"
      }
    }
  }

  func applyMonitorDevice(_ uid: String) {
    if pendingMonitorEcho == uid {
      pendingMonitorEcho = nil
      return
    }
    Task {
      let result = await daemon.setMonitorDevice(uid: uid)
      if !result.success {
        lastActionMessage = result.message ?? "Failed to set monitor output"
      } else if let message = result.message, !message.isEmpty {
        lastActionMessage = message
      }
    }
  }

  func applyInputDevice(_ uid: String) {
    if pendingInputEcho == uid {
      pendingInputEcho = nil
      return
    }
    Task {
      let result = await daemon.setInputDevice(uid: uid)
      if !result.success {
        lastActionMessage = result.message ?? "Failed to set input device"
      } else if let message = result.message, !message.isEmpty {
        lastActionMessage = message
      }
    }
  }

  func setCaptureSelected(bundleID: String, isSelected: Bool) {
    var selected = Set(captureApps.filter(\.selected).map(\.bundleID))
    if isSelected { selected.insert(bundleID) } else { selected.remove(bundleID) }
    Task {
      let result = await daemon.setCapturedApps(bundleIDs: Array(selected).sorted())
      if result.success {
        await reloadCaptureApps()
        await reloadSources()
        await reloadRoutes()
      } else {
        lastActionMessage = result.message ?? "Failed to update captured apps"
      }
    }
  }

  func saveCurrentScene(name: String) {
    let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return }
    let scene = LKXPCScene(
      name: cleaned,
      masterGain: masterGain,
      monitorDeviceUID: monitorDeviceUID,
      sources: sources,
      routes: routes
    )
    Task {
      let result = await daemon.saveScene(scene)
      if result.success {
        await reloadScenes()
        selectedSceneName = cleaned
        lastActionMessage = "Saved scene \(cleaned)"
      } else {
        lastActionMessage = result.message ?? "Failed to save scene"
      }
    }
  }

  func loadSelectedScene() {
    let name = selectedSceneName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    Task {
      let (scene, result) = await daemon.loadScene(name: name)
      guard result.success, let scene else {
        lastActionMessage = result.message ?? "Failed to load scene"
        return
      }
      masterGain = scene.masterGain
      monitorDeviceUID = scene.monitorDeviceUID
      sources = scene.sources
      if let sceneRoutes = scene.routes {
        routes = sceneRoutes
      } else {
        routes = await daemon.listRoutes()
      }
      await reloadCaptureApps()
      lastActionMessage = "Loaded scene \(scene.name)"
    }
  }

  func retryConnection() {
    Task {
      await daemon.reconnect()
      await refreshStatus()
      await reloadDevices()
      await reloadInputDevices()
      await reloadCaptureApps()
      await reloadSources()
      await reloadRoutes()
    }
  }

  func requestMicrophoneAccess() {
    Task {
      let result = await daemon.requestMicrophoneAccess()
      lastActionMessage = result.success
        ? "Microphone access granted"
        : (result.message ?? "Microphone access was not granted")
      await refreshStatus()
      await reloadInputDevices()
    }
  }

  // MARK: Polling

  private func startStatusPolling() {
    pollingTask?.cancel()
    pollingTask = Task { [weak self] in
      while !Task.isCancelled {
        await self?.refreshStatus()
        try? await Task.sleep(nanoseconds: 500_000_000)  // 2 Hz
      }
    }
  }

  private func startMeterPolling() {
    meterTask?.cancel()
    meterTask = Task { [weak self] in
      while !Task.isCancelled {
        await self?.refreshMeters()
        try? await Task.sleep(nanoseconds: 33_000_000)  // ~30 Hz
      }
    }
  }

  // MARK: Data loading

  private func reloadDevices() async {
    let devices = await daemon.listDevices()
    outputDevices = devices
    if monitorDeviceUID == "system.default",
       let defaultDevice = devices.first(where: { $0.isDefault }) {
      monitorDeviceUID = defaultDevice.uid
    }
  }

  private func reloadInputDevices() async {
    let devices = await daemon.listInputDevices()
    inputDevices = devices
    if inputDeviceUID == "system.default",
       let defaultDevice = devices.first(where: { $0.isDefault }) {
      inputDeviceUID = defaultDevice.uid
    }
  }

  private func reloadCaptureApps() async {
    captureApps = await daemon.listCaptureApps()
  }

  private func reloadSources() async {
    let next = await daemon.listSources()
    // Merge rather than overwrite: keep the user's local edits for any
    // source they're currently touching, but sync new sources (e.g. a
    // freshly-captured app) and preserve display-name updates.
    if let heldID = interactingSourceID,
       let existing = sources.first(where: { $0.id == heldID }) {
      var merged = next
      if let idx = merged.firstIndex(where: { $0.id == heldID }) {
        merged[idx] = existing
      }
      sources = merged
    } else {
      sources = next
    }
  }

  private func reloadRoutes() async {
    routes = await daemon.listRoutes()
  }

  private func reloadScenes() async {
    scenes = await daemon.listScenes()
  }

  private func refreshStatus() async {
    guard let next = await daemon.getStatus() else {
      status = nil
      return
    }
    status = next
    captureWarning = next.captureWarning?.nonEmpty
    monitorWarning = next.monitorWarning?.nonEmpty
    inputWarning = next.inputWarning?.nonEmpty
    broadcastOutputWarning = next.broadcastOutputWarning?.nonEmpty
    broadcastOutputReady = next.broadcastOutputConnected
    if monitorDeviceUID != next.activeMonitorDeviceUID {
      pendingMonitorEcho = next.activeMonitorDeviceUID
      monitorDeviceUID = next.activeMonitorDeviceUID
    }
    if inputDeviceUID != next.activeInputDeviceUID {
      pendingInputEcho = next.activeInputDeviceUID
      inputDeviceUID = next.activeInputDeviceUID
    }
  }

  private func refreshMeters() async {
    let next = await daemon.subscribeMeters()
    meters = Dictionary(uniqueKeysWithValues: next.map { ($0.sourceID, $0) })
    let now = Date()
    for meter in next where meter.clippedL || meter.clippedR {
      clipHoldUntil[meter.sourceID] = now.addingTimeInterval(1)
    }
    clipHoldUntil = clipHoldUntil.filter { $0.value > now }
    clippingSourceIDs = Set(clipHoldUntil.keys)
  }

  // MARK: Derived view helpers

  func meter(for sourceID: String) -> LKXPCMeter? { meters[sourceID] }

  func isClipping(_ sourceID: String) -> Bool {
    clippingSourceIDs.contains(sourceID)
  }

  var monitorDevices: [LKXPCDevice] {
    outputDevices.filter {
      $0.uid != "BlackHole2ch_UID"
        && $0.uid != status?.activeBroadcastDeviceUID
        && $0.name.localizedCaseInsensitiveCompare("BlackHole 2ch") != .orderedSame
    }
  }

  func hasRoute(sourceID: String, destinationID: String) -> Bool {
    routes.contains { $0.sourceID == sourceID && $0.destinationID == destinationID }
  }

  func toggleRoute(sourceID: String, destinationID: String) {
    var next = routes.filter {
      !($0.sourceID == sourceID && $0.destinationID == destinationID)
    }
    if next.count == routes.count {
      next.append(LKXPCRoute(sourceID: sourceID, destinationID: destinationID))
    }
    next.sort {
      $0.sourceID == $1.sourceID
        ? $0.destinationID < $1.destinationID
        : $0.sourceID < $1.sourceID
    }
    routes = next
    Task {
      let result = await daemon.setRoutes(next)
      if !result.success {
        lastActionMessage = result.message ?? "Failed to update routing"
        await reloadRoutes()
      }
    }
  }

  func echoRiskBundleID(sourceID: String, destinationID: String) -> String? {
    guard destinationID == LKRouteDestinationBroadcast,
          !hasRoute(sourceID: sourceID, destinationID: destinationID),
          sourceID.hasPrefix("app:")
    else { return nil }
    let bundleID = String(sourceID.dropFirst(4))
    return LoopKitApplicationPolicy.isCommunicationsApplication(bundleID) ? bundleID : nil
  }

  func approveEchoRiskAndEnableRoute(sourceID: String, bundleID: String) {
    Task {
      let result = await daemon.approveEchoRisk(bundleID: bundleID, approved: true)
      guard result.success else {
        lastActionMessage = result.message ?? "Failed to approve the communications-app route"
        return
      }
      toggleRoute(sourceID: sourceID, destinationID: LKRouteDestinationBroadcast)
    }
  }

  func deviceName(uid: String, inputs: Bool = false) -> String {
    let pool = inputs ? inputDevices : outputDevices
    return pool.first(where: { $0.uid == uid })?.name ?? uid
  }
}

private extension String {
  var nonEmpty: String? { isEmpty ? nil : self }
}
