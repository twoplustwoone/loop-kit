import Foundation
import LoopKitAudioCore
import LoopKitIPC
import LoopKitEngine

private let kProcessingFrames: UInt32 = 512
private let kProcessingWakeFrames: UInt64 = 256
private let kOutputLeadFrames: UInt64 = 1_536
private let kMaxCatchUpBlocks = 4

final class LoopKitDaemonRuntime {
  private static let micSourceID = "mic"
  private static let appSourcePrefix = "app:"

  // BlackHole 2ch is the default Discord-facing virtual device. Users set
  // Discord's mic input to "BlackHole 2ch" and we write the mix there.
  private static let kBlackHoleDeviceUID = "BlackHole2ch_UID"
  private static let kBlackHoleDeviceName = "BlackHole 2ch"

  private let queue = DispatchQueue(
    label: "com.twoplustwoone.LoopKit.agent.state",
    qos: .userInteractive
  )
  private let maintenanceQueue = DispatchQueue(
    label: "com.twoplustwoone.LoopKit.agent.maintenance",
    qos: .utility
  )
  private let sceneStore = SceneStore(folder: SceneStore.defaultFolder)
  private let sessionStore = SessionStore(file: SessionStore.defaultFile)
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

  private var captureMode: String = LKCaptureModeProcessTap
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
  private var processingSchedule = AudioProcessingSchedule(
    sampleRate: 48_000,
    blockFrames: UInt64(kProcessingFrames),
    leadFrames: kOutputLeadFrames,
    maxCatchUpBlocks: kMaxCatchUpBlocks
  )
  private var schedulerDiscontinuities: UInt64 = 0
  private var lastError: String?
  private var lifecycle = LKRuntimeLifecycleStarting
  private var microphonePermission = LKPermissionStateNotRequested
  private var started = false
  private var recentHealthTracker = RecentAudioHealthTracker()
  private var echoRiskAcknowledgements: Set<String> = []
  private lazy var sessionWriter = DebouncedSessionWriter(queue: queue) { [weak self] state in
    guard let self else { return }
    do {
      try self.sessionStore.write(state)
    } catch {
      self.lastError = "Could not save LoopKit state: \(error.localizedDescription)"
    }
  }

  private let audioBlocks = AudioBlockStorage(frameCapacity: Int(kProcessingFrames))

  init() {}

  func start() {
    queue.async {
      guard !self.started else { return }
      self.started = true
      self.lifecycle = LKRuntimeLifecycleStarting
      self.restoreSessionLocked()
      self.refreshMicrophonePermissionLocked()
      self.ensureCoreSourcesLocked()
      self.bootstrapDSP()
      if self.microphonePermission == LKPermissionStateGranted {
        self.applyInputDeviceLocked()
      }
      self.startProcessingLoop()
      self.startMaintenanceLoop()
      if self.engine == nil {
        self.lifecycle = LKRuntimeLifecycleFailed
      } else if self.broadcastOutputWarning != nil || self.captureWarning != nil || self.inputWarning != nil {
        self.lifecycle = LKRuntimeLifecycleDegraded
      } else {
        self.lifecycle = LKRuntimeLifecycleReady
      }
    }
  }

