import Foundation

public let LoopKitDaemonMachService = "com.example.LoopKit.loopkitd"
public let LKCaptureModeProcessTap = "processTap"
public let LKCaptureModeUnavailable = "unavailable"
public let LKRouteDestinationMonitor = "monitor"
public let LKRouteDestinationBroadcast = "broadcast"
public let LKMeterSourceBroadcastMix = "mix:broadcast"
public let LKMeterSourceMonitorMix = "mix:monitor"

@objc(LKXPCResult)
@objcMembers
public final class LKXPCResult: NSObject, NSSecureCoding {
  public static var supportsSecureCoding: Bool = true

  public let success: Bool
  public let message: String?

  public init(success: Bool, message: String? = nil) {
    self.success = success
    self.message = message
  }

  public required init?(coder: NSCoder) {
    success = coder.decodeBool(forKey: "success")
    message = coder.decodeObject(of: NSString.self, forKey: "message") as String?
  }

  public func encode(with coder: NSCoder) {
    coder.encode(success, forKey: "success")
    coder.encode(message, forKey: "message")
  }
}

@objc(LKXPCDevice)
@objcMembers
public final class LKXPCDevice: NSObject, NSSecureCoding {
  public static var supportsSecureCoding: Bool = true

  public let uid: String
  public let name: String
  public let isDefault: Bool

  public init(uid: String, name: String, isDefault: Bool) {
    self.uid = uid
    self.name = name
    self.isDefault = isDefault
  }

  public required init?(coder: NSCoder) {
    guard
      let uid = coder.decodeObject(of: NSString.self, forKey: "uid") as String?,
      let name = coder.decodeObject(of: NSString.self, forKey: "name") as String?
    else {
      return nil
    }
    self.uid = uid
    self.name = name
    isDefault = coder.decodeBool(forKey: "isDefault")
  }

  public func encode(with coder: NSCoder) {
    coder.encode(uid, forKey: "uid")
    coder.encode(name, forKey: "name")
    coder.encode(isDefault, forKey: "isDefault")
  }
}

@objc(LKXPCSourceState)
@objcMembers
public final class LKXPCSourceState: NSObject, NSSecureCoding {
  public static var supportsSecureCoding: Bool = true

  public let id: String
  public let displayName: String
  public var gain: Double
  public var mute: Bool
  public var solo: Bool
  public var enabled: Bool

  public init(id: String, displayName: String, gain: Double, mute: Bool, solo: Bool, enabled: Bool) {
    self.id = id
    self.displayName = displayName
    self.gain = gain
    self.mute = mute
    self.solo = solo
    self.enabled = enabled
  }

  public required init?(coder: NSCoder) {
    guard
      let id = coder.decodeObject(of: NSString.self, forKey: "id") as String?,
      let displayName = coder.decodeObject(of: NSString.self, forKey: "displayName") as String?
    else {
      return nil
    }
    self.id = id
    self.displayName = displayName
    gain = coder.decodeDouble(forKey: "gain")
    mute = coder.decodeBool(forKey: "mute")
    solo = coder.decodeBool(forKey: "solo")
    enabled = coder.decodeBool(forKey: "enabled")
  }

  public func encode(with coder: NSCoder) {
    coder.encode(id, forKey: "id")
    coder.encode(displayName, forKey: "displayName")
    coder.encode(gain, forKey: "gain")
    coder.encode(mute, forKey: "mute")
    coder.encode(solo, forKey: "solo")
    coder.encode(enabled, forKey: "enabled")
  }
}

@objc(LKXPCRoute)
@objcMembers
public final class LKXPCRoute: NSObject, NSSecureCoding {
  public static var supportsSecureCoding: Bool = true

  public let sourceID: String
  public let destinationID: String

  public init(sourceID: String, destinationID: String) {
    self.sourceID = sourceID
    self.destinationID = destinationID
  }

  public required init?(coder: NSCoder) {
    guard
      let sourceID = coder.decodeObject(of: NSString.self, forKey: "sourceID") as String?,
      let destinationID = coder.decodeObject(of: NSString.self, forKey: "destinationID") as String?
    else {
      return nil
    }
    self.sourceID = sourceID
    self.destinationID = destinationID
  }

