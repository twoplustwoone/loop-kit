import AppKit
import Foundation
import LoopKitUpdate
import SwiftUI

@MainActor
final class LoopKitUpdateViewModel: ObservableObject {
  enum Presentation: Equatable {
    case checking
    case current(installedVersion: String)
    case available(installedVersion: String, release: GitHubRelease)
    case failed(message: String)
  }

  @Published private(set) var availableRelease: GitHubRelease?
  @Published private(set) var presentation: Presentation?

  let installedVersion: String

  private let service: LoopKitUpdateCheckService?
  private let openURL: (URL) -> Bool
  private var hasRestoredCache = false
  private var stateRevision = 0

  init(
    service: LoopKitUpdateCheckService = LoopKitUpdateCheckService(
      fetcher: GitHubReleaseClient(),
      persistence: UserDefaultsLoopKitUpdatePersistence()
    ),
    installedVersion: String = Bundle.main.object(
      forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String ?? "Unknown",
    openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
  ) {
    self.service = service
    self.installedVersion = installedVersion
    self.openURL = openURL
  }

  private init(
    installedVersion: String,
    availableRelease: GitHubRelease?,
    presentation: Presentation?
  ) {
    service = nil
    self.installedVersion = installedVersion
    self.availableRelease = availableRelease
    self.presentation = presentation
    openURL = { _ in false }
    hasRestoredCache = true
  }

  func restoreCachedAvailability(setupComplete: Bool) {
    guard setupComplete, !hasRestoredCache, let service else { return }
    hasRestoredCache = true
    let revision = stateRevision
    Task {
      let release = await service.cachedAvailability(installedVersion: installedVersion)
      guard revision == stateRevision else { return }
      availableRelease = release
    }
  }

  func checkAutomaticallyIfEligible(setupComplete: Bool) {
    guard let service else { return }
    stateRevision += 1
    let revision = stateRevision
    let trigger = LoopKitUpdateCheckTrigger.automatic(setupComplete: setupComplete)
    Task {
      guard let result = await service.check(
        installedVersion: installedVersion,
        trigger: trigger
      ) else {
        guard revision == stateRevision, setupComplete else { return }
        availableRelease = await service.cachedAvailability(installedVersion: installedVersion)
        return
      }
      guard revision == stateRevision else { return }
      apply(result, trigger: trigger)
    }
  }

  func checkManually() {
    guard let service else { return }
    stateRevision += 1
    let revision = stateRevision
    presentation = .checking
    Task {
      guard let result = await service.check(
        installedVersion: installedVersion,
        trigger: .manual
      ) else {
        presentation = .failed(message: "The update check did not complete. Please try again.")
        return
      }
      guard revision == stateRevision else { return }
      apply(result, trigger: .manual)
    }
  }

  func presentAvailableUpdate() {
    guard let availableRelease else { return }
    presentation = .available(
      installedVersion: installedVersion,
      release: availableRelease
    )
  }

  func dismissPresentation() {
    presentation = nil
  }

  func viewRelease(_ release: GitHubRelease) {
    guard release.isEligible else { return }
    guard openURL(release.releaseURL) else {
      presentation = .failed(
        message: "LoopKit could not open the release page. Check your default browser and try again."
      )
      return
    }
  }

  private func apply(
    _ result: LoopKitUpdateCheckResult,
    trigger: LoopKitUpdateCheckTrigger
  ) {
    let presentResult = LoopKitUpdatePresentationPolicy.shouldPresent(
      result: result,
      trigger: trigger
    )
    switch result {
    case .available(let installed, let release):
      availableRelease = release
      if presentResult {
        presentation = .available(
          installedVersion: installed.description,
          release: release
        )
      }
    case .current(let installed, _):
      availableRelease = nil
      if presentResult {
        presentation = .current(installedVersion: installed.description)
      }
    case .failed(let error):
      if presentResult {
        presentation = .failed(
          message: error.errorDescription ?? "The update check could not complete."
        )
      }
    }
  }
}

#if DEBUG
extension LoopKitUpdateViewModel {
  static func previewAvailable() -> LoopKitUpdateViewModel {
    let release = GitHubRelease(
      tagName: "v12.34.567",
      releaseURL: URL(
        string: "https://github.com/twoplustwoone/loop-kit/releases/tag/v12.34.567"
      )!,
      name: "LoopKit 12.34.567 Community",
      notes: "Improves update discovery and includes a deliberately long release-note preview.\n\nCommunity builds remain ad-hoc signed and unnotarized. Download and installation still happen from the GitHub release page."
    )
    return LoopKitUpdateViewModel(
      installedVersion: "1.0.12",
      availableRelease: release,
      presentation: .available(installedVersion: "1.0.12", release: release)
    )
  }

  static func previewCurrent() -> LoopKitUpdateViewModel {
    LoopKitUpdateViewModel(
      installedVersion: "12.34.567",
      availableRelease: nil,
      presentation: .current(installedVersion: "12.34.567")
    )
  }

  static func previewChecking() -> LoopKitUpdateViewModel {
    LoopKitUpdateViewModel(
      installedVersion: "1.0.12",
      availableRelease: nil,
      presentation: .checking
    )
  }

  static func previewFailure() -> LoopKitUpdateViewModel {
    LoopKitUpdateViewModel(
      installedVersion: "1.0.12",
      availableRelease: nil,
      presentation: .failed(
        message: "LoopKit could not reach GitHub. Check your connection and try again."
      )
    )
  }
}
#endif