  deinit {
    sessionWriter.cancel()
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

  func handshake(_ reply: @escaping (LKXPCHandshake) -> Void) {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "development"
    reply(
      LKXPCHandshake(
        protocolVersion: LoopKitIPCProtocolVersion,
        minimumSupportedVersion: LoopKitIPCMinimumSupportedVersion,
        daemonVersion: version,
        capabilities: [
          LoopKitCapability.processTap,
          LoopKitCapability.microphonePermission,
          LoopKitCapability.echoRiskApproval,
          LoopKitCapability.recentHealth,
        ]
      )
    )
  }

  func setMasterGain(_ gain: Double, withReply reply: @escaping (LKXPCResult) -> Void) {
    queue.async {
      self.masterGain = ControlPolicy.gain(gain)
      self.syncEngineStateLocked()
      self.scheduleSessionSaveLocked()
      reply(LKXPCResult(success: true))
    }
  }

  func setSourceParams(_ source: LKXPCSourceState, withReply reply: @escaping (LKXPCResult) -> Void) {
    queue.async {
      self.sources[source.id] = self.sanitizedSource(source)
      self.syncEngineStateLocked()
      self.scheduleSessionSaveLocked()
      reply(LKXPCResult(success: true))
    }
  }

  func setMuteSolo(sourceID: String, mute: Bool, solo: Bool, enabled: Bool, withReply reply: @escaping (LKXPCResult) -> Void) {
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
      self.scheduleSessionSaveLocked()
      reply(LKXPCResult(success: true))
    }
  }

  func setMonitorDevice(uid: String, withReply reply: @escaping (LKXPCResult) -> Void) {
    queue.async {
      do {
        try RoutingSafetyPolicy.validateMonitorDevice(
          uid: uid,
          broadcastDeviceUID: self.activeBroadcastDeviceUID
        )
      } catch {
        reply(LKXPCResult(success: false, message: error.localizedDescription))
        return
      }
      let devices = AudioDevices.outputDevices()
      guard devices.contains(where: { $0.uid == uid }) || uid == "system.default" else {
        reply(LKXPCResult(success: false, message: "Monitor output device not found"))
        return
      }
      self.requestedMonitorDeviceUID = uid
      let switched = self.applyMonitorDeviceLocked(preferredUID: uid, allowFallback: true, reason: "manual switch")
      if switched {
        self.scheduleSessionSaveLocked()
        reply(LKXPCResult(success: true, message: self.monitorFallbackActive ? self.monitorWarning : nil))
      } else {
        reply(LKXPCResult(success: false, message: self.monitorWarning ?? "Failed to set monitor output device"))
      }
    }
  }

  func listDevices(_ reply: @escaping ([LKXPCDevice]) -> Void) {
    queue.async {
      let devices = AudioDevices.outputDevices()
      if devices.isEmpty {
        reply([LKXPCDevice(uid: "system.default", name: "System Default Output", isDefault: true)])
      } else {
        reply(devices)
      }
    }
  }

  func listInputDevices(_ reply: @escaping ([LKXPCDevice]) -> Void) {
    queue.async {
      let devices = AudioDevices.inputDevices()
      if devices.isEmpty {
        reply([LKXPCDevice(uid: "system.default", name: "System Default Input", isDefault: true)])
      } else {
        reply(devices)
      }
    }
  }

  func setInputDevice(uid: String, withReply reply: @escaping (LKXPCResult) -> Void) {
    queue.async {
      let known = AudioDevices.inputDevices().contains(where: { $0.uid == uid }) || uid == "system.default"
      guard known else {
        reply(LKXPCResult(success: false, message: "Input device not found"))
        return
      }
      self.requestedInputDeviceUID = uid
      guard self.microphonePermission == LKPermissionStateGranted else {
        self.scheduleSessionSaveLocked()
        reply(LKXPCResult(
          success: false,
          message: "Choose Enable Microphone in LoopKit setup before selecting an input device."
        ))
        return
      }
      self.applyInputDeviceLocked()
      self.scheduleSessionSaveLocked()
      reply(LKXPCResult(success: self.inputWarning == nil, message: self.inputWarning))
    }
  }

