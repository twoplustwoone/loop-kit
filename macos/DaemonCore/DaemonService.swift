import Foundation
import LoopKitAudioCore
import LoopKitIPC
import LoopKitEngine

private let kProcessingFrames: UInt32 = 512

public final class LoopKitDaemonService: NSObject, LoopKitDaemonXPCProtocol {
  private static let micSourceID = "mic"
  private static let appSourcePrefix = "app:"

  // BlackHole 2ch is the default Discord-facing virtual device. Users set
  // Discord's mic input to "BlackHole 2ch" and we write the mix there.
  private static let kBlackHoleDeviceUID = "BlackHole2ch_UID"
  private static let kBlackHoleDeviceName = "BlackHole 2ch"

  private let queue = DispatchQueue(label: "com.example.LoopKit.loopkitd.state")
  private let maintenanceQueue = DispatchQueue(
    label: "com.example.LoopKit.loopkitd.maintenance",
    qos: .utility
  )
  private let sceneStore = SceneStore(folder: SceneStore.defaultFolder)
  private let processTapManager = LKProcessTapManager(maxFrames: kProcessingFrames)
  private let monitorOutputManager = LKAudioOutputRouter(
    label: "Monitor", sampleRate: 48_000, maxFrames: kProcessingFrames
  )
  private let broadcastOutputManager = LKAudioOutputRouter(
    label: "Broadcast", sampleRate: 48_000, maxFrames: kProcessingFrames
  )
  private let micInputManager = LKMicInputManager(sampleRate: 48_000, maxFrames: kProcessingFrames)

  private let sampleRate = 48_000
  private let blockFrames: UInt32 = kProcessingFrames
  private let maxFrames: UInt32 = kProcessingFrames

  private var engine: OpaquePointer?
  private var processingTimer: DispatchSourceTimer?
  private var maintenanceTimer: DispatchSourceTimer?

  private var masterGain: Double = 1.0
  private var requestedMonitorDeviceUID: String = "system.default"
  private var activeMonitorDeviceUID: String = "system.default"
  private var monitorFallbackActive: Bool = false
  private var monitorWarning: String?
  private var sources: [String: LKXPCSourceState] = [:]
  private var routeTable = RouteTable()
  private var capturedAppBundleIDs: [String] = []
  private var captureAppDisplayNames: [String: String] = [:]
  private var latestMeters: [LKXPCMeter] = []

  private var captureMode: String = LKCaptureModeUnavailable
  private var activeTapCount: Int = 0
  private var captureWarning: String?
  private var monitorActive: Bool = false
  private var monitorIdleSince: Date?
  private var monitorDeviceSampleRate: Int = 0
  private let monitorIdleStopSeconds: TimeInterval = 30.0
  private let monitorSilenceThreshold: Float = 1.0e-5

  // Input-device state. Populated by MicInputManager once wired; default to
  // system input until then.
  private var requestedInputDeviceUID: String = "system.default"
  private var activeInputDeviceUID: String = "system.default"
  private var inputWarning: String?
  private var micInputDeviceSampleRate: Int = 0

  // Broadcast-output state.
  private var activeBroadcastDeviceUID: String = ""
  private var broadcastOutputSampleRate: Int = 0
  private var broadcastOutputWarning: String?
  private var lastBroadcastRetry: Date = .distantPast

  private var nextFrameIndex: UInt64 = 0
  private var lastError: String?

  private var appBusLeft = [Float](repeating: 0, count: Int(kProcessingFrames))
  private var appBusRight = [Float](repeating: 0, count: Int(kProcessingFrames))
  private var monitorAppBusLeft = [Float](repeating: 0, count: Int(kProcessingFrames))
  private var monitorAppBusRight = [Float](repeating: 0, count: Int(kProcessingFrames))
  private var tapScratchLeft = [Float](repeating: 0, count: Int(kProcessingFrames))
  private var tapScratchRight = [Float](repeating: 0, count: Int(kProcessingFrames))
  private var micLeft = [Float](repeating: 0, count: Int(kProcessingFrames))
  private var micRight = [Float](repeating: 0, count: Int(kProcessingFrames))
  private var broadcastLeft = [Float](repeating: 0, count: Int(kProcessingFrames))
  private var broadcastRight = [Float](repeating: 0, count: Int(kProcessingFrames))
  private var monitorLeft = [Float](repeating: 0, count: Int(kProcessingFrames))
  private var monitorRight = [Float](repeating: 0, count: Int(kProcessingFrames))

  public override init() {
    super.init()
    queue.sync {
      ensureCoreSourcesLocked()
      bootstrapDSP()
      startProcessingLoop()
      startMaintenanceLoop()
    }
  }

