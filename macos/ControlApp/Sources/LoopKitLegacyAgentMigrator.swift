import Foundation
import ServiceManagement

@MainActor
final class LoopKitLegacyAgentMigrator {
  static let completionKey = "LoopKitLegacyAgentMigrationV1Complete"
  static let plistName = "com.twoplustwoone.LoopKit.agent.plist"

  enum MigrationError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
      switch self {
      case .unavailable(let message):
        return "The previous LoopKit background helper could not be removed: \(message)"
      }
    }
  }

  private let service: SMAppService
  private let defaults: UserDefaults

  init(
    service: SMAppService? = nil,
    defaults: UserDefaults = .standard
  ) {
    self.service = service ?? .agent(plistName: Self.plistName)
    self.defaults = defaults
  }

  func migrateIfNeeded() async throws {
    guard !defaults.bool(forKey: Self.completionKey) else { return }

    switch service.status {
    case .enabled, .requiresApproval:
      try await unregister()
    case .notRegistered, .notFound:
      break
    @unknown default:
      throw MigrationError.unavailable("macOS returned an unknown service state")
    }

    defaults.set(true, forKey: Self.completionKey)
  }

  func retry() async throws {
    defaults.removeObject(forKey: Self.completionKey)
    try await migrateIfNeeded()
  }

  func openLoginItemsSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }

  private func unregister() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      service.unregister { error in
        if let error {
          continuation.resume(throwing: MigrationError.unavailable(error.localizedDescription))
        } else {
          continuation.resume(returning: ())
        }
      }
    }
  }
}
