import Foundation
import ServiceManagement

@MainActor
final class LoopKitHelperManager: ObservableObject {
  enum Status: Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unavailable(String)
  }

  static let launchAgentPlistName = "com.twoplustwoone.LoopKit.agent.plist"
  static let legacyLaunchAgentName = "com.example.LoopKit.loopkitd.plist"

  @Published private(set) var status: Status = .notRegistered
  @Published private(set) var lastError: String?

  private let service: SMAppService
  private let fileManager: FileManager

  init(
    service: SMAppService = .agent(plistName: "com.twoplustwoone.LoopKit.agent.plist"),
    fileManager: FileManager = .default
  ) {
    self.service = service
    self.fileManager = fileManager
    refresh()
  }

  var hasLegacyInstallation: Bool {
    fileManager.fileExists(atPath: legacyLaunchAgentURL.path)
      || fileManager.fileExists(atPath: legacyDaemonURL.path)
  }

  func refresh() {
    switch service.status {
    case .notRegistered: status = .notRegistered
    case .enabled: status = .enabled
    case .requiresApproval: status = .requiresApproval
    case .notFound: status = .notFound
    @unknown default: status = .unavailable("Unknown helper registration state")
    }
  }

  @discardableResult
  func register() -> Bool {
    do {
      try service.register()
      lastError = nil
      refresh()
      return status == .enabled || status == .requiresApproval
    } catch {
      lastError = error.localizedDescription
      refresh()
      return false
    }
  }

  @discardableResult
  func unregister() -> Bool {
    do {
      try service.unregister()
      lastError = nil
      refresh()
      return true
    } catch {
      lastError = error.localizedDescription
      refresh()
      return false
    }
  }

  @discardableResult
  func repair() -> Bool {
    if service.status != .notRegistered {
      do { try service.unregister() } catch { lastError = error.localizedDescription }
    }
    return register()
  }

  func openLoginItemsSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }

  @discardableResult
  func removeLegacyInstallation() -> Bool {
    let bootout = Process()
    bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    bootout.arguments = [
      "bootout",
      "gui/\(getuid())",
      legacyLaunchAgentURL.path,
    ]
    try? bootout.run()
    bootout.waitUntilExit()
    try? fileManager.removeItem(at: legacyLaunchAgentURL)
    try? fileManager.removeItem(at: legacyDaemonURL)
    lastError = hasLegacyInstallation ? "The legacy developer helper could not be fully removed." : nil
    return !hasLegacyInstallation
  }

  private var legacyLaunchAgentURL: URL {
    fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/LaunchAgents")
      .appendingPathComponent(Self.legacyLaunchAgentName)
  }

  private var legacyDaemonURL: URL {
    fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/LoopKit/bin/loopkitd")
  }
}