  func listCaptureApps(_ reply: @escaping ([LKXPCCaptureApp]) -> Void) {
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

  func setCapturedApps(bundleIDs: [String], withReply reply: @escaping (LKXPCResult) -> Void) {
    queue.async {
      let sanitized = Self.sanitizedBundleIDs(bundleIDs)
      do {
        try RoutingSafetyPolicy.validateCapturedApplications(sanitized)
      } catch {
        reply(LKXPCResult(success: false, message: error.localizedDescription))
        return
      }
      self.capturedAppBundleIDs = sanitized
      self.processTapManager.setSelectedBundleIDs(sanitized)
      self.ensureCaptureSourcesLocked()
      self.requestTapReconcile()
      self.scheduleSessionSaveLocked()
      reply(LKXPCResult(success: true))
    }
  }

  func listSources(_ reply: @escaping ([LKXPCSourceState]) -> Void) {
    queue.async {
      reply(self.visibleSourcesLocked().map(self.cloneSource))
    }
  }

  func listRoutes(_ reply: @escaping ([LKXPCRoute]) -> Void) {
    queue.async {
      self.ensureCaptureSourcesLocked()
      reply(self.routeTable.xpcRoutes())
    }
  }

  func setRoutes(_ routes: [LKXPCRoute], withReply reply: @escaping (LKXPCResult) -> Void) {
    queue.async {
      self.ensureCaptureSourcesLocked()
      do {
        try RoutingSafetyPolicy.validateRoutes(
          routes,
          echoRiskAcknowledgements: self.echoRiskAcknowledgements
        )
        try self.routeTable.replace(with: routes)
        self.scheduleSessionSaveLocked()
        reply(LKXPCResult(success: true))
      } catch {
        reply(LKXPCResult(success: false, message: error.localizedDescription))
      }
    }
  }

  func refreshMicrophoneAuthorization(_ reply: @escaping (LKXPCResult) -> Void) {
    maintenanceQueue.async {
      let permission = self.micInputManager.permissionStatus()
      self.queue.async {
        switch permission {
        case .granted:
          self.microphonePermission = LKPermissionStateGranted
          self.applyInputDeviceLocked()
        case .denied:
          self.microphonePermission = LKPermissionStateDenied
          self.micInputManager.stop()
          self.inputWarning = "Microphone permission denied — enable it in System Settings › Privacy & Security › Microphone."
        case .notDetermined:
          self.microphonePermission = LKPermissionStateNotRequested
          self.micInputManager.stop()
          self.inputWarning = nil
        @unknown default:
          self.microphonePermission = LKPermissionStateDenied
          self.micInputManager.stop()
          self.inputWarning = "Microphone authorization is unavailable."
        }
        reply(LKXPCResult(success: true, message: self.inputWarning))
      }
    }
  }

  func approveEchoRisk(
    bundleID: String,
    approved: Bool,
    withReply reply: @escaping (LKXPCResult) -> Void
  ) {
    queue.async {
      guard RoutingSafetyPolicy.isCommunicationApplication(bundleID) else {
        reply(LKXPCResult(success: false, message: "\(bundleID) is not a recognized communications app"))
        return
      }
      if approved {
        self.echoRiskAcknowledgements.insert(bundleID)
      } else {
        self.echoRiskAcknowledgements.remove(bundleID)
        let sourceID = SourceID(applicationBundleID: bundleID)
        var routes = self.routeTable.xpcRoutes()
        routes.removeAll {
          $0.sourceID == sourceID.rawValue && $0.destinationID == RouteDestination.broadcast.rawValue
        }
        try? self.routeTable.replace(with: routes)
      }
      self.scheduleSessionSaveLocked()
      reply(LKXPCResult(success: true))
    }
  }

  func saveScene(_ scene: LKXPCScene, withReply reply: @escaping (LKXPCResult) -> Void) {
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

  func loadScene(name: String, withReply reply: @escaping (LKXPCScene?, LKXPCResult) -> Void) {
    queue.async {
      do {
        let loaded = try self.sceneStore.read(named: name)
        let scene = loaded.scene
        let capturedBundleIDs = Self.sanitizedBundleIDs(loaded.capturedAppBundleIDs)
        try RoutingSafetyPolicy.validateCapturedApplications(capturedBundleIDs)
        try RoutingSafetyPolicy.validateMonitorDevice(
          uid: scene.monitorDeviceUID,
          broadcastDeviceUID: Self.kBlackHoleDeviceUID
        )
        if let routes = scene.routes {
          try RoutingSafetyPolicy.validateRoutes(
            routes,
            echoRiskAcknowledgements: self.echoRiskAcknowledgements
          )
        }

        self.masterGain = scene.masterGain
        self.requestedMonitorDeviceUID = scene.monitorDeviceUID
        self.sources = Dictionary(
          uniqueKeysWithValues: scene.sources.map {
            ($0.id, self.sanitizedSource($0))
          }
        )
        self.capturedAppBundleIDs = capturedBundleIDs
        self.processTapManager.setSelectedBundleIDs(self.capturedAppBundleIDs)
        self.ensureCaptureSourcesLocked()
        self.routeTable.restore(
          scene.routes,
          sourceIDs: Set(self.sources.keys.map { SourceID(rawValue: $0) }),
          defaults: RoutingSafetyPolicy.defaultDestinations
        )
        self.syncEngineStateLocked()
        self.requestTapReconcile()
        _ = self.applyMonitorDeviceLocked(preferredUID: self.requestedMonitorDeviceUID, allowFallback: true, reason: "scene load")
        self.scheduleSessionSaveLocked()
        reply(scene, LKXPCResult(success: true))
      } catch {
        reply(nil, LKXPCResult(success: false, message: error.localizedDescription))
      }
    }
  }

  func listScenes(_ reply: @escaping ([String]) -> Void) {
    queue.async {
      reply(self.sceneStore.listNames())
    }
  }

  func getStatus(_ reply: @escaping (LKXPCStatus) -> Void) {
    queue.async {
      let tapUnderruns = self.processTapManager.tapUnderruns()
      let tapOverruns = self.processTapManager.tapOverruns()
      let monitorUnderruns = self.monitorOutputManager.underrunCount()
      let monitorOverruns = self.monitorOutputManager.overrunCount()
      let broadcastUnderruns = self.broadcastOutputManager.underrunCount()
      let broadcastOverruns = self.broadcastOutputManager.overrunCount()
      let tapSampleRate = Int(self.processTapManager.tapSampleRate().rounded())
      let rates = self.recentHealthTracker.sample(
        counters: AudioHealthCounters(
          tapUnderruns: tapUnderruns,
          tapOverruns: tapOverruns,
          monitorUnderruns: monitorUnderruns,
          monitorOverruns: monitorOverruns,
          broadcastUnderruns: broadcastUnderruns,
          broadcastOverruns: broadcastOverruns
        )
      )
      if !self.started {
        self.lifecycle = LKRuntimeLifecycleStarting
      } else if self.engine == nil {
        self.lifecycle = LKRuntimeLifecycleFailed
      } else if self.captureWarning != nil || self.monitorWarning != nil
        || self.inputWarning != nil || self.broadcastOutputWarning != nil {
        self.lifecycle = LKRuntimeLifecycleDegraded
      } else {
        self.lifecycle = LKRuntimeLifecycleReady
      }
      let healthState: String
      if self.lifecycle == LKRuntimeLifecycleFailed || self.lastError != nil {
        healthState = LKHealthStateFault
      } else if self.lifecycle != LKRuntimeLifecycleReady || rates.hasRecentEvents {
        healthState = LKHealthStateRecovering
      } else {
        healthState = LKHealthStateHealthy
      }
      reply(
        LKXPCStatus(
          daemonOnline: true,
          runtimeLifecycle: self.lifecycle,
          microphonePermission: self.microphonePermission,
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
          broadcastOutputWarning: self.broadcastOutputWarning,
          tapUnderrunRate: rates.tapUnderruns,
          tapOverrunRate: rates.tapOverruns,
          monitorUnderrunRate: rates.monitorUnderruns,
          monitorOverrunRate: rates.monitorOverruns,
          broadcastUnderrunRate: rates.broadcastUnderruns,
          broadcastOverrunRate: rates.broadcastOverruns,
          monitorQueueFill: self.monitorOutputManager.queueFillRatio(),
          broadcastQueueFill: self.broadcastOutputManager.queueFillRatio(),
          schedulerDiscontinuities: self.schedulerDiscontinuities,
          healthState: healthState
        )
      )
    }
  }

  func subscribeMeters(_ reply: @escaping ([LKXPCMeter]) -> Void) {
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

  private func sessionSnapshotLocked() -> LoopKitSessionState {
    LoopKitSessionState(
      masterGain: masterGain,
      sources: sources.values.sorted { $0.id < $1.id }.map {
        SessionSourceState(
          id: $0.id,
          displayName: $0.displayName,
          gain: $0.gain,
          mute: $0.mute,
          solo: $0.solo,
          enabled: $0.enabled
        )
      },
      selectedApplicationBundleIDs: capturedAppBundleIDs,
      routes: routeTable.xpcRoutes().map {
        SessionRoute(sourceID: $0.sourceID, destinationID: $0.destinationID)
      },
      monitorDeviceUID: requestedMonitorDeviceUID,
      inputDeviceUID: requestedInputDeviceUID,
      echoRiskAcknowledgements: echoRiskAcknowledgements.sorted()
    )
  }

  private func scheduleSessionSaveLocked() {
    sessionWriter.schedule(sessionSnapshotLocked())
  }

  private func restoreSessionLocked() {
    do {
      guard let state = try sessionStore.read() else { return }
      let restoredBundleIDs = Self.sanitizedBundleIDs(state.selectedApplicationBundleIDs)
      let restoredAcknowledgements = Set(state.echoRiskAcknowledgements.filter {
        RoutingSafetyPolicy.isCommunicationApplication($0)
      })
      let restoredRoutes = state.routes.map {
        LKXPCRoute(sourceID: $0.sourceID, destinationID: $0.destinationID)
      }
      try RoutingSafetyPolicy.validateCapturedApplications(restoredBundleIDs)
      try RoutingSafetyPolicy.validateMonitorDevice(
        uid: state.monitorDeviceUID,
        broadcastDeviceUID: Self.kBlackHoleDeviceUID
      )
      try RoutingSafetyPolicy.validateRoutes(
        restoredRoutes,
        echoRiskAcknowledgements: restoredAcknowledgements
      )

      masterGain = ControlPolicy.gain(state.masterGain)
      requestedMonitorDeviceUID = state.monitorDeviceUID
      requestedInputDeviceUID = state.inputDeviceUID
      capturedAppBundleIDs = restoredBundleIDs
      sources = Dictionary(uniqueKeysWithValues: state.sources.map { stored in
        let source = LKXPCSourceState(
          id: stored.id,
          displayName: stored.displayName,
          gain: stored.gain,
          mute: stored.mute,
          solo: stored.solo,
          enabled: stored.enabled
        )
        return (stored.id, sanitizedSource(source))
      })
      processTapManager.setSelectedBundleIDs(capturedAppBundleIDs)
      ensureCaptureSourcesLocked()
      routeTable.restore(
        restoredRoutes,
        sourceIDs: Set(sources.keys.map { SourceID(rawValue: $0) })
      )
      echoRiskAcknowledgements = restoredAcknowledgements
    } catch {
      let originalError = error
      do {
        let quarantined = try sessionStore.quarantineCorruptFile()
        let suffix = quarantined.map { " Quarantined as \($0.lastPathComponent)." } ?? ""
        lastError = "LoopKit state was unreadable and defaults were restored.\(suffix) \(originalError.localizedDescription)"
      } catch {
        lastError = "LoopKit state was unreadable and could not be quarantined: \(error.localizedDescription)"
      }
    }
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
    routeTable.reconcile(
      sourceIDs: Set(sources.keys.map { SourceID(rawValue: $0) }),
      defaults: RoutingSafetyPolicy.defaultDestinations
    )
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
    routeTable.reconcile(
      sourceIDs: Set(sources.keys.map { SourceID(rawValue: $0) }),
      defaults: RoutingSafetyPolicy.defaultDestinations
    )
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
    guard engine != nil else {
      lastError = "Failed to initialize the LoopKit audio engine"
      return
    }
    syncEngineStateLocked()
    // Only eagerly activate the monitor when the user has picked a specific
    // device. For the default case we stay silent until there's audio worth
    // routing — no point holding the physical output open otherwise.
    if requestedMonitorDeviceUID != "system.default" {
      _ = applyMonitorDeviceLocked(preferredUID: requestedMonitorDeviceUID, allowFallback: true, reason: "startup")
    }
    applyBroadcastOutputLocked(force: true)
  }

  private func refreshMicrophonePermissionLocked() {
    switch micInputManager.permissionStatus() {
    case .granted:
      microphonePermission = LKPermissionStateGranted
    case .denied:
      microphonePermission = LKPermissionStateDenied
    case .notDetermined:
      microphonePermission = LKPermissionStateNotRequested
    @unknown default:
      microphonePermission = LKPermissionStateDenied
    }
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
        "BlackHole 2ch is not installed. Use the official BlackHole installer, then reconnect LoopKit."
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
    processingSchedule.reset()
    nextFrameIndex = 0
    let tickNanoseconds = max(
      1_000_000,
      Int((Double(kProcessingWakeFrames) / Double(sampleRate)) * 1_000_000_000.0)
    )
    timer.schedule(
      deadline: .now(),
      repeating: .nanoseconds(tickNanoseconds),
      leeway: .nanoseconds(max(50_000, tickNanoseconds / 20))
    )
    timer.setEventHandler { [weak self] in
      self?.processScheduledAudioLocked()
    }
    timer.resume()
    processingTimer = timer
  }

  private func processScheduledAudioLocked(nowNanos: UInt64 = DispatchTime.now().uptimeNanoseconds) {
    let decision = processingSchedule.advance(nowNanos: nowNanos)
    for _ in 0..<decision.blockCount {
      processAudioTickLocked()
    }
    schedulerDiscontinuities = processingSchedule.discontinuities
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
      self.captureMode = LKCaptureModeProcessTap
      if tapCount == 0 && !self.capturedAppBundleIDs.isEmpty && self.captureWarning == nil {
        self.captureWarning = "Selected application capture is unavailable; no fallback capture adapter is configured"
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
    let devices = AudioDevices.outputDevices().filter {
      $0.uid != Self.kBlackHoleDeviceUID && $0.uid != activeBroadcastDeviceUID
    }
    let systemDefaultUID = AudioDevices.defaultOutputUID()
    let safeDefaultUID = devices.contains(where: { $0.uid == systemDefaultUID })
      ? systemDefaultUID
      : devices.first?.uid
    let decision = MonitorOutputPolicy.activate(
      requestedUID: preferredUID,
      devices: devices.map { MonitorOutputDevice(uid: $0.uid, name: $0.name) },
      defaultUID: safeDefaultUID,
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

  private func processAudioTickLocked() {
    guard let engine else { return }

    // Reattempt BlackHole binding at a low rate if it isn't currently bound.
    if !broadcastOutputManager.isRunning() {
      _ = applyBroadcastOutputLocked(force: false)
    }

    ensureCaptureSourcesLocked()

    let frameCount: UInt32 = blockFrames
    let frameIndex: UInt64 = nextFrameIndex

    audioBlocks.prepare(frames: Int(frameCount))

    // Pull the mic lane from AVAudioEngine → AsyncResampler (48 kHz) →
    // engine. On underrun, the resampler zero-fills for us.
    _ = audioBlocks.captureMicrophone(from: micInputManager, frames: frameCount)

    let sourceIDs = visibleSourcesLocked().map(\.id)
    let soloEnabled = sourceIDs.compactMap { sources[$0] }.contains(where: { $0.enabled && !$0.mute && $0.solo })
    var meterMap: [String: LKXPCMeter] = [:]

    for bundleID in capturedAppBundleIDs {
      let sourceID = Self.sourceID(forBundleID: bundleID)
      guard let source = sources[sourceID] else { continue }

      let tapFrames = audioBlocks.captureApplication(
        bundleID: bundleID,
        from: processTapManager,
        frames: frameCount
      )
      let active = sourceIsActive(source, soloEnabled: soloEnabled)
      let meter = audioBlocks.applicationMeter(
        sourceID: sourceID,
        frames: Int(min(frameCount, tapFrames)),
        gain: Float(source.gain),
        active: active
      )
      meterMap[sourceID] = meter

      if active, tapFrames > 0 {
        let mixedFrames = Int(min(frameCount, tapFrames))
        audioBlocks.mixCapturedApplication(
          frames: mixedFrames,
          gain: Float(source.gain),
          broadcast: routeTable.contains(
            source: SourceID(rawValue: sourceID),
            destination: .broadcast
          ),
          monitor: routeTable.contains(
            source: SourceID(rawValue: sourceID),
            destination: .monitor
          )
        )
      }
    }

    var micActive = false
    if let mic = sources[Self.micSourceID] {
      micActive = sourceIsActive(mic, soloEnabled: soloEnabled)
      meterMap[Self.micSourceID] = audioBlocks.microphoneMeter(
        sourceID: Self.micSourceID,
        frames: Int(frameCount),
        gain: Float(mic.gain),
        active: micActive
      )
    }

    let micBroadcastFrames = micActive
      && routeTable.contains(source: .microphone, destination: .broadcast)
      ? frameCount : 0
    let micMonitorFrames = micActive
      && routeTable.contains(source: .microphone, destination: .monitor)
      ? frameCount : 0
    let mixMeters = audioBlocks.process(
      engine: engine,
      frames: frameCount,
      microphoneBroadcastFrames: micBroadcastFrames,
      microphoneMonitorFrames: micMonitorFrames
    )
    let broadcastMeter = mixMeters.broadcast
    let monitorMeter = mixMeters.monitor
    meterMap[LKMeterSourceBroadcastMix] = LKXPCMeter(
      sourceID: LKMeterSourceBroadcastMix,
      peakL: Double(broadcastMeter.peak_l),
      peakR: Double(broadcastMeter.peak_r),
      rmsL: Double(broadcastMeter.rms_l),
      rmsR: Double(broadcastMeter.rms_r),
      clippedL: broadcastMeter.clipped_l != 0,
      clippedR: broadcastMeter.clipped_r != 0
    )
    meterMap[LKMeterSourceMonitorMix] = LKXPCMeter(
      sourceID: LKMeterSourceMonitorMix,
      peakL: Double(monitorMeter.peak_l),
      peakR: Double(monitorMeter.peak_r),
      rmsL: Double(monitorMeter.rms_l),
      rmsR: Double(monitorMeter.rms_r),
      clippedL: monitorMeter.clipped_l != 0,
      clippedR: monitorMeter.clipped_r != 0
    )

    // The Broadcast stream is always-on: a downstream consumer such as
    // Discord expects continuous audio even during silence, unlike the
    // idle-stoppable Monitor path.
    if broadcastOutputManager.isRunning() {
      audioBlocks.enqueueBroadcast(to: broadcastOutputManager, frames: frameCount)
    }

    updateMonitorLifecycleLocked(mixMeter: monitorMeter)
    if monitorActive {
      audioBlocks.enqueueMonitor(to: monitorOutputManager, frames: frameCount)
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

}
