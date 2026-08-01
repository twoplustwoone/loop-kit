import AppKit
import Foundation
import LoopKitUpdate
import SwiftUI

@MainActor
final class LoopKitUpdateViewModel: ObservableObject {
  typealias Presentation = LoopKitUpdatePresentation

  @Published private(set) var availableRelease: GitHubRelease?
  @Published private(set) var presentation: Presentation?
  @Published private(set) var announcement: LoopKitUpdateAnnouncement?

  let installedVersion: String

  private let service: LoopKitUpdateCheckService?
  private let openURL: (URL) -> Bool
  private var hasRestoredCache = false
  private var stateMachine: LoopKitUpdateStateMachine

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
    stateMachine = LoopKitUpdateStateMachine()
    availableRelease = stateMachine.availableRelease
    presentation = stateMachine.presentation
    announcement = stateMachine.announcement
  }

  private init(
    installedVersion: String,
    availableRelease: GitHubRelease?,
    presentation: Presentation?
  ) {
    service = nil
    self.installedVersion = installedVersion
    stateMachine = LoopKitUpdateStateMachine(
      availableRelease: availableRelease,
      presentation: presentation
    )
    self.availableRelease = stateMachine.availableRelease
    self.presentation = stateMachine.presentation
    announcement = stateMachine.announcement
    openURL = { _ in false }
    hasRestoredCache = true
  }

  func restoreCachedAvailability(setupComplete: Bool) {
    guard setupComplete, !hasRestoredCache, let service else { return }
    hasRestoredCache = true
    let generation = stateMachine.cacheRestoreGeneration
    Task {
      let release = await service.cachedAvailability(installedVersion: installedVersion)
      stateMachine.restoreCachedAvailability(release, generation: generation)
      publishState()
    }
  }

  func checkAutomaticallyIfEligible(setupComplete: Bool) {
    beginCheck(trigger: .automatic(setupComplete: setupComplete))
  }

  func checkManually() {
    beginCheck(trigger: .manual)
  }

  func presentAvailableUpdate() {
    stateMachine.presentAvailableUpdate(installedVersion: installedVersion)
    publishState()
  }

  func dismissPresentation() {
    stateMachine.dismissPresentation()
    publishState()
  }

  func viewRelease(_ release: GitHubRelease) {
    guard release.isEligible else { return }
    guard openURL(release.releaseURL) else {
      stateMachine.reportReleaseOpenFailure(release)
      publishState()
      return
    }
  }

  private func beginCheck(trigger: LoopKitUpdateCheckTrigger) {
    guard let service else { return }
    switch stateMachine.beginCheck(trigger: trigger) {
    case .joined(let recordAutomaticAttempt):
      publishState()
      if recordAutomaticAttempt {
        Task {
          await service.recordAutomaticAttemptIfEligible(setupComplete: true)
        }
      }

    case .started(let checkID, let serviceTrigger):
      publishState()
      Task {
        let result = await service.check(
          installedVersion: installedVersion,
          trigger: serviceTrigger
        )
        let completion = stateMachine.completeCheck(id: checkID, result: result)
        publishState()
        if completion == .retryManually {
          beginCheck(trigger: .manual)
        }
      }
    }
  }

  private func publishState() {
    availableRelease = stateMachine.availableRelease
    presentation = stateMachine.presentation
    announcement = stateMachine.announcement
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
      presentation: .checkFailed(
        message: "LoopKit could not reach GitHub. Check your connection and try again."
      )
    )
  }
}
#endif