  public func encode(with coder: NSCoder) {
    coder.encode(sourceID, forKey: "sourceID")
    coder.encode(destinationID, forKey: "destinationID")
  }
}

@objc(LKXPCMeter)
@objcMembers
public final class LKXPCMeter: NSObject, NSSecureCoding {
  public static var supportsSecureCoding: Bool = true

  public let sourceID: String
  public let peakL: Double
  public let peakR: Double
  public let rmsL: Double
  public let rmsR: Double
  public let clippedL: Bool
  public let clippedR: Bool

  public init(
    sourceID: String,
    peakL: Double,
    peakR: Double,
    rmsL: Double,
    rmsR: Double,
    clippedL: Bool = false,
    clippedR: Bool = false
  ) {
    self.sourceID = sourceID
    self.peakL = peakL
    self.peakR = peakR
    self.rmsL = rmsL
    self.rmsR = rmsR
    self.clippedL = clippedL
    self.clippedR = clippedR
  }

  public required init?(coder: NSCoder) {
    guard let sourceID = coder.decodeObject(of: NSString.self, forKey: "sourceID") as String? else {
      return nil
    }
    self.sourceID = sourceID
    peakL = coder.decodeDouble(forKey: "peakL")
    peakR = coder.decodeDouble(forKey: "peakR")
    rmsL = coder.decodeDouble(forKey: "rmsL")
    rmsR = coder.decodeDouble(forKey: "rmsR")
    clippedL = coder.decodeBool(forKey: "clippedL")
    clippedR = coder.decodeBool(forKey: "clippedR")
  }

  public func encode(with coder: NSCoder) {
    coder.encode(sourceID, forKey: "sourceID")
    coder.encode(peakL, forKey: "peakL")
    coder.encode(peakR, forKey: "peakR")
    coder.encode(rmsL, forKey: "rmsL")
    coder.encode(rmsR, forKey: "rmsR")
    coder.encode(clippedL, forKey: "clippedL")
    coder.encode(clippedR, forKey: "clippedR")
  }
}

@objc(LKXPCStatus)
@objcMembers
public final class LKXPCStatus: NSObject, NSSecureCoding {
  public static var supportsSecureCoding: Bool = true

  public let daemonOnline: Bool
  public let sampleRate: Int
  public let blockFrames: Int
  public let tapOverruns: UInt64
  public let tapUnderruns: UInt64
  public let monitorOverruns: UInt64
  public let monitorUnderruns: UInt64
  public let broadcastOverruns: UInt64
  public let broadcastUnderruns: UInt64
  public let tapSampleRate: Int
  public let errorMessage: String?
  public let captureMode: String
  public let activeTapCount: Int
  public let captureWarning: String?
  public let requestedMonitorDeviceUID: String
  public let activeMonitorDeviceUID: String
  public let monitorFallbackActive: Bool
  public let monitorWarning: String?
  public let monitorDeviceSampleRate: Int
  public let micInputDeviceSampleRate: Int
  public let requestedInputDeviceUID: String
  public let activeInputDeviceUID: String
  public let inputWarning: String?
  public let broadcastOutputConnected: Bool
  public let activeBroadcastDeviceUID: String
  public let broadcastOutputSampleRate: Int
  public let broadcastOutputWarning: String?

