import Foundation
import LoopKitIPC

enum LoopKitConnectionState: Equatable {
  case connected
  case connecting
  case disconnected(reason: String)
}

/// async-first wrapper over the XPC surface. Uses a private serial queue to
/// serialize connection setup and mutation; public APIs are async so callers
/// can `await` from @MainActor without manual dispatch.
actor LoopKitDaemonClient {
  private var connection: NSXPCConnection?
  private var lastDisconnectReason: String?

  /// Called on every connection state transition, on the actor's executor.
  /// The ViewModel hops to @MainActor to update its @Published state.
  private var stateObserver: ((LoopKitConnectionState) -> Void)?

  func setStateObserver(_ observer: @escaping (LoopKitConnectionState) -> Void) {
    self.stateObserver = observer
  }

  func reconnect() {
    notify(.connecting)
    connection?.invalidate()
    let conn = NSXPCConnection(machServiceName: LoopKitDaemonMachService, options: [])
    let interface = NSXPCInterface(with: LoopKitDaemonXPCProtocol.self)
    configureLoopKitXPCInterface(interface)
    conn.remoteObjectInterface = interface
    conn.invalidationHandler = { [weak self] in
      Task { await self?.handleInvalidation(reason: "loopkitd connection invalidated") }
    }
    conn.interruptionHandler = { [weak self] in
      Task { await self?.handleInvalidation(reason: "loopkitd connection interrupted") }
    }
    conn.resume()
    self.connection = conn
    self.lastDisconnectReason = nil
    // Optimistically notify connected; a failed first call will re-run the
    // invalidation handler and correct the state.
    notify(.connected)
  }

  private func handleInvalidation(reason: String) {
    lastDisconnectReason = reason
    connection = nil
    notify(.disconnected(reason: reason))
  }

  private func notify(_ state: LoopKitConnectionState) {
    stateObserver?(state)
  }

  // MARK: - Read operations

  func listDevices() async -> [LKXPCDevice] {
    await call(fallback: []) { proxy, cont in
      proxy.listDevices { devices in cont.resume(returning: devices) }
    }
  }

  func listInputDevices() async -> [LKXPCDevice] {
    await call(fallback: []) { proxy, cont in
      proxy.listInputDevices { devices in cont.resume(returning: devices) }
    }
  }

  func listCaptureApps() async -> [LKXPCCaptureApp] {
    await call(fallback: []) { proxy, cont in
      proxy.listCaptureApps { apps in cont.resume(returning: apps) }
    }
  }

  func listSources() async -> [LKXPCSourceState] {
    await call(fallback: []) { proxy, cont in
      proxy.listSources { sources in cont.resume(returning: sources) }
    }
  }

  func listRoutes() async -> [LKXPCRoute] {
    await call(fallback: []) { proxy, cont in
      proxy.listRoutes { routes in cont.resume(returning: routes) }
    }
  }

  func listScenes() async -> [String] {
    await call(fallback: []) { proxy, cont in
      proxy.listScenes { names in cont.resume(returning: names) }
    }
  }

  func getStatus() async -> LKXPCStatus? {
    await call(fallback: nil) { proxy, cont in
      proxy.getStatus { status in cont.resume(returning: status) }
    }
  }

  func subscribeMeters() async -> [LKXPCMeter] {
    await call(fallback: []) { proxy, cont in
      proxy.subscribeMeters { meters in cont.resume(returning: meters) }
    }
  }

  // MARK: - Write operations

  @discardableResult
  func setMasterGain(_ gain: Double) async -> LKXPCResult {
    await call(fallback: LKXPCResult(success: false, message: "Daemon unavailable")) { proxy, cont in
      proxy.setMasterGain(gain) { result in cont.resume(returning: result) }
    }
  }

  @discardableResult
  func setSource(_ source: LKXPCSourceState) async -> LKXPCResult {
    await call(fallback: LKXPCResult(success: false, message: "Daemon unavailable")) { proxy, cont in
      proxy.setSourceParams(source) { result in cont.resume(returning: result) }
    }
  }

  @discardableResult
  func setSourceToggles(_ sourceID: String, mute: Bool, solo: Bool, enabled: Bool) async -> LKXPCResult {
    await call(fallback: LKXPCResult(success: false, message: "Daemon unavailable")) { proxy, cont in
      proxy.setMuteSolo(sourceID: sourceID, mute: mute, solo: solo, enabled: enabled) { result in
        cont.resume(returning: result)
      }
    }
  }

  @discardableResult
  func setMonitorDevice(uid: String) async -> LKXPCResult {
    await call(fallback: LKXPCResult(success: false, message: "Daemon unavailable")) { proxy, cont in
      proxy.setMonitorDevice(uid: uid) { result in cont.resume(returning: result) }
    }
  }

  @discardableResult
  func setInputDevice(uid: String) async -> LKXPCResult {
    await call(fallback: LKXPCResult(success: false, message: "Daemon unavailable")) { proxy, cont in
      proxy.setInputDevice(uid: uid) { result in cont.resume(returning: result) }
    }
  }

  @discardableResult
  func setCapturedApps(bundleIDs: [String]) async -> LKXPCResult {
    await call(fallback: LKXPCResult(success: false, message: "Daemon unavailable")) { proxy, cont in
      proxy.setCapturedApps(bundleIDs: bundleIDs) { result in cont.resume(returning: result) }
    }
  }

  @discardableResult
  func setRoutes(_ routes: [LKXPCRoute]) async -> LKXPCResult {
    await call(fallback: LKXPCResult(success: false, message: "Daemon unavailable")) { proxy, cont in
      proxy.setRoutes(routes) { result in cont.resume(returning: result) }
    }
  }

  @discardableResult
  func saveScene(_ scene: LKXPCScene) async -> LKXPCResult {
    await call(fallback: LKXPCResult(success: false, message: "Daemon unavailable")) { proxy, cont in
      proxy.saveScene(scene) { result in cont.resume(returning: result) }
    }
  }

  func loadScene(name: String) async -> (LKXPCScene?, LKXPCResult) {
    await call(fallback: (nil, LKXPCResult(success: false, message: "Daemon unavailable"))) { proxy, cont in
      proxy.loadScene(name: name) { scene, result in cont.resume(returning: (scene, result)) }
    }
  }

  // MARK: - Private plumbing

  private func proxyIfAvailable(onError: @escaping (Error) -> Void) -> LoopKitDaemonXPCProtocol? {
    if connection == nil {
      reconnect()
    }
    guard let connection else { return nil }
    return connection.remoteObjectProxyWithErrorHandler(onError) as? LoopKitDaemonXPCProtocol
  }

  private func call<T: Sendable>(
    fallback: T,
    invoke: @escaping (LoopKitDaemonXPCProtocol, CheckedContinuation<T, Never>) -> Void
  ) async -> T {
    await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
      let onError: (Error) -> Void = { [weak self] error in
        Task { await self?.handleInvalidation(reason: error.localizedDescription) }
        cont.resume(returning: fallback)
      }
      guard let proxy = proxyIfAvailable(onError: onError) else {
        cont.resume(returning: fallback)
        return
      }
      invoke(proxy, cont)
    }
  }
}