  deinit {
    processingTimer?.cancel()
    processingTimer = nil
    maintenanceTimer?.cancel()
    maintenanceTimer = nil
    monitorOutputManager.stop()
    broadcastOutputManager.stop()
    micInputManager.stop()
    if let engine {
      lk_engine_destroy(engine)
    }
  }

  public func setMasterGain(_ gain: Double, withReply reply: @escaping (LKXPCResult) -> Void) {
    queue.async {
      self.masterGain = ControlPolicy.gain(gain)
      self.syncEngineStateLocked()
      reply(LKXPCResult(success: true))
    }
  }

  public func setSourceParams(_ source: LKXPCSourceState, withReply reply: @escaping (LKXPCResult) -> Void) {
    queue.async {
      self.sources[source.id] = self.sanitizedSource(source)
      self.syncEngineStateLocked()
      reply(LKXPCResult(success: true))
    }
  }

  public func setMuteSolo(sourceID: String, mute: Bool, solo: Bool, enabled: Bool, withReply reply: @escaping (LKXPCResult) -> Void) {
    queue.async {
      guard let current = self.sources[sourceID] else {
        reply(LKXPCResult(success: false, message: "Unknown source \(sourceID)"))
        return
      }
      current.mute = mute
      current.solo = solo
      current.enabled = enabled
      self.sources[sourceID] = current
      self.syncEngineStateLocked()
      reply(LKXPCResult(success: true))
    }
  }

  public func setMonitorDevice(uid: String, withReply reply: @escaping (LKXPCResult) -> Void) {
    queue.async {
      let devices = AudioDevices.outputDevices()
      guard devices.contains(where: { $0.uid == uid }) || uid == "system.default" else {
        reply(LKXPCResult(success: false, message: "Monitor output device not found"))
        return
      }
      self.requestedMonitorDeviceUID = uid
      let switched = self.applyMonitorDeviceLocked(preferredUID: uid, allowFallback: true, reason: "manual switch")
      if switched {
        reply(LKXPCResult(success: true, message: self.monitorFallbackActive ? self.monitorWarning : nil))
      } else {
        reply(LKXPCResult(success: false, message: self.monitorWarning ?? "Failed to set monitor output device"))
      }
    }
  }

  public func listDevices(_ reply: @escaping ([LKXPCDevice]) -> Void) {
    queue.async {
      let devices = AudioDevices.outputDevices()
      if devices.isEmpty {
        reply([LKXPCDevice(uid: "system.default", name: "System Default Output", isDefault: true)])
      } else {
        reply(devices)
      }
    }
  }

  public func listInputDevices(_ reply: @escaping ([LKXPCDevice]) -> Void) {
    queue.async {
      let devices = AudioDevices.inputDevices()
      if devices.isEmpty {
        reply([LKXPCDevice(uid: "system.default", name: "System Default Input", isDefault: true)])
      } else {
        reply(devices)
      }
    }
  }

  public func setInputDevice(uid: String, withReply reply: @escaping (LKXPCResult) -> Void) {
    queue.async {
      let known = AudioDevices.inputDevices().contains(where: { $0.uid == uid }) || uid == "system.default"
      guard known else {
        reply(LKXPCResult(success: false, message: "Input device not found"))
        return
      }
      self.requestedInputDeviceUID = uid
      self.applyInputDeviceLocked()
      reply(LKXPCResult(success: self.inputWarning == nil, message: self.inputWarning))
    }
  }