  public init(
    daemonOnline: Bool,
    sampleRate: Int,
    blockFrames: Int,
    tapOverruns: UInt64 = 0,
    tapUnderruns: UInt64 = 0,
    monitorOverruns: UInt64 = 0,
    monitorUnderruns: UInt64 = 0,
    broadcastOverruns: UInt64 = 0,
    broadcastUnderruns: UInt64 = 0,
    tapSampleRate: Int = 0,
    errorMessage: String? = nil,
    captureMode: String = LKCaptureModeUnavailable,
    activeTapCount: Int = 0,
    captureWarning: String? = nil,
    requestedMonitorDeviceUID: String = "system.default",
    activeMonitorDeviceUID: String = "system.default",
    monitorFallbackActive: Bool = false,
    monitorWarning: String? = nil,
    monitorDeviceSampleRate: Int = 0,
    micInputDeviceSampleRate: Int = 0,
    requestedInputDeviceUID: String = "system.default",
    activeInputDeviceUID: String = "system.default",
    inputWarning: String? = nil,
    broadcastOutputConnected: Bool = false,
    activeBroadcastDeviceUID: String = "",
    broadcastOutputSampleRate: Int = 0,
    broadcastOutputWarning: String? = nil
  ) {
    self.daemonOnline = daemonOnline
    self.sampleRate = sampleRate
    self.blockFrames = blockFrames
    self.tapOverruns = tapOverruns
    self.tapUnderruns = tapUnderruns
    self.monitorOverruns = monitorOverruns
    self.monitorUnderruns = monitorUnderruns
    self.broadcastOverruns = broadcastOverruns
    self.broadcastUnderruns = broadcastUnderruns
    self.tapSampleRate = tapSampleRate
    self.errorMessage = errorMessage
    self.captureMode = captureMode
    self.activeTapCount = activeTapCount
    self.captureWarning = captureWarning
    self.requestedMonitorDeviceUID = requestedMonitorDeviceUID
    self.activeMonitorDeviceUID = activeMonitorDeviceUID
    self.monitorFallbackActive = monitorFallbackActive
    self.monitorWarning = monitorWarning
    self.monitorDeviceSampleRate = monitorDeviceSampleRate
    self.micInputDeviceSampleRate = micInputDeviceSampleRate
    self.requestedInputDeviceUID = requestedInputDeviceUID
    self.activeInputDeviceUID = activeInputDeviceUID
    self.inputWarning = inputWarning
    self.broadcastOutputConnected = broadcastOutputConnected
    self.activeBroadcastDeviceUID = activeBroadcastDeviceUID
    self.broadcastOutputSampleRate = broadcastOutputSampleRate
    self.broadcastOutputWarning = broadcastOutputWarning
  }

  public required init?(coder: NSCoder) {
    daemonOnline = coder.decodeBool(forKey: "daemonOnline")
    sampleRate = coder.decodeInteger(forKey: "sampleRate")
    blockFrames = coder.decodeInteger(forKey: "blockFrames")
    tapOverruns = UInt64(coder.decodeInt64(forKey: "tapOverruns"))
    tapUnderruns = UInt64(coder.decodeInt64(forKey: "tapUnderruns"))
    monitorOverruns = UInt64(coder.decodeInt64(forKey: "monitorOverruns"))
    monitorUnderruns = UInt64(coder.decodeInt64(forKey: "monitorUnderruns"))
    // Preserve the original wire keys so a rolling daemon/app restart remains compatible.
    broadcastOverruns = UInt64(coder.decodeInt64(forKey: "discordOverruns"))
    broadcastUnderruns = UInt64(coder.decodeInt64(forKey: "discordUnderruns"))
    tapSampleRate = coder.decodeInteger(forKey: "tapSampleRate")
    errorMessage = coder.decodeObject(of: NSString.self, forKey: "errorMessage") as String?
    captureMode = (coder.decodeObject(of: NSString.self, forKey: "captureMode") as String?) ?? LKCaptureModeUnavailable
    activeTapCount = coder.decodeInteger(forKey: "activeTapCount")
    captureWarning = coder.decodeObject(of: NSString.self, forKey: "captureWarning") as String?
    requestedMonitorDeviceUID = (coder.decodeObject(of: NSString.self, forKey: "requestedMonitorDeviceUID") as String?) ?? "system.default"
    activeMonitorDeviceUID = (coder.decodeObject(of: NSString.self, forKey: "activeMonitorDeviceUID") as String?) ?? "system.default"
    monitorFallbackActive = coder.decodeBool(forKey: "monitorFallbackActive")
    monitorWarning = coder.decodeObject(of: NSString.self, forKey: "monitorWarning") as String?
    monitorDeviceSampleRate = coder.decodeInteger(forKey: "monitorDeviceSampleRate")
    micInputDeviceSampleRate = coder.decodeInteger(forKey: "micInputDeviceSampleRate")
    requestedInputDeviceUID = (coder.decodeObject(of: NSString.self, forKey: "requestedInputDeviceUID") as String?) ?? "system.default"
    activeInputDeviceUID = (coder.decodeObject(of: NSString.self, forKey: "activeInputDeviceUID") as String?) ?? "system.default"
    inputWarning = coder.decodeObject(of: NSString.self, forKey: "inputWarning") as String?
    broadcastOutputConnected = coder.decodeBool(forKey: "discordOutputConnected")
    activeBroadcastDeviceUID = (coder.decodeObject(of: NSString.self, forKey: "activeDiscordDeviceUID") as String?) ?? ""
    broadcastOutputSampleRate = coder.decodeInteger(forKey: "discordOutputSampleRate")
    broadcastOutputWarning = coder.decodeObject(of: NSString.self, forKey: "discordOutputWarning") as String?
  }

