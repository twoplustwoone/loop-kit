import Foundation
import LoopKitDaemonCore
import LoopKitIPC

final class LoopKitDaemonDelegate: NSObject, NSXPCListenerDelegate {
  private let service = LoopKitDaemonService()

  func start() {
    service.start()
  }

  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
    let interface = NSXPCInterface(with: LoopKitDaemonXPCProtocol.self)
    configureLoopKitXPCInterface(interface)
    newConnection.exportedInterface = interface
    newConnection.exportedObject = service
    newConnection.resume()
    return true
  }
}

let delegate = LoopKitDaemonDelegate()
let listener = NSXPCListener(machServiceName: LoopKitDaemonMachService)
#if DEBUG || LOOPKIT_COMMUNITY
listener.setConnectionCodeSigningRequirement(
  LoopKitCodeSigningRequirement.identifierOnly(identifier: LoopKitCodeSigningRequirement.appIdentifier)
)
#else
let teamIdentifier = Bundle.main.object(forInfoDictionaryKey: "LoopKitTeamIdentifier") as? String
guard let appRequirement = LoopKitCodeSigningRequirement.release(
  identifier: LoopKitCodeSigningRequirement.appIdentifier,
  teamIdentifier: teamIdentifier
) else {
  fatalError("LoopKit agent is missing its release Team ID")
}
listener.setConnectionCodeSigningRequirement(appRequirement)
#endif
listener.delegate = delegate
listener.resume()
delegate.start()

RunLoop.main.run()
