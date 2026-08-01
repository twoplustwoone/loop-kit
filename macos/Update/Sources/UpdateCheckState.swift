import Foundation

public enum LoopKitUpdatePresentation: Equatable, Sendable {
  case checking
  case current(installedVersion: String)
  case available(installedVersion: String, release: GitHubRelease)
  case failed(message: String)
}

public enum LoopKitUpdateCheckStart: Equatable, Sendable {
  case started(id: UInt64, trigger: LoopKitUpdateCheckTrigger)
  case joined(recordAutomaticAttempt: Bool)
}

public enum LoopKitUpdateCheckCompletion: Equatable, Sendable {
  case finished
  case retryManually
}

public struct LoopKitUpdateStateMachine: Sendable {
  private struct ActiveCheck: Sendable {
    let id: UInt64
    let startedManually: Bool
    var shouldPresentResult: Bool
  }

  public private(set) var availableRelease: GitHubRelease?
  public private(set) var presentation: LoopKitUpdatePresentation?

  private var activeCheck: ActiveCheck?
  private var nextCheckID: UInt64 = 0
  private var successfulResultGeneration: UInt64 = 0

  public init(
    availableRelease: GitHubRelease? = nil,
    presentation: LoopKitUpdatePresentation? = nil
  ) {
    self.availableRelease = availableRelease
    self.presentation = presentation
  }

  public var cacheRestoreGeneration: UInt64 {
    successfulResultGeneration
  }

  public mutating func beginCheck(
    trigger: LoopKitUpdateCheckTrigger
  ) -> LoopKitUpdateCheckStart {
    let isManual = trigger == .manual
    let isEligibleAutomatic: Bool
    if case .automatic(let setupComplete) = trigger {
      isEligibleAutomatic = setupComplete
    } else {
      isEligibleAutomatic = false
    }
    if var activeCheck {
      if isManual {
        activeCheck.shouldPresentResult = true
        self.activeCheck = activeCheck
        presentation = .checking
      }
      return .joined(
        recordAutomaticAttempt: isEligibleAutomatic && activeCheck.startedManually
      )
    }

    nextCheckID &+= 1
    let checkID = nextCheckID
    activeCheck = ActiveCheck(
      id: checkID,
      startedManually: isManual,
      shouldPresentResult: isManual
    )
    if isManual {
      presentation = .checking
    }
    return .started(id: checkID, trigger: trigger)
  }

  public mutating func completeCheck(
    id: UInt64,
    result: LoopKitUpdateCheckResult?
  ) -> LoopKitUpdateCheckCompletion {
    guard let activeCheck, activeCheck.id == id else { return .finished }
    self.activeCheck = nil

    guard let result else {
      if activeCheck.shouldPresentResult {
        presentation = .checking
        return .retryManually
      }
      return .finished
    }

    let shouldPresent = activeCheck.shouldPresentResult
    let isPresentingAvailable: Bool
    if case .available = presentation {
      isPresentingAvailable = true
    } else {
      isPresentingAvailable = false
    }
    switch result {
    case .available(let installed, let release):
      successfulResultGeneration &+= 1
      availableRelease = release
      if shouldPresent || isPresentingAvailable {
        presentation = .available(
          installedVersion: installed.description,
          release: release
        )
      }

    case .current(let installed, _):
      successfulResultGeneration &+= 1
      availableRelease = nil
      if shouldPresent {
        presentation = .current(installedVersion: installed.description)
      } else if isPresentingAvailable {
        presentation = nil
      }

    case .failed(let error):
      if shouldPresent {
        presentation = .failed(
          message: error.errorDescription ?? "The update check could not complete."
        )
      }
    }
    return .finished
  }

  public mutating func restoreCachedAvailability(
    _ release: GitHubRelease?,
    generation: UInt64
  ) {
    guard generation == successfulResultGeneration else { return }
    availableRelease = release
  }

  public mutating func presentAvailableUpdate(installedVersion: String) {
    guard let availableRelease else { return }
    presentation = .available(
      installedVersion: installedVersion,
      release: availableRelease
    )
  }

  public mutating func dismissPresentation() {
    presentation = nil
  }

  public mutating func reportReleaseOpenFailure() {
    presentation = .failed(
      message: "LoopKit could not open the release page. Check your default browser and try again."
    )
  }
}