  public func encode(with coder: NSCoder) {
    coder.encode(daemonOnline, forKey: "daemonOnline")
    coder.encode(sampleRate, forKey: "sampleRate")
    coder.encode(blockFrames, forKey: "blockFrames")
    coder.encode(Int64(tapOverruns), forKey: "tapOverruns")
    coder.encode(Int64(tapUnderruns), forKey: "tapUnderruns")
    coder.encode(Int64(monitorOverruns), forKey: "monitorOverruns")
    coder.encode(Int64(monitorUnderruns), forKey: "monitorUnderruns")
    coder.encode(Int64(broadcastOverruns), forKey: "discordOverruns")
    coder.encode(Int64(broadcastUnderruns), forKey: "discordUnderruns")
    coder.encode(tapSampleRate, forKey: "tapSampleRate")
    coder.encode(errorMessage, forKey: "errorMessage")
    coder.encode(captureMode, forKey: "captureMode")
    coder.encode(activeTapCount, forKey: "activeTapCount")
    coder.encode(captureWarning, forKey: "captureWarning")
    coder.encode(requestedMonitorDeviceUID, forKey: "requestedMonitorDeviceUID")
    coder.encode(activeMonitorDeviceUID, forKey: "activeMonitorDeviceUID")
    coder.encode(monitorFallbackActive, forKey: "monitorFallbackActive")
    coder.encode(monitorWarning, forKey: "monitorWarning")
    coder.encode(monitorDeviceSampleRate, forKey: "monitorDeviceSampleRate")
    coder.encode(micInputDeviceSampleRate, forKey: "micInputDeviceSampleRate")
    coder.encode(requestedInputDeviceUID, forKey: "requestedInputDeviceUID")
    coder.encode(activeInputDeviceUID, forKey: "activeInputDeviceUID")
    coder.encode(inputWarning, forKey: "inputWarning")
    coder.encode(broadcastOutputConnected, forKey: "discordOutputConnected")
    coder.encode(activeBroadcastDeviceUID, forKey: "activeDiscordDeviceUID")
    coder.encode(broadcastOutputSampleRate, forKey: "discordOutputSampleRate")
    coder.encode(broadcastOutputWarning, forKey: "discordOutputWarning")
  }
}

@objc(LKXPCCaptureApp)
@objcMembers
public final class LKXPCCaptureApp: NSObject, NSSecureCoding {
  public static var supportsSecureCoding: Bool = true

  public let bundleID: String
  public let displayName: String
  public let pid: Int
  public let running: Bool
  public let selected: Bool
  public let sourceID: String

  public init(
    bundleID: String,
    displayName: String,
    pid: Int,
    running: Bool,
    selected: Bool,
    sourceID: String
  ) {
    self.bundleID = bundleID
    self.displayName = displayName
    self.pid = pid
    self.running = running
    self.selected = selected
    self.sourceID = sourceID
  }

