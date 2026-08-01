import Foundation

public protocol LoopKitReleaseFetching: Sendable {
  func latestRelease() async throws -> GitHubRelease
}

public enum LoopKitUpdateCheckError: Error, Equatable, Sendable {
  case invalidInstalledVersion(String)
  case ineligibleRelease
  case invalidResponse
  case httpStatus(Int)
  case requestFailed(String)
}

extension LoopKitUpdateCheckError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidInstalledVersion:
      return "LoopKit could not compare the installed app version."
    case .ineligibleRelease:
      return "GitHub returned release information LoopKit could not verify."
    case .invalidResponse:
      return "GitHub returned an invalid update response."
    case .httpStatus(let status):
      return "GitHub could not complete the update check (HTTP \(status))."
    case .requestFailed:
      return "LoopKit could not reach GitHub. Check your connection and try again."
    }
  }
}

public actor GitHubReleaseClient: LoopKitReleaseFetching {
  public static let latestReleaseURL = URL(
    string: "https://api.github.com/repos/twoplustwoone/loop-kit/releases/latest"
  )!

  private let session: URLSession
  private let endpoint: URL

  public init(
    session: URLSession = .shared,
    endpoint: URL = GitHubReleaseClient.latestReleaseURL
  ) {
    self.session = session
    self.endpoint = endpoint
  }

  public func latestRelease() async throws -> GitHubRelease {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "GET"
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    request.setValue("LoopKit-Update-Checker", forHTTPHeaderField: "User-Agent")

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw LoopKitUpdateCheckError.requestFailed(error.localizedDescription)
    }

    guard let httpResponse = response as? HTTPURLResponse else {
      throw LoopKitUpdateCheckError.invalidResponse
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      throw LoopKitUpdateCheckError.httpStatus(httpResponse.statusCode)
    }

    do {
      return try JSONDecoder().decode(GitHubRelease.self, from: data)
    } catch {
      throw LoopKitUpdateCheckError.invalidResponse
    }
  }
}

public enum LoopKitUpdateCheckTrigger: Sendable {
  case automatic(setupComplete: Bool)
  case manual

  fileprivate var isAutomatic: Bool {
    if case .automatic = self { return true }
    return false
  }
}

public enum LoopKitUpdateCheckResult: Equatable, Sendable {
  case current(installed: LoopKitVersion, latest: LoopKitVersion)
  case available(installed: LoopKitVersion, release: GitHubRelease)
  case failed(LoopKitUpdateCheckError)

  public var availableRelease: GitHubRelease? {
    if case .available(_, let release) = self { return release }
    return nil
  }
}

public enum LoopKitUpdatePresentationPolicy {
  public static func shouldPresent(
    result: LoopKitUpdateCheckResult,
    trigger: LoopKitUpdateCheckTrigger
  ) -> Bool {
    switch trigger {
    case .manual:
      return true
    case .automatic:
      return false
    }
  }
}

public actor LoopKitUpdateCheckService {
  public static let automaticInterval: TimeInterval = 24 * 60 * 60

  private let fetcher: any LoopKitReleaseFetching
  private let persistence: any LoopKitUpdatePersisting
  private let now: @Sendable () -> Date
  private struct InFlight {
    let id: UUID
    let task: Task<LoopKitUpdateCheckResult?, Never>
  }

  private var inFlight: InFlight?

  public init(
    fetcher: any LoopKitReleaseFetching,
    persistence: any LoopKitUpdatePersisting,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.fetcher = fetcher
    self.persistence = persistence
    self.now = now
  }

  public func cachedAvailability(installedVersion rawInstalledVersion: String) async -> GitHubRelease? {
    guard let installedVersion = LoopKitVersion(rawInstalledVersion),
          let release = await persistence.cachedRelease(),
          release.isEligible,
          let latestVersion = release.version,
          latestVersion > installedVersion
    else {
      return nil
    }
    return release
  }

  public func check(
    installedVersion rawInstalledVersion: String,
    trigger: LoopKitUpdateCheckTrigger
  ) async -> LoopKitUpdateCheckResult? {
    if case .automatic(let setupComplete) = trigger, !setupComplete {
      return nil
    }

    if let inFlight {
      let joinedResult = await inFlight.task.value
      if joinedResult == nil, !trigger.isAutomatic {
        if self.inFlight?.id == inFlight.id {
          self.inFlight = nil
        }
        return await check(installedVersion: rawInstalledVersion, trigger: trigger)
      }
      return joinedResult
    }

    let fetcher = self.fetcher
    let persistence = self.persistence
    let checkDate = now()
    let task = Task<LoopKitUpdateCheckResult?, Never> {
      if trigger.isAutomatic {
        if let lastAttempt = await persistence.lastAutomaticAttempt(),
           checkDate.timeIntervalSince(lastAttempt) < Self.automaticInterval {
          return nil
        }
        await persistence.setLastAutomaticAttempt(checkDate)
      }

      guard let installedVersion = LoopKitVersion(rawInstalledVersion) else {
        return .failed(.invalidInstalledVersion(rawInstalledVersion))
      }

      do {
        let release = try await fetcher.latestRelease()
        guard release.isEligible, let latestVersion = release.version else {
          return .failed(.ineligibleRelease)
        }
        await persistence.setCachedRelease(release)
        if latestVersion > installedVersion {
          return .available(installed: installedVersion, release: release)
        }
        return .current(installed: installedVersion, latest: latestVersion)
      } catch let error as LoopKitUpdateCheckError {
        return .failed(error)
      } catch {
        return .failed(.requestFailed(error.localizedDescription))
      }
    }
    let requestID = UUID()
    inFlight = InFlight(id: requestID, task: task)
    let result = await task.value
    if inFlight?.id == requestID {
      inFlight = nil
    }
    return result
  }
}
