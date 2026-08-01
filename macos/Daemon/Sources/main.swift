import Foundation
import LoopKitDaemonCore
import LoopKitIPC

final class LoopKitDaemonDelegate: NSObject, NSXPCListenerDelegate {
  private let service = LoopKitDaemonService()
  private let connectionCodeSigningRequirement: String?

  init(connectionCodeSigningRequirement: String?) {
    self.connectionCodeSigningRequirement = connectionCodeSigningRequirement
  }

  func start() {
    service.start()
  }

  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
    if let connectionCodeSigningRequirement {
      newConnection.setCodeSigningRequirement(connectionCodeSigningRequirement)
    }
    let interface = NSXPCInterface(with: LoopKitDaemonXPCProtocol.self)
    configureLoopKitXPCInterface(interface)
    newConnection.exportedInterface = interface
    newConnection.exportedObject = service
    newConnection.resume()
    return true
  }
}

// The same entry point is retained for one transition release: the executable
// under Contents/Resources is only used long enough for the ControlApp to
// unregister an existing SMAppService LaunchAgent, while the normal runtime is
// an app-owned service under Contents/XPCServices.
let listenerKind: LoopKitXPCListenerKind = Bundle.main.bundleURL.pathExtension == "xpc"
  ? .embeddedService
  : .machService
let listener = listenerKind == .embeddedService
  ? NSXPCListener.service()
  : NSXPCListener(machServiceName: LoopKitDaemonMachService)
#if DEBUG || LOOPKIT_COMMUNITY
let appRequirement = LoopKitCodeSigningRequirement.identifierOnly(
  identifier: LoopKitCodeSigningRequirement.appIdentifier
)
#else
let teamIdentifier = Bundle.main.object(forInfoDictionaryKey: "LoopKitTeamIdentifier") as? String
guard let appRequirement = LoopKitCodeSigningRequirement.release(
  identifier: LoopKitCodeSigningRequirement.appIdentifier,
  teamIdentifier: teamIdentifier
) else {
  fatalError("LoopKit agent is missing its release Team ID")
}
#endif
let authenticationPlacement = LoopKitXPCPeerAuthentication.placement(for: listenerKind)
let delegate = LoopKitDaemonDelegate(
  connectionCodeSigningRequirement: authenticationPlacement == .acceptedConnection
    ? appRequirement
    : nil
)
if authenticationPlacement == .listener {
  listener.setConnectionCodeSigningRequirement(appRequirement)
}
listener.delegate = delegate
listener.activate()
delegate.start()

RunLoop.main.run()