  public required init?(coder: NSCoder) {
    guard
      let bundleID = coder.decodeObject(of: NSString.self, forKey: "bundleID") as String?,
      let displayName = coder.decodeObject(of: NSString.self, forKey: "displayName") as String?,
      let sourceID = coder.decodeObject(of: NSString.self, forKey: "sourceID") as String?
    else {
      return nil
    }
    self.bundleID = bundleID
    self.displayName = displayName
    pid = coder.decodeInteger(forKey: "pid")
    running = coder.decodeBool(forKey: "running")
    selected = coder.decodeBool(forKey: "selected")
    self.sourceID = sourceID
  }

  public func encode(with coder: NSCoder) {
    coder.encode(bundleID, forKey: "bundleID")
    coder.encode(displayName, forKey: "displayName")
    coder.encode(pid, forKey: "pid")
    coder.encode(running, forKey: "running")
    coder.encode(selected, forKey: "selected")
    coder.encode(sourceID, forKey: "sourceID")
  }
}

@objc(LKXPCScene)
@objcMembers
public final class LKXPCScene: NSObject, NSSecureCoding {
  public static var supportsSecureCoding: Bool = true

  public let name: String
  public let masterGain: Double
  public let monitorDeviceUID: String
  public let sources: [LKXPCSourceState]
  public let routes: [LKXPCRoute]?

  public init(
    name: String,
    masterGain: Double,
    monitorDeviceUID: String,
    sources: [LKXPCSourceState],
    routes: [LKXPCRoute]? = nil
  ) {
    self.name = name
    self.masterGain = masterGain
    self.monitorDeviceUID = monitorDeviceUID
    self.sources = sources
    self.routes = routes
  }

  public required init?(coder: NSCoder) {
    guard
      let name = coder.decodeObject(of: NSString.self, forKey: "name") as String?,
      let monitorDeviceUID = coder.decodeObject(of: NSString.self, forKey: "monitorDeviceUID") as String?
    else {
      return nil
    }
    self.name = name
    masterGain = coder.decodeDouble(forKey: "masterGain")
    self.monitorDeviceUID = monitorDeviceUID
    let classes: [AnyClass] = [NSArray.self, LKXPCSourceState.self]
    sources = coder.decodeObject(of: classes, forKey: "sources") as? [LKXPCSourceState] ?? []
    let routeClasses: [AnyClass] = [NSArray.self, LKXPCRoute.self]
    routes = coder.containsValue(forKey: "routes")
      ? coder.decodeObject(of: routeClasses, forKey: "routes") as? [LKXPCRoute]
      : nil
  }

  public func encode(with coder: NSCoder) {
    coder.encode(name, forKey: "name")
    coder.encode(masterGain, forKey: "masterGain")
    coder.encode(monitorDeviceUID, forKey: "monitorDeviceUID")
    coder.encode(sources, forKey: "sources")
    coder.encode(routes, forKey: "routes")
  }
}

@objc public protocol LoopKitDaemonXPCProtocol {
  func setMasterGain(_ gain: Double, withReply reply: @escaping (LKXPCResult) -> Void)
  func setSourceParams(_ source: LKXPCSourceState, withReply reply: @escaping (LKXPCResult) -> Void)
  func setMuteSolo(sourceID: String, mute: Bool, solo: Bool, enabled: Bool, withReply reply: @escaping (LKXPCResult) -> Void)
  func setMonitorDevice(uid: String, withReply reply: @escaping (LKXPCResult) -> Void)
  func setInputDevice(uid: String, withReply reply: @escaping (LKXPCResult) -> Void)
  func listDevices(_ reply: @escaping ([LKXPCDevice]) -> Void)
  func listInputDevices(_ reply: @escaping ([LKXPCDevice]) -> Void)
  func listCaptureApps(_ reply: @escaping ([LKXPCCaptureApp]) -> Void)
  func setCapturedApps(bundleIDs: [String], withReply reply: @escaping (LKXPCResult) -> Void)
  func listSources(_ reply: @escaping ([LKXPCSourceState]) -> Void)
  func listRoutes(_ reply: @escaping ([LKXPCRoute]) -> Void)
  func setRoutes(_ routes: [LKXPCRoute], withReply reply: @escaping (LKXPCResult) -> Void)
  func saveScene(_ scene: LKXPCScene, withReply reply: @escaping (LKXPCResult) -> Void)
  func loadScene(name: String, withReply reply: @escaping (LKXPCScene?, LKXPCResult) -> Void)
  func listScenes(_ reply: @escaping ([String]) -> Void)
  func getStatus(_ reply: @escaping (LKXPCStatus) -> Void)
  func subscribeMeters(_ reply: @escaping ([LKXPCMeter]) -> Void)
}

