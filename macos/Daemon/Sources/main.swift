import Foundation
import LoopKitDaemonCore
import LoopKitIPC

final class LoopKitDaemonDelegate: NSObject, NSXPCListenerDelegate {
  private let service = LoopKitDaemonService()

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
listener.delegate = delegate
listener.resume()

RunLoop.main.run()
