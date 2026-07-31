import Foundation
import LoopKitIPC

public final class LoopKitDaemonService: NSObject, LoopKitDaemonXPCProtocol {
  private let runtime: LoopKitDaemonRuntime

  public override init() {
    runtime = LoopKitDaemonRuntime()
    super.init()
  }

  public func start() { runtime.start() }

  public func handshake(_ reply: @escaping (LKXPCHandshake) -> Void) { runtime.handshake(reply) }
  public func setMasterGain(_ gain: Double, withReply reply: @escaping (LKXPCResult) -> Void) {
    runtime.setMasterGain(gain, withReply: reply)
  }
  public func setSourceParams(_ source: LKXPCSourceState, withReply reply: @escaping (LKXPCResult) -> Void) {
    runtime.setSourceParams(source, withReply: reply)
  }
  public func setMuteSolo(sourceID: String, mute: Bool, solo: Bool, enabled: Bool, withReply reply: @escaping (LKXPCResult) -> Void) {
    runtime.setMuteSolo(sourceID: sourceID, mute: mute, solo: solo, enabled: enabled, withReply: reply)
  }
  public func setMonitorDevice(uid: String, withReply reply: @escaping (LKXPCResult) -> Void) {
    runtime.setMonitorDevice(uid: uid, withReply: reply)
  }
  public func setInputDevice(uid: String, withReply reply: @escaping (LKXPCResult) -> Void) {
    runtime.setInputDevice(uid: uid, withReply: reply)
  }
  public func listDevices(_ reply: @escaping ([LKXPCDevice]) -> Void) { runtime.listDevices(reply) }
  public func listInputDevices(_ reply: @escaping ([LKXPCDevice]) -> Void) { runtime.listInputDevices(reply) }
  public func listCaptureApps(_ reply: @escaping ([LKXPCCaptureApp]) -> Void) { runtime.listCaptureApps(reply) }
  public func setCapturedApps(bundleIDs: [String], withReply reply: @escaping (LKXPCResult) -> Void) {
    runtime.setCapturedApps(bundleIDs: bundleIDs, withReply: reply)
  }
  public func listSources(_ reply: @escaping ([LKXPCSourceState]) -> Void) { runtime.listSources(reply) }
  public func listRoutes(_ reply: @escaping ([LKXPCRoute]) -> Void) { runtime.listRoutes(reply) }
  public func setRoutes(_ routes: [LKXPCRoute], withReply reply: @escaping (LKXPCResult) -> Void) {
    runtime.setRoutes(routes, withReply: reply)
  }
  public func refreshMicrophoneAuthorization(_ reply: @escaping (LKXPCResult) -> Void) {
    runtime.refreshMicrophoneAuthorization(reply)
  }
  public func approveEchoRisk(bundleID: String, approved: Bool, withReply reply: @escaping (LKXPCResult) -> Void) {
    runtime.approveEchoRisk(bundleID: bundleID, approved: approved, withReply: reply)
  }
  public func saveScene(_ scene: LKXPCScene, withReply reply: @escaping (LKXPCResult) -> Void) {
    runtime.saveScene(scene, withReply: reply)
  }
  public func loadScene(name: String, withReply reply: @escaping (LKXPCScene?, LKXPCResult) -> Void) {
    runtime.loadScene(name: name, withReply: reply)
  }
  public func listScenes(_ reply: @escaping ([String]) -> Void) { runtime.listScenes(reply) }
  public func getStatus(_ reply: @escaping (LKXPCStatus) -> Void) { runtime.getStatus(reply) }
  public func subscribeMeters(_ reply: @escaping ([LKXPCMeter]) -> Void) { runtime.subscribeMeters(reply) }
}