  public func listCaptureApps(_ reply: @escaping ([LKXPCCaptureApp]) -> Void) {
    queue.async {
      let selected = Set(self.capturedAppBundleIDs)
      self.maintenanceQueue.async {
        let discovered = self.processTapManager.listApps()
        self.queue.async {
          for app in discovered {
            self.captureAppDisplayNames[app.bundleID] = app.displayName
          }

          var byBundle: [String: LKXPCCaptureApp] = [:]
          for app in discovered {
            let bundleID = app.bundleID
            let sourceID = Self.sourceID(forBundleID: bundleID)
            byBundle[bundleID] = LKXPCCaptureApp(
              bundleID: bundleID,
              displayName: app.displayName,
              pid: Int(app.pid),
              running: app.running,
              selected: selected.contains(bundleID),
              sourceID: sourceID
            )
          }

          for bundleID in selected where byBundle[bundleID] == nil {
            byBundle[bundleID] = LKXPCCaptureApp(
              bundleID: bundleID,
              displayName: bundleID,
              pid: 0,
              running: false,
              selected: true,
              sourceID: Self.sourceID(forBundleID: bundleID)
            )
          }

          let apps = byBundle.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
          }
          reply(apps)
        }
      }
    }
  }

  public func setCapturedApps(bundleIDs: [String], withReply reply: @escaping (LKXPCResult) -> Void) {
    queue.async {
      let sanitized = Self.sanitizedBundleIDs(bundleIDs)
      self.capturedAppBundleIDs = sanitized
      self.processTapManager.setSelectedBundleIDs(sanitized)
      self.ensureCaptureSourcesLocked()
      self.requestTapReconcile()
      reply(LKXPCResult(success: true))
    }
  }

  public func listSources(_ reply: @escaping ([LKXPCSourceState]) -> Void) {
    queue.async {
      reply(self.visibleSourcesLocked().map(self.cloneSource))
    }
  }

  public func listRoutes(_ reply: @escaping ([LKXPCRoute]) -> Void) {
    queue.async {
      self.ensureCaptureSourcesLocked()
      reply(self.routeTable.xpcRoutes())
    }
  }

  public func setRoutes(_ routes: [LKXPCRoute], withReply reply: @escaping (LKXPCResult) -> Void) {
    queue.async {
      self.ensureCaptureSourcesLocked()
      do {
        try self.routeTable.replace(with: routes)
        reply(LKXPCResult(success: true))
      } catch {
        reply(LKXPCResult(success: false, message: error.localizedDescription))
      }
    }
  }

  public func saveScene(_ scene: LKXPCScene, withReply reply: @escaping (LKXPCResult) -> Void) {
    queue.async {
      do {
        let routedScene = LKXPCScene(
          name: scene.name,
          masterGain: scene.masterGain,
          monitorDeviceUID: scene.monitorDeviceUID,
          sources: scene.sources,
          routes: self.routeTable.xpcRoutes()
        )
        try self.sceneStore.write(
          routedScene,
          capturedAppBundleIDs: self.capturedAppBundleIDs,
          captureModePreference: "processTapPreferred",
          playbackPolicy: "redirectMuted"
        )
        reply(LKXPCResult(success: true))
      } catch {
        reply(LKXPCResult(success: false, message: error.localizedDescription))
      }
    }
  }

  public func loadScene(name: String, withReply reply: @escaping (LKXPCScene?, LKXPCResult) -> Void) {
    queue.async {
      do {
        let loaded = try self.sceneStore.read(named: name)
        let scene = loaded.scene
        self.masterGain = scene.masterGain
        self.requestedMonitorDeviceUID = scene.monitorDeviceUID
        self.sources = Dictionary(
          uniqueKeysWithValues: scene.sources.map {
            ($0.id, self.sanitizedSource($0))
          }
        )
        self.capturedAppBundleIDs = Self.sanitizedBundleIDs(loaded.capturedAppBundleIDs)
        self.processTapManager.setSelectedBundleIDs(self.capturedAppBundleIDs)
        self.ensureCaptureSourcesLocked()
        self.routeTable.restore(scene.routes, sourceIDs: Set(self.sources.keys))
        self.syncEngineStateLocked()
        self.requestTapReconcile()
        _ = self.applyMonitorDeviceLocked(preferredUID: self.requestedMonitorDeviceUID, allowFallback: true, reason: "scene load")
        reply(scene, LKXPCResult(success: true))
      } catch {
        reply(nil, LKXPCResult(success: false, message: error.localizedDescription))
      }
    }
  }

  public func listScenes(_ reply: @escaping ([String]) -> Void) {
    queue.async {
      reply(self.sceneStore.listNames())
    }
  }

  public func getStatus(_ reply: @escaping (LKXPCStatus) -> Void) {
    queue.async {
      let tapUnderruns = self.processTapManager.tapUnderruns()
      let tapOverruns = self.processTapManager.tapOverruns()
      let monitorUnderruns = self.monitorOutputManager.underrunCount()
      let monitorOverruns = self.monitorOutputManager.overrunCount()
      let broadcastUnderruns = self.broadcastOutputManager.underrunCount()
      let broadcastOverruns = self.broadcastOutputManager.overrunCount()
      let tapSampleRate = Int(self.processTapManager.tapSampleRate().rounded())
      reply(
        LKXPCStatus(
          daemonOnline: true,
          sampleRate: self.sampleRate,
          blockFrames: Int(self.blockFrames),
          tapOverruns: tapOverruns,
          tapUnderruns: tapUnderruns,
          monitorOverruns: monitorOverruns,
          monitorUnderruns: monitorUnderruns,
          broadcastOverruns: broadcastOverruns,
          broadcastUnderruns: broadcastUnderruns,
          tapSampleRate: tapSampleRate,
          errorMessage: self.lastError,
          captureMode: self.captureMode,
          activeTapCount: self.activeTapCount,
          captureWarning: self.captureWarning,
          requestedMonitorDeviceUID: self.requestedMonitorDeviceUID,
          activeMonitorDeviceUID: self.activeMonitorDeviceUID,
          monitorFallbackActive: self.monitorFallbackActive,
          monitorWarning: self.monitorWarning,
          monitorDeviceSampleRate: self.monitorDeviceSampleRate,
          micInputDeviceSampleRate: self.micInputDeviceSampleRate,
          requestedInputDeviceUID: self.requestedInputDeviceUID,
          activeInputDeviceUID: self.activeInputDeviceUID,
          inputWarning: self.inputWarning,
          broadcastOutputConnected: self.broadcastOutputManager.isRunning(),
          activeBroadcastDeviceUID: self.activeBroadcastDeviceUID,
          broadcastOutputSampleRate: self.broadcastOutputSampleRate,
          broadcastOutputWarning: self.broadcastOutputWarning
        )
      )
    }
  }

  public func subscribeMeters(_ reply: @escaping ([LKXPCMeter]) -> Void) {
    queue.async {
      reply(self.latestMeters)
    }
  }

  private static func sanitizedBundleIDs(_ bundleIDs: [String]) -> [String] {
    Array(Set(bundleIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
  }

  private static func sourceID(forBundleID bundleID: String) -> String {
    "\(appSourcePrefix)\(bundleID)"
  }

  private func cloneSource(_ source: LKXPCSourceState) -> LKXPCSourceState {
    LKXPCSourceState(
      id: source.id,
      displayName: source.displayName,
      gain: source.gain,
      mute: source.mute,
      solo: source.solo,
      enabled: source.enabled
    )
  }

  private func sanitizedSource(_ source: LKXPCSourceState) -> LKXPCSourceState {
    LKXPCSourceState(
      id: source.id,
      displayName: source.displayName,
      gain: ControlPolicy.gain(source.gain),
      mute: source.mute,
      solo: source.solo,
      enabled: source.enabled
    )
  }

  private func ensureCoreSourcesLocked() {
    if sources[Self.micSourceID] == nil {
      sources[Self.micSourceID] = LKXPCSourceState(
        id: Self.micSourceID,
        displayName: "Microphone",
        gain: 1.0,
        mute: false,
        solo: false,
        enabled: true
      )
    }
    routeTable.reconcile(sourceIDs: Set(sources.keys))
  }

  private func ensureCaptureSourcesLocked() {
    ensureCoreSourcesLocked()

    let selectedSourceIDs = Set(capturedAppBundleIDs.map(Self.sourceID(forBundleID:)))
    for sourceID in sources.keys where sourceID.hasPrefix(Self.appSourcePrefix)
      && !selectedSourceIDs.contains(sourceID)
    {
      sources.removeValue(forKey: sourceID)
    }

    for bundleID in capturedAppBundleIDs {
      let sourceID = Self.sourceID(forBundleID: bundleID)
      if sources[sourceID] == nil {
        let displayName = captureAppDisplayNames[bundleID] ?? bundleID
        sources[sourceID] = LKXPCSourceState(
          id: sourceID,
          displayName: displayName,
          gain: 1.0,
          mute: false,
          solo: false,
          enabled: true
        )
      } else if let knownName = captureAppDisplayNames[bundleID] {
        if let current = sources[sourceID], current.displayName != knownName {
          sources[sourceID] = LKXPCSourceState(
            id: current.id,
            displayName: knownName,
            gain: current.gain,
            mute: current.mute,
            solo: current.solo,
            enabled: current.enabled
          )
        }
      }
    }
    routeTable.reconcile(sourceIDs: Set(sources.keys))
  }

  private func visibleSourcesLocked() -> [LKXPCSourceState] {
    ensureCaptureSourcesLocked()

    var sourceIDs = capturedAppBundleIDs.map(Self.sourceID(forBundleID:))
    sourceIDs = sourceIDs.filter { sources[$0] != nil }

    sourceIDs.append(Self.micSourceID)

    return sourceIDs.compactMap { sources[$0] }
  }

  private func bootstrapDSP() {
    var config = lk_engine_config(sample_rate: UInt32(sampleRate), max_block_frames: maxFrames)
    engine = lk_engine_create(&config)
    syncEngineStateLocked()
    // Only eagerly activate the monitor when the user has picked a specific
    // device. For the default case we stay silent until there's audio worth
    // routing — no point holding the physical output open otherwise.
    if requestedMonitorDeviceUID != "system.default" {
      _ = applyMonitorDeviceLocked(preferredUID: requestedMonitorDeviceUID, allowFallback: true, reason: "startup")
    }
    applyBroadcastOutputLocked(force: true)
    applyInputDeviceLocked()
  }

  // Resolve BlackHole 2ch (by UID, then by name) and activate the Broadcast
  // adapter. On miss, set a warning; retry at most once per 5 s from
  // the health loop so the user's CPU doesn't thrash if BlackHole is absent.
  @discardableResult
  private func applyBroadcastOutputLocked(force: Bool) -> Bool {
    let now = Date()
    if !force && now.timeIntervalSince(lastBroadcastRetry) < 5.0 && !broadcastOutputManager.isRunning() {
      return false
    }
    lastBroadcastRetry = now

    let outputs = AudioDevices.outputDevices()
    let byUID = outputs.first(where: { $0.uid == Self.kBlackHoleDeviceUID })
    let byName = byUID ?? outputs.first(where: { $0.name == Self.kBlackHoleDeviceName })

    guard let device = byName else {
      broadcastOutputManager.stop()
      activeBroadcastDeviceUID = ""
      broadcastOutputSampleRate = 0
      broadcastOutputWarning =
        "BlackHole 2ch not installed — run the LoopKit installer to install it."
      return false
    }

    if broadcastOutputManager.activateDevice(withUID: device.uid) {
      activeBroadcastDeviceUID = device.uid
      let rate = broadcastOutputManager.deviceSampleRate()
      broadcastOutputSampleRate = Int(rate.rounded())
      broadcastOutputWarning = nil
      return true
    }

    let err = broadcastOutputManager.lastError()
    broadcastOutputWarning = err.isEmpty ? "Failed to activate BlackHole 2ch" : err
    activeBroadcastDeviceUID = ""
    broadcastOutputSampleRate = 0
    return false
  }

  private func applyInputDeviceLocked() {
    // Request mic permission once; a denial will surface as a warning rather
    // than stopping the daemon. Per-launch caching is fine since TCC short-
    // circuits on subsequent calls.
    if !micInputManager.requestPermissionSync() {
      inputWarning = "Microphone permission denied — enable it in System Settings › Privacy & Security › Microphone."
      activeInputDeviceUID = "system.default"
      micInputDeviceSampleRate = 0
      return
    }

    if micInputManager.activateDevice(withUID: requestedInputDeviceUID) {
      activeInputDeviceUID = micInputManager.activeDeviceUID()
      let rate = micInputManager.inputDeviceSampleRate()
      micInputDeviceSampleRate = Int(rate.rounded())
      let err = micInputManager.lastError()
      inputWarning = err.isEmpty ? nil : err
    } else {
      activeInputDeviceUID = "system.default"
      micInputDeviceSampleRate = 0
      let err = micInputManager.lastError()
      inputWarning = err.isEmpty ? "Failed to activate input device" : err
    }
  }

  private func startProcessingLoop() {
    processingTimer?.cancel()
    processingTimer = nil

    let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
    let tickNanoseconds = max(1_000_000, Int((Double(blockFrames) / Double(sampleRate)) * 1_000_000_000.0))
    timer.schedule(
      deadline: .now(),
      repeating: .nanoseconds(tickNanoseconds),
      leeway: .nanoseconds(max(50_000, tickNanoseconds / 20))
    )
    timer.setEventHandler { [weak self] in
      self?.processAudioTickLocked()
    }
    timer.resume()
    processingTimer = timer
  }

  private func startMaintenanceLoop() {
    maintenanceTimer?.cancel()
    maintenanceTimer = nil

    let timer = DispatchSource.makeTimerSource(queue: maintenanceQueue)
    timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(100))
    timer.setEventHandler { [weak self] in
      self?.performMaintenance()
    }
    timer.resume()
    maintenanceTimer = timer
  }

  private func syncEngineStateLocked() {
    guard let engine else { return }
    ensureCoreSourcesLocked()

    lk_engine_set_master_gain(engine, Float(masterGain))

    let appParams = lk_source_params(gain: 1.0, mute: 0, solo: 0, enabled: 1)
    let micSource = sources[Self.micSourceID] ?? LKXPCSourceState(
      id: Self.micSourceID, displayName: "Microphone", gain: 1, mute: false, solo: false, enabled: true
    )
    let micParams = lk_source_params(
      gain: Float(ControlPolicy.gain(micSource.gain)),
      mute: 0,
      solo: 0,
      enabled: 1
    )
    lk_engine_set_source_params(engine, UInt32(LK_SOURCE_APP), appParams)
    lk_engine_set_source_params(engine, UInt32(LK_SOURCE_MIC), micParams)
  }

  private func requestTapReconcile() {
    maintenanceQueue.async { [weak self] in
      self?.reconcileProcessTaps()
    }
  }

  private func reconcileProcessTaps() {
    processTapManager.reconcile()
    let tapCount = Int(processTapManager.activeTapCount())
    let warning = normalizedWarning(processTapManager.lastWarning())

    queue.async { [weak self] in
      guard let self else { return }
      self.activeTapCount = tapCount
      self.captureWarning = warning
      if tapCount > 0 && !self.capturedAppBundleIDs.isEmpty {
        self.captureMode = LKCaptureModeProcessTap
      } else {
        self.captureMode = LKCaptureModeUnavailable
        if !self.capturedAppBundleIDs.isEmpty && self.captureWarning == nil {
          self.captureWarning = "Selected application capture is unavailable; no fallback capture adapter is configured"
        }
      }
    }
  }

  private func performMaintenance() {
    reconcileProcessTaps()

    let shouldCheckMonitor = queue.sync { monitorActive }
    guard shouldCheckMonitor else { return }

    let healthWarning = normalizedWarning(monitorOutputManager.healthWarning())
    queue.async { [weak self] in
      guard let self else { return }
      if let healthWarning {
        _ = self.applyMonitorDeviceLocked(
          preferredUID: self.requestedMonitorDeviceUID,
          allowFallback: true,
          reason: "health-check"
        )
        if self.monitorWarning == nil {
          self.monitorWarning = healthWarning
        }
      } else if !self.monitorFallbackActive {
        self.monitorWarning = nil
      }
    }
  }

  private func normalizedWarning(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  @discardableResult
  private func applyMonitorDeviceLocked(preferredUID: String, allowFallback: Bool, reason _: String) -> Bool {
    let devices = AudioDevices.outputDevices()
    let decision = MonitorOutputPolicy.activate(
      requestedUID: preferredUID,
      devices: devices.map { MonitorOutputDevice(uid: $0.uid, name: $0.name) },
      defaultUID: AudioDevices.defaultOutputUID(),
      allowFallback: allowFallback
    ) { uid in
      if self.monitorOutputManager.activateDevice(withUID: uid) {
        return nil
      }
      return self.normalizedWarning(self.monitorOutputManager.lastError())
        ?? "Failed to open Monitor \(uid)"
    }

    guard let activeUID = decision.activeUID else {
      monitorActive = false
      monitorFallbackActive = false
      monitorWarning = decision.warning
      return false
    }

    activeMonitorDeviceUID = activeUID
    monitorDeviceSampleRate = Int(monitorOutputManager.deviceSampleRate().rounded())
    monitorActive = true
    monitorIdleSince = nil
    monitorFallbackActive = decision.fallbackActive
    monitorWarning = decision.warning
    return true
  }

  private func updateMonitorLifecycleLocked(mixMeter: lk_meter_block) {
    let peak = max(mixMeter.peak_l, mixMeter.peak_r)
    let silent = peak < monitorSilenceThreshold

    if !monitorActive {
      if !silent {
        _ = applyMonitorDeviceLocked(
          preferredUID: requestedMonitorDeviceUID,
          allowFallback: true,
          reason: "lazy-start"
        )
      }
      return
    }

    if silent {
      if monitorIdleSince == nil {
        monitorIdleSince = Date()
      } else if let since = monitorIdleSince,
                Date().timeIntervalSince(since) >= monitorIdleStopSeconds {
        monitorOutputManager.stop()
        monitorActive = false
        monitorIdleSince = nil
      }
    } else {
      monitorIdleSince = nil
    }
  }

  private func sourceIsActive(_ source: LKXPCSourceState, soloEnabled: Bool) -> Bool {
    if !source.enabled || source.mute {
      return false
    }
    if soloEnabled && !source.solo {
      return false
    }
    return true
  }

  private func meterForBuffer(
    sourceID: String,
    left: [Float],
    right: [Float],
    frames: Int,
    gain: Float,
    active: Bool
  ) -> LKXPCMeter {
    guard active, frames > 0 else {
      return LKXPCMeter(sourceID: sourceID, peakL: 0, peakR: 0, rmsL: 0, rmsR: 0)
    }

    var peakL: Float = 0
    var peakR: Float = 0
    var sumSqL: Double = 0
    var sumSqR: Double = 0
    for i in 0..<frames {
      let l = left[i] * gain
      let r = right[i] * gain
      peakL = max(peakL, abs(l))
      peakR = max(peakR, abs(r))
      sumSqL += Double(l * l)
      sumSqR += Double(r * r)
    }

    return LKXPCMeter(
      sourceID: sourceID,
      peakL: Double(peakL),
      peakR: Double(peakR),
      rmsL: sqrt(sumSqL / Double(frames)),
      rmsR: sqrt(sumSqR / Double(frames))
    )
  }

  private func mixIntoBus(
    left: [Float],
    right: [Float],
    frames: Int,
    gain: Float,
    busLeft: inout [Float],
    busRight: inout [Float]
  ) {
    guard frames > 0 else { return }
    for i in 0..<frames {
      busLeft[i] += left[i] * gain
      busRight[i] += right[i] * gain
    }
  }

  private func processAudioTickLocked() {
    guard let engine else { return }

    // Reattempt BlackHole binding at a low rate if it isn't currently bound.
    if !broadcastOutputManager.isRunning() {
      _ = applyBroadcastOutputLocked(force: false)
    }

    ensureCaptureSourcesLocked()

    let frameCount: UInt32 = blockFrames
    let frameIndex: UInt64 = nextFrameIndex

    zeroStereoBuffers(left: &appBusLeft, right: &appBusRight, frames: Int(frameCount))
    zeroStereoBuffers(left: &monitorAppBusLeft, right: &monitorAppBusRight, frames: Int(frameCount))
    zeroStereoBuffers(left: &broadcastLeft, right: &broadcastRight, frames: Int(frameCount))
    zeroStereoBuffers(left: &monitorLeft, right: &monitorRight, frames: Int(frameCount))

    // Pull the mic lane from AVAudioEngine → AsyncResampler (48 kHz) →
    // engine. On underrun, the resampler zero-fills for us.
    zeroStereoBuffers(left: &micLeft, right: &micRight, frames: Int(frameCount))
    _ = withStereoMutableBuffers(left: &micLeft, right: &micRight) { left, right in
      micInputManager.copyAudioLeft(left, right: right, maxFrames: frameCount)
    }

    let sourceIDs = visibleSourcesLocked().map(\.id)
    let soloEnabled = sourceIDs.compactMap { sources[$0] }.contains(where: { $0.enabled && !$0.mute && $0.solo })
    var meterMap: [String: LKXPCMeter] = [:]

    for bundleID in capturedAppBundleIDs {
      let sourceID = Self.sourceID(forBundleID: bundleID)
      guard let source = sources[sourceID] else { continue }

      zeroStereoBuffers(left: &tapScratchLeft, right: &tapScratchRight, frames: Int(frameCount))
      let tapFrames = withStereoMutableBuffers(left: &tapScratchLeft, right: &tapScratchRight) { left, right in
        processTapManager.copyAudio(forBundleID: bundleID, left: left, right: right, maxFrames: frameCount)
      }
      let active = sourceIsActive(source, soloEnabled: soloEnabled)
      let meter = meterForBuffer(
        sourceID: sourceID,
        left: tapScratchLeft,
        right: tapScratchRight,
        frames: Int(min(frameCount, tapFrames)),
        gain: Float(source.gain),
        active: active
      )
      meterMap[sourceID] = meter

      if active, tapFrames > 0 {
        let mixedFrames = Int(min(frameCount, tapFrames))
        if routeTable.contains(sourceID: sourceID, destinationID: LKRouteDestinationBroadcast) {
          mixIntoBus(
            left: tapScratchLeft,
            right: tapScratchRight,
            frames: mixedFrames,
            gain: Float(source.gain),
            busLeft: &appBusLeft,
            busRight: &appBusRight
          )
        }
        if routeTable.contains(sourceID: sourceID, destinationID: LKRouteDestinationMonitor) {
          mixIntoBus(
            left: tapScratchLeft,
            right: tapScratchRight,
            frames: mixedFrames,
            gain: Float(source.gain),
            busLeft: &monitorAppBusLeft,
            busRight: &monitorAppBusRight
          )
        }
      }
    }

    var micActive = false
    if let mic = sources[Self.micSourceID] {
      micActive = sourceIsActive(mic, soloEnabled: soloEnabled)
      meterMap[Self.micSourceID] = meterForBuffer(
        sourceID: Self.micSourceID,
        left: micLeft,
        right: micRight,
        frames: Int(frameCount),
        gain: Float(mic.gain),
        active: micActive
      )
    }

    let micBroadcastFrames = micActive
      && routeTable.contains(sourceID: Self.micSourceID, destinationID: LKRouteDestinationBroadcast)
      ? frameCount : 0
    let micMonitorFrames = micActive
      && routeTable.contains(sourceID: Self.micSourceID, destinationID: LKRouteDestinationMonitor)
      ? frameCount : 0
    var broadcastMeter = lk_meter_block(peak_l: 0, peak_r: 0, rms_l: 0, rms_r: 0)
    var monitorMeter = lk_meter_block(peak_l: 0, peak_r: 0, rms_l: 0, rms_r: 0)
    withAllBuffers { broadcastAppL, broadcastAppR, monitorAppL, monitorAppR, micL, micR, broadcastL, broadcastR, monitorL, monitorR in
      var broadcastAppIn = lk_input_audio_block(left: broadcastAppL, right: broadcastAppR, frames: frameCount)
      var broadcastMicIn = lk_input_audio_block(left: micL, right: micR, frames: micBroadcastFrames)
      var monitorAppIn = lk_input_audio_block(left: monitorAppL, right: monitorAppR, frames: frameCount)
      var monitorMicIn = lk_input_audio_block(left: micL, right: micR, frames: micMonitorFrames)
      var broadcastOut = lk_output_audio_block(left: broadcastL, right: broadcastR, frames: frameCount)
      var monitorOut = lk_output_audio_block(left: monitorL, right: monitorR, frames: frameCount)
      lk_engine_process_routed(
        engine,
        &broadcastAppIn,
        &broadcastMicIn,
        &monitorAppIn,
        &monitorMicIn,
        &broadcastOut,
        &monitorOut,
        &broadcastMeter,
        &monitorMeter
      )
    }

    // The Broadcast stream is always-on: a downstream consumer such as
    // Discord expects continuous audio even during silence, unlike the
    // idle-stoppable Monitor path.
    if broadcastOutputManager.isRunning() {
      withStereoMutableBuffers(left: &broadcastLeft, right: &broadcastRight) { left, right in
        broadcastOutputManager.enqueueLeft(left, right: right, frames: frameCount)
      }
    }

    updateMonitorLifecycleLocked(mixMeter: monitorMeter)
    if monitorActive {
      withStereoMutableBuffers(left: &monitorLeft, right: &monitorRight) { left, right in
        monitorOutputManager.enqueueLeft(left, right: right, frames: frameCount)
      }
    }

    if captureWarning == nil && broadcastOutputWarning == nil {
      lastError = nil
    }
    nextFrameIndex = frameIndex + UInt64(frameCount)

    let visibleSourceIDs = Set(visibleSourcesLocked().map(\.id))
    for sourceID in visibleSourceIDs where meterMap[sourceID] == nil {
      meterMap[sourceID] = LKXPCMeter(sourceID: sourceID, peakL: 0, peakR: 0, rmsL: 0, rmsR: 0)
    }
    latestMeters = meterMap.values.sorted {
      $0.sourceID.localizedCaseInsensitiveCompare($1.sourceID) == .orderedAscending
    }
  }

  private func zeroStereoBuffers(left: inout [Float], right: inout [Float], frames: Int) {
    guard frames > 0 else { return }
    for i in 0..<frames {
      left[i] = 0
      right[i] = 0
    }
  }

  private func withStereoMutableBuffers<R>(
    left: inout [Float],
    right: inout [Float],
    _ body: (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>) -> R
  ) -> R {
    left.withUnsafeMutableBufferPointer { leftBuffer in
      right.withUnsafeMutableBufferPointer { rightBuffer in
        body(leftBuffer.baseAddress!, rightBuffer.baseAddress!)
      }
    }
  }

  private func withAllBuffers(
    _ body: (
      UnsafeMutablePointer<Float>,
      UnsafeMutablePointer<Float>,
      UnsafeMutablePointer<Float>,
      UnsafeMutablePointer<Float>,
      UnsafeMutablePointer<Float>,
      UnsafeMutablePointer<Float>,
      UnsafeMutablePointer<Float>,
      UnsafeMutablePointer<Float>,
      UnsafeMutablePointer<Float>,
      UnsafeMutablePointer<Float>
    ) -> Void
  ) {
    withStereoMutableBuffers(left: &appBusLeft, right: &appBusRight) { appL, appR in
      withStereoMutableBuffers(left: &monitorAppBusLeft, right: &monitorAppBusRight) { monitorAppL, monitorAppR in
        withStereoMutableBuffers(left: &micLeft, right: &micRight) { micL, micR in
          withStereoMutableBuffers(left: &broadcastLeft, right: &broadcastRight) { broadcastL, broadcastR in
            withStereoMutableBuffers(left: &monitorLeft, right: &monitorRight) { monitorL, monitorR in
              body(appL, appR, monitorAppL, monitorAppR, micL, micR, broadcastL, broadcastR, monitorL, monitorR)
            }
          }
        }
      }
    }
  }

}
