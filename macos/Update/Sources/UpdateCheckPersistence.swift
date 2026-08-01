import Foundation

public protocol LoopKitUpdatePersisting: Sendable {
  func lastAutomaticAttempt() async -> Date?
  func setLastAutomaticAttempt(_ date: Date) async
  func cachedRelease() async -> GitHubRelease?
  func setCachedRelease(_ release: GitHubRelease) async
}

public actor UserDefaultsLoopKitUpdatePersistence: LoopKitUpdatePersisting {
  private let defaults: UserDefaults
  private let lastAttemptKey: String
  private let cachedReleaseKey: String

  public init(
    defaults: UserDefaults = .standard,
    keyPrefix: String = "LoopKitUpdate"
  ) {
    self.defaults = defaults
    lastAttemptKey = "\(keyPrefix).lastAutomaticAttempt"
    cachedReleaseKey = "\(keyPrefix).cachedRelease"
  }

  public func lastAutomaticAttempt() -> Date? {
    defaults.object(forKey: lastAttemptKey) as? Date
  }

  public func setLastAutomaticAttempt(_ date: Date) {
    defaults.set(date, forKey: lastAttemptKey)
  }

  public func cachedRelease() -> GitHubRelease? {
    guard let data = defaults.data(forKey: cachedReleaseKey) else { return nil }
    return try? JSONDecoder().decode(GitHubRelease.self, from: data)
  }

  public func setCachedRelease(_ release: GitHubRelease) {
    guard let data = try? JSONEncoder().encode(release) else { return }
    defaults.set(data, forKey: cachedReleaseKey)
  }
}