public func configureLoopKitXPCInterface(_ interface: NSXPCInterface) {
  func classSet(_ classes: [AnyClass]) -> Set<AnyHashable> {
    (NSSet(array: classes) as? Set<AnyHashable>) ?? []
  }

  interface.setClasses(
    classSet([LKXPCSourceState.self]),
    for: #selector(LoopKitDaemonXPCProtocol.setSourceParams(_:withReply:)),
    argumentIndex: 0,
    ofReply: false
  )
  interface.setClasses(
    classSet([LKXPCScene.self, NSArray.self, LKXPCSourceState.self, LKXPCRoute.self]),
    for: #selector(LoopKitDaemonXPCProtocol.saveScene(_:withReply:)),
    argumentIndex: 0,
    ofReply: false
  )
  interface.setClasses(
    classSet([NSArray.self, LKXPCDevice.self]),
    for: #selector(LoopKitDaemonXPCProtocol.listDevices(_:)),
    argumentIndex: 0,
    ofReply: true
  )
  interface.setClasses(
    classSet([NSArray.self, LKXPCDevice.self]),
    for: #selector(LoopKitDaemonXPCProtocol.listInputDevices(_:)),
    argumentIndex: 0,
    ofReply: true
  )
  interface.setClasses(
    classSet([NSArray.self, LKXPCCaptureApp.self]),
    for: #selector(LoopKitDaemonXPCProtocol.listCaptureApps(_:)),
    argumentIndex: 0,
    ofReply: true
  )
  interface.setClasses(
    classSet([NSArray.self, LKXPCSourceState.self]),
    for: #selector(LoopKitDaemonXPCProtocol.listSources(_:)),
    argumentIndex: 0,
    ofReply: true
  )
  interface.setClasses(
    classSet([NSArray.self, LKXPCRoute.self]),
    for: #selector(LoopKitDaemonXPCProtocol.listRoutes(_:)),
    argumentIndex: 0,
    ofReply: true
  )
  interface.setClasses(
    classSet([NSArray.self, LKXPCRoute.self]),
    for: #selector(LoopKitDaemonXPCProtocol.setRoutes(_:withReply:)),
    argumentIndex: 0,
    ofReply: false
  )
  interface.setClasses(
    classSet([NSArray.self, NSString.self]),
    for: #selector(LoopKitDaemonXPCProtocol.setCapturedApps(bundleIDs:withReply:)),
    argumentIndex: 0,
    ofReply: false
  )
  interface.setClasses(
    classSet([LKXPCScene.self, NSArray.self, LKXPCSourceState.self, LKXPCRoute.self]),
    for: #selector(LoopKitDaemonXPCProtocol.loadScene(name:withReply:)),
    argumentIndex: 0,
    ofReply: true
  )
  interface.setClasses(
    classSet([LKXPCResult.self]),
    for: #selector(LoopKitDaemonXPCProtocol.loadScene(name:withReply:)),
    argumentIndex: 1,
    ofReply: true
  )
  interface.setClasses(
    classSet([NSArray.self, NSString.self]),
    for: #selector(LoopKitDaemonXPCProtocol.listScenes(_:)),
    argumentIndex: 0,
    ofReply: true
  )
  interface.setClasses(
    classSet([LKXPCStatus.self]),
    for: #selector(LoopKitDaemonXPCProtocol.getStatus(_:)),
    argumentIndex: 0,
    ofReply: true
  )
  interface.setClasses(
    classSet([NSArray.self, LKXPCMeter.self]),
    for: #selector(LoopKitDaemonXPCProtocol.subscribeMeters(_:)),
    argumentIndex: 0,
    ofReply: true
  )
}
