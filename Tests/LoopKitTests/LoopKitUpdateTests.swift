import Foundation
import XCTest
@testable import LoopKitUpdate

final class LoopKitUpdateTests: XCTestCase {
  func testVersionNormalizationAndValidation() {
    XCTAssertEqual(LoopKitVersion("1.2.3")?.description, "1.2.3")
    XCTAssertEqual(LoopKitVersion("v1.2.3")?.description, "1.2.3")
    XCTAssertEqual(LoopKitVersion("1.2.3+build.9"), LoopKitVersion("1.2.3+other"))

    for invalid in [
      "", "v", "vv1.2.3", "1.2", "1.2.3.4", "01.2.3", "1.-2.3",
      "1.2.x", "1.2.3-", "1.2.3-alpha..1", "1.2.3-01", "1.2.3+",
      "1.2.3+bad!", "999999999999999999999999.2.3"
    ] {
      XCTAssertNil(LoopKitVersion(invalid), "Expected \(invalid) to be rejected")
    }
  }

  func testSemanticVersionOrdering() {
    XCTAssertLessThan(version("1.2.3"), version("1.2.4"))
    XCTAssertLessThan(version("1.2.9"), version("1.3.0"))
    XCTAssertLessThan(version("1.9.9"), version("2.0.0"))
    XCTAssertLessThan(version("1.0.0-alpha"), version("1.0.0-alpha.1"))
    XCTAssertLessThan(version("1.0.0-alpha.1"), version("1.0.0-alpha.beta"))
    XCTAssertLessThan(version("1.0.0-beta.2"), version("1.0.0-beta.11"))
    XCTAssertLessThan(version("1.0.0-rc.1"), version("1.0.0"))
    XCTAssertEqual(version("v2.4.6"), version("2.4.6"))
  }

  func testOversizedNumericPrereleaseIdentifiersUseNumericOrdering() {
    let smaller = version("1.0.0-9999999999999999999")
    let larger = version("1.0.0-10000000000000000000")

    XCTAssertLessThan(smaller, larger)
    XCTAssertLessThan(larger, version("1.0.0-alpha"))
    XCTAssertEqual(larger.description, "1.0.0-10000000000000000000")
  }

  func testManualCheckKeepsVisibleResultWhenAutomaticTriggerJoins() {
    let available = release("2.0.0")
    var state = LoopKitUpdateStateMachine()

    guard case .started(let checkID, .manual) = state.beginCheck(trigger: .manual) else {
      return XCTFail("Expected the manual check to start")
    }
    XCTAssertEqual(state.presentation, .checking)
    XCTAssertEqual(
      state.beginCheck(trigger: .automatic(setupComplete: true)),
      .joined(recordAutomaticAttempt: true)
    )

    let completion = state.completeCheck(
      id: checkID,
      result: .available(installed: version("1.0.0"), release: available)
    )
    XCTAssertEqual(completion, .finished)
    XCTAssertEqual(
      state.presentation,
      .available(installedVersion: "1.0.0", release: available)
    )
  }

  func testSetupIncompleteAutomaticTriggerDoesNotRecordJoinedAttempt() {
    var state = LoopKitUpdateStateMachine()
    guard case .started(_, .manual) = state.beginCheck(trigger: .manual) else {
      return XCTFail("Expected the manual check to start")
    }

    XCTAssertEqual(
      state.beginCheck(trigger: .automatic(setupComplete: false)),
      .joined(recordAutomaticAttempt: false)
    )
  }

  func testManualTriggerPromotesAnAutomaticCheckToVisibleResult() {
    let available = release("2.0.0")
    var state = LoopKitUpdateStateMachine()

    guard case .started(let checkID, .automatic(setupComplete: true)) = state.beginCheck(
      trigger: .automatic(setupComplete: true)
    ) else {
      return XCTFail("Expected the automatic check to start")
    }
    XCTAssertEqual(state.beginCheck(trigger: .manual), .joined(recordAutomaticAttempt: false))
    XCTAssertEqual(state.presentation, .checking)

    _ = state.completeCheck(
      id: checkID,
      result: .available(installed: version("1.0.0"), release: available)
    )
    XCTAssertEqual(
      state.presentation,
      .available(installedVersion: "1.0.0", release: available)
    )
  }

  func testAutomaticFailurePreservesCachedAvailabilityAcrossRestoreOrdering() {
    let cached = release("2.0.0")

    var cacheFirst = LoopKitUpdateStateMachine()
    let firstGeneration = cacheFirst.cacheRestoreGeneration
    cacheFirst.restoreCachedAvailability(cached, generation: firstGeneration)
    guard case .started(let firstCheckID, _) = cacheFirst.beginCheck(
      trigger: .automatic(setupComplete: true)
    ) else {
      return XCTFail("Expected the first automatic check to start")
    }
    _ = cacheFirst.completeCheck(id: firstCheckID, result: .failed(.httpStatus(429)))
    XCTAssertEqual(cacheFirst.availableRelease, cached)
    XCTAssertNil(cacheFirst.presentation)

    var failureFirst = LoopKitUpdateStateMachine()
    let secondGeneration = failureFirst.cacheRestoreGeneration
    guard case .started(let secondCheckID, _) = failureFirst.beginCheck(
      trigger: .automatic(setupComplete: true)
    ) else {
      return XCTFail("Expected the second automatic check to start")
    }
    _ = failureFirst.completeCheck(id: secondCheckID, result: .failed(.httpStatus(429)))
    failureFirst.restoreCachedAvailability(cached, generation: secondGeneration)
    XCTAssertEqual(failureFirst.availableRelease, cached)
    XCTAssertNil(failureFirst.presentation)
  }

  func testSuccessfulCurrentResultRejectsLateCachedAvailability() {
    let cached = release("2.0.0")
    var state = LoopKitUpdateStateMachine()
    let staleGeneration = state.cacheRestoreGeneration

    guard case .started(let checkID, _) = state.beginCheck(
      trigger: .automatic(setupComplete: true)
    ) else {
      return XCTFail("Expected the automatic check to start")
    }
    _ = state.completeCheck(
      id: checkID,
      result: .current(installed: version("2.0.0"), latest: version("2.0.0"))
    )
    state.restoreCachedAvailability(cached, generation: staleGeneration)
    XCTAssertNil(state.availableRelease)
  }

  func testBackgroundResultsReconcileAnOpenAvailabilityPresentation() {
    let cached = release("2.0.0")
    let newer = release("3.0.0")
    var newerState = LoopKitUpdateStateMachine(
      availableRelease: cached,
      presentation: .available(installedVersion: "1.0.0", release: cached)
    )

    guard case .started(let newerCheckID, _) = newerState.beginCheck(
      trigger: .automatic(setupComplete: true)
    ) else {
      return XCTFail("Expected the automatic check to start")
    }
    _ = newerState.completeCheck(
      id: newerCheckID,
      result: .available(installed: version("1.0.0"), release: newer)
    )
    XCTAssertEqual(newerState.availableRelease, newer)
    XCTAssertEqual(
      newerState.presentation,
      .available(installedVersion: "1.0.0", release: newer)
    )

    var currentState = LoopKitUpdateStateMachine(
      availableRelease: cached,
      presentation: .available(installedVersion: "1.0.0", release: cached)
    )
    guard case .started(let currentCheckID, _) = currentState.beginCheck(
      trigger: .automatic(setupComplete: true)
    ) else {
      return XCTFail("Expected the automatic check to start")
    }
    _ = currentState.completeCheck(
      id: currentCheckID,
      result: .current(installed: version("2.0.0"), latest: version("2.0.0"))
    )
    XCTAssertNil(currentState.availableRelease)
    XCTAssertNil(currentState.presentation)
  }

  func testBackgroundFailureKeepsAnOpenAvailabilityPresentation() {
    let cached = release("2.0.0")
    let cachedPresentation = LoopKitUpdatePresentation.available(
      installedVersion: "1.0.0",
      release: cached
    )
    var state = LoopKitUpdateStateMachine(
      availableRelease: cached,
      presentation: cachedPresentation
    )

    guard case .started(let checkID, _) = state.beginCheck(
      trigger: .automatic(setupComplete: true)
    ) else {
      return XCTFail("Expected the automatic check to start")
    }
    _ = state.completeCheck(id: checkID, result: .failed(.httpStatus(429)))

    XCTAssertEqual(state.availableRelease, cached)
    XCTAssertEqual(state.presentation, cachedPresentation)
  }

  func testVisibleCheckResultsPublishOperationSpecificAnnouncements() {
    let available = release("2.0.0")

    var availableState = LoopKitUpdateStateMachine()
    guard case .started(let availableCheckID, _) = availableState.beginCheck(trigger: .manual)
    else {
      return XCTFail("Expected the available check to start")
    }
    _ = availableState.completeCheck(
      id: availableCheckID,
      result: .available(installed: version("1.0.0"), release: available)
    )
    XCTAssertEqual(availableState.announcement?.message, "LoopKit update 2.0.0 is available.")

    var currentState = LoopKitUpdateStateMachine()
    guard case .started(let currentCheckID, _) = currentState.beginCheck(trigger: .manual) else {
      return XCTFail("Expected the current check to start")
    }
    _ = currentState.completeCheck(
      id: currentCheckID,
      result: .current(installed: version("2.0.0"), latest: version("2.0.0"))
    )
    XCTAssertEqual(currentState.announcement?.message, "LoopKit 2.0.0 is up to date.")

    var failedState = LoopKitUpdateStateMachine()
    guard case .started(let failedCheckID, _) = failedState.beginCheck(trigger: .manual) else {
      return XCTFail("Expected the failed check to start")
    }
    _ = failedState.completeCheck(id: failedCheckID, result: .failed(.httpStatus(429)))
    guard case .checkFailed(let message) = failedState.presentation else {
      return XCTFail("Expected a check-specific failure")
    }
    XCTAssertTrue(failedState.announcement?.message.contains(message) == true)
  }

  func testBackgroundResultsDoNotPublishAnnouncements() {
    let available = release("2.0.0")
    var state = LoopKitUpdateStateMachine(
      availableRelease: available,
      presentation: .available(installedVersion: "1.0.0", release: available)
    )

    guard case .started(let checkID, _) = state.beginCheck(
      trigger: .automatic(setupComplete: true)
    ) else {
      return XCTFail("Expected the automatic check to start")
    }
    _ = state.completeCheck(
      id: checkID,
      result: .available(installed: version("1.0.0"), release: release("3.0.0"))
    )

    XCTAssertNil(state.announcement)
  }

  func testReleaseOpenFailurePreservesReleaseForOperationSpecificRetry() {
    let available = release("2.0.0")
    var state = LoopKitUpdateStateMachine(
      availableRelease: available,
      presentation: .available(installedVersion: "1.0.0", release: available)
    )

    state.reportReleaseOpenFailure(available)

    guard case .releaseOpenFailed(let retryRelease, let message) = state.presentation else {
      return XCTFail("Expected a release-open failure")
    }
    XCTAssertEqual(retryRelease, available)
    XCTAssertTrue(message.contains("default browser"))
    XCTAssertEqual(state.announcement?.message, message)
  }

  func testGitHubReleaseDecodingAndEligibility() throws {
    let data = Data(#"""
    {
      "tag_name":"v1.4.9",
      "html_url":"https://github.com/twoplustwoone/loop-kit/releases/tag/v1.4.9",
      "name":"LoopKit 1.4.9 Community",
      "body":"Fixes and improvements.",
      "draft":false,
      "prerelease":false
    }
    """#.utf8)
    let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
    XCTAssertTrue(release.isEligible)
    XCTAssertEqual(release.version, version("1.4.9"))
    XCTAssertEqual(release.notes, "Fixes and improvements.")
    XCTAssertEqual(
      release.releaseURL.absoluteString,
      "https://github.com/twoplustwoone/loop-kit/releases/tag/v1.4.9"
    )

    XCTAssertThrowsError(
      try JSONDecoder().decode(
        GitHubRelease.self,
        from: Data(#"{"html_url":"https://github.com/release","draft":false,"prerelease":false}"#.utf8)
      )
    )
  }

  func testIneligibleReleaseVariants() {
    XCTAssertFalse(release("1.2.0", draft: true).isEligible)
    XCTAssertFalse(release("1.2.0", prerelease: true).isEligible)
    XCTAssertFalse(release("1.2.0-rc.1").isEligible)
    XCTAssertFalse(release("1.2", url: "https://github.com/release").isEligible)
    XCTAssertFalse(release("1.2.0", url: "http://github.com/release").isEligible)
    XCTAssertFalse(release("1.2.0", url: "https://example.com/1.2.0").isEligible)
    XCTAssertFalse(
      release(
        "1.2.0",
        url: "https://github.com/twoplustwoone/other/releases/tag/1.2.0"
      ).isEligible
    )
    XCTAssertFalse(
      release(
        "1.2.0",
        url: "https://user@github.com/twoplustwoone/loop-kit/releases/tag/1.2.0"
      ).isEligible
    )
    XCTAssertFalse(
      release(
        "1.2.0",
        url: "https://github.com/twoplustwoone/loop-kit/releases/tag/1.2.0?source=other"
      ).isEligible
    )
  }

  func testGitHubClientBuildsExpectedRequest() async throws {
    let endpoint = URL(string: "https://api.github.test/releases/latest")!
    let session = makeURLSession { request in
      XCTAssertEqual(request.url, endpoint)
      XCTAssertEqual(request.httpMethod, "GET")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
      XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
      XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "LoopKit-Update-Checker")
      return (
        HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        self.releaseJSON("1.4.9")
      )
    }
    defer { session.invalidateAndCancel() }

    let fetched = try await GitHubReleaseClient(session: session, endpoint: endpoint).latestRelease()
    XCTAssertTrue(fetched.isEligible)
    XCTAssertEqual(fetched.version, version("1.4.9"))
  }

  func testGitHubClientRejectsHTTPAndMalformedResponses() async {
    let endpoint = URL(string: "https://api.github.test/releases/latest")!
    let rateLimitedSession = makeURLSession { _ in
      (
        HTTPURLResponse(url: endpoint, statusCode: 429, httpVersion: nil, headerFields: nil)!,
        Data()
      )
    }
    defer { rateLimitedSession.invalidateAndCancel() }

    do {
      _ = try await GitHubReleaseClient(
        session: rateLimitedSession,
        endpoint: endpoint
      ).latestRelease()
      XCTFail("Expected HTTP failure")
    } catch let error as LoopKitUpdateCheckError {
      XCTAssertEqual(error, .httpStatus(429))
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    let malformedSession = makeURLSession { _ in
      (
        HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data("not json".utf8)
      )
    }
    defer { malformedSession.invalidateAndCancel() }

    do {
      _ = try await GitHubReleaseClient(
        session: malformedSession,
        endpoint: endpoint
      ).latestRelease()
      XCTFail("Expected malformed-response failure")
    } catch let error as LoopKitUpdateCheckError {
      XCTAssertEqual(error, .invalidResponse)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testResultClassificationNeverOffersDowngrade() async {
    let persistence = TestUpdatePersistence()

    let available = LoopKitUpdateCheckService(
      fetcher: TestReleaseFetcher(result: .success(release("1.2.0"))),
      persistence: persistence
    )
    let availableResult = await available.check(installedVersion: "1.1.0", trigger: .manual)
    XCTAssertEqual(availableResult?.availableRelease?.version, version("1.2.0"))

    let current = LoopKitUpdateCheckService(
      fetcher: TestReleaseFetcher(result: .success(release("1.2.0"))),
      persistence: persistence
    )
    let currentResult = await current.check(installedVersion: "1.2.0", trigger: .manual)
    XCTAssertEqual(
      currentResult,
      .current(installed: version("1.2.0"), latest: version("1.2.0"))
    )

    let newerInstalled = LoopKitUpdateCheckService(
      fetcher: TestReleaseFetcher(result: .success(release("1.2.0"))),
      persistence: persistence
    )
    let newerInstalledResult = await newerInstalled.check(
      installedVersion: "2.0.0",
      trigger: .manual
    )
    XCTAssertEqual(
      newerInstalledResult,
      .current(installed: version("2.0.0"), latest: version("1.2.0"))
    )
  }

  func testInvalidInstalledAndLatestVersionsFailSafely() async {
    let persistence = TestUpdatePersistence()
    let invalidInstalled = LoopKitUpdateCheckService(
      fetcher: TestReleaseFetcher(result: .success(release("1.2.0"))),
      persistence: persistence
    )
    let invalidInstalledResult = await invalidInstalled.check(
      installedVersion: "development",
      trigger: .manual
    )
    XCTAssertEqual(
      invalidInstalledResult,
      .failed(.invalidInstalledVersion("development"))
    )

    let invalidLatest = LoopKitUpdateCheckService(
      fetcher: TestReleaseFetcher(result: .success(release("not-a-version"))),
      persistence: persistence
    )
    let invalidLatestResult = await invalidLatest.check(
      installedVersion: "1.0.0",
      trigger: .manual
    )
    XCTAssertEqual(
      invalidLatestResult,
      .failed(.ineligibleRelease)
    )
  }

  func testAutomaticCadenceAndSetupGate() async {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let fetcher = TestReleaseFetcher(result: .success(release("1.2.0")))
    let persistence = TestUpdatePersistence()
    let service = LoopKitUpdateCheckService(
      fetcher: fetcher,
      persistence: persistence,
      now: { now }
    )

    let gatedResult = await service.check(
      installedVersion: "1.0.0",
      trigger: .automatic(setupComplete: false)
    )
    XCTAssertNil(gatedResult)
    let gatedCallCount = await fetcher.callCount()
    XCTAssertEqual(gatedCallCount, 0)

    _ = await service.check(
      installedVersion: "1.0.0",
      trigger: .automatic(setupComplete: true)
    )
    let firstCallCount = await fetcher.callCount()
    let lastAttempt = await persistence.lastAutomaticAttempt()
    XCTAssertEqual(firstCallCount, 1)
    XCTAssertEqual(lastAttempt, now)

    _ = await service.check(
      installedVersion: "1.0.0",
      trigger: .automatic(setupComplete: true)
    )
    let throttledCallCount = await fetcher.callCount()
    XCTAssertEqual(throttledCallCount, 1)
  }

  func testAutomaticBoundaryAndBackwardClock() async {
    let now = Date(timeIntervalSince1970: 2_000_000)

    let boundaryFetcher = TestReleaseFetcher(result: .success(release("1.2.0")))
    let boundaryPersistence = TestUpdatePersistence(
      lastAttempt: now.addingTimeInterval(-LoopKitUpdateCheckService.automaticInterval)
    )
    let boundaryService = LoopKitUpdateCheckService(
      fetcher: boundaryFetcher,
      persistence: boundaryPersistence,
      now: { now }
    )
    _ = await boundaryService.check(
      installedVersion: "1.0.0",
      trigger: .automatic(setupComplete: true)
    )
    let boundaryCallCount = await boundaryFetcher.callCount()
    XCTAssertEqual(boundaryCallCount, 1)

    let backwardFetcher = TestReleaseFetcher(result: .success(release("1.2.0")))
    let backwardPersistence = TestUpdatePersistence(lastAttempt: now.addingTimeInterval(60))
    let backwardService = LoopKitUpdateCheckService(
      fetcher: backwardFetcher,
      persistence: backwardPersistence,
      now: { now }
    )
    let backwardResult = await backwardService.check(
      installedVersion: "1.0.0",
      trigger: .automatic(setupComplete: true)
    )
    XCTAssertNil(backwardResult)
    let backwardCallCount = await backwardFetcher.callCount()
    XCTAssertEqual(backwardCallCount, 0)
  }

  func testAutomaticFailuresArePersistedAndManualChecksBypassCadence() async {
    let now = Date(timeIntervalSince1970: 3_000_000)
    let fetcher = TestReleaseFetcher(result: .failure(.httpStatus(429)))
    let persistence = TestUpdatePersistence()
    let service = LoopKitUpdateCheckService(
      fetcher: fetcher,
      persistence: persistence,
      now: { now }
    )

    let automaticFailure = await service.check(
      installedVersion: "1.0.0",
      trigger: .automatic(setupComplete: true)
    )
    XCTAssertEqual(
      automaticFailure,
      .failed(.httpStatus(429))
    )
    let failureAttempt = await persistence.lastAutomaticAttempt()
    XCTAssertEqual(failureAttempt, now)
    let throttledResult = await service.check(
      installedVersion: "1.0.0",
      trigger: .automatic(setupComplete: true)
    )
    XCTAssertNil(throttledResult)
    let manualFailure = await service.check(installedVersion: "1.0.0", trigger: .manual)
    XCTAssertEqual(
      manualFailure,
      .failed(.httpStatus(429))
    )
    let failureCallCount = await fetcher.callCount()
    XCTAssertEqual(failureCallCount, 2)
  }

  func testJoinedAutomaticTriggerCanRecordCadenceWithoutFetching() async {
    let now = Date(timeIntervalSince1970: 3_500_000)
    let fetcher = TestReleaseFetcher(result: .success(release("1.2.0")))
    let persistence = TestUpdatePersistence()
    let service = LoopKitUpdateCheckService(
      fetcher: fetcher,
      persistence: persistence,
      now: { now }
    )

    await service.recordAutomaticAttemptIfEligible(setupComplete: true)

    let recordedAttempt = await persistence.lastAutomaticAttempt()
    let callCount = await fetcher.callCount()
    XCTAssertEqual(recordedAttempt, now)
    XCTAssertEqual(callCount, 0)
  }

  func testConcurrentManualAndAutomaticChecksShareOneFetch() async {
    let fetcher = TestReleaseFetcher(
      result: .success(release("1.2.0")),
      delayNanoseconds: 80_000_000
    )
    let service = LoopKitUpdateCheckService(
      fetcher: fetcher,
      persistence: TestUpdatePersistence(),
      now: { Date(timeIntervalSince1970: 4_000_000) }
    )

    async let automatic = service.check(
      installedVersion: "1.0.0",
      trigger: .automatic(setupComplete: true)
    )
    try? await Task.sleep(nanoseconds: 10_000_000)
    async let manual = service.check(installedVersion: "1.0.0", trigger: .manual)
    let (automaticResult, manualResult) = await (automatic, manual)

    XCTAssertEqual(automaticResult, manualResult)
    let concurrentCallCount = await fetcher.callCount()
    XCTAssertEqual(concurrentCallCount, 1)
  }

  func testManualCheckRetriesWhenJoinedAutomaticCheckIsCadenceSuppressed() async {
    let now = Date(timeIntervalSince1970: 4_500_000)
    let fetcher = TestReleaseFetcher(result: .success(release("1.2.0")))
    let persistence = TestUpdatePersistence(
      lastAttempt: now,
      lastAttemptReadDelayNanoseconds: 60_000_000
    )
    let service = LoopKitUpdateCheckService(
      fetcher: fetcher,
      persistence: persistence,
      now: { now }
    )

    async let automatic = service.check(
      installedVersion: "1.0.0",
      trigger: .automatic(setupComplete: true)
    )
    try? await Task.sleep(nanoseconds: 10_000_000)
    async let manual = service.check(installedVersion: "1.0.0", trigger: .manual)
    let (automaticResult, manualResult) = await (automatic, manual)

    XCTAssertNil(automaticResult)
    XCTAssertEqual(manualResult?.availableRelease?.version, version("1.2.0"))
    let callCount = await fetcher.callCount()
    XCTAssertEqual(callCount, 1)
  }

  func testCachedReleaseIsRevalidatedAgainstInstalledVersion() async {
    let cached = release("2.0.0")
    let persistence = TestUpdatePersistence(cachedRelease: cached)
    let service = LoopKitUpdateCheckService(
      fetcher: TestReleaseFetcher(result: .success(cached)),
      persistence: persistence
    )

    let olderInstalled = await service.cachedAvailability(installedVersion: "1.0.0")
    let equalInstalled = await service.cachedAvailability(installedVersion: "2.0.0")
    let newerInstalled = await service.cachedAvailability(installedVersion: "3.0.0")
    let malformedInstalled = await service.cachedAvailability(installedVersion: "malformed")
    XCTAssertEqual(olderInstalled, cached)
    XCTAssertNil(equalInstalled)
    XCTAssertNil(newerInstalled)
    XCTAssertNil(malformedInstalled)
  }

  func testCorruptUserDefaultsCacheIsIgnored() async {
    let suiteName = "LoopKitUpdateTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(Data("not json".utf8), forKey: "Test.cachedRelease")

    let persistence = UserDefaultsLoopKitUpdatePersistence(
      defaults: defaults,
      keyPrefix: "Test"
    )
    let corruptCache = await persistence.cachedRelease()
    XCTAssertNil(corruptCache)
  }

  private func version(_ value: String) -> LoopKitVersion {
    guard let version = LoopKitVersion(value) else {
      XCTFail("Invalid test version \(value)")
      fatalError("Invalid test version")
    }
    return version
  }

  private func release(
    _ version: String,
    url: String? = nil,
    draft: Bool = false,
    prerelease: Bool = false
  ) -> GitHubRelease {
    GitHubRelease(
      tagName: version,
      releaseURL: URL(
        string: url ?? "https://github.com/twoplustwoone/loop-kit/releases/tag/\(version)"
      )!,
      name: "LoopKit \(version) Community",
      notes: "Release notes",
      draft: draft,
      prerelease: prerelease
    )
  }

  private func releaseJSON(_ version: String) -> Data {
    Data(#"""
    {
      "tag_name":"\#(version)",
      "html_url":"https://github.com/twoplustwoone/loop-kit/releases/tag/\#(version)",
      "name":"LoopKit \#(version) Community",
      "body":"Release notes",
      "draft":false,
      "prerelease":false
    }
    """#.utf8)
  }

  private func makeURLSession(
    handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
  ) -> URLSession {
    TestURLProtocol.setHandler(handler)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TestURLProtocol.self]
    return URLSession(configuration: configuration)
  }
}

private final class TestURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  private static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

  static func setHandler(
    _ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
  ) {
    lock.lock()
    self.handler = handler
    lock.unlock()
  }

  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.lock.lock()
    let handler = Self.handler
    Self.lock.unlock()

    guard let handler else {
      client?.urlProtocol(self, didFailWithError: URLError(.unknown))
      return
    }

    do {
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

private actor TestReleaseFetcher: LoopKitReleaseFetching {
  private let result: Result<GitHubRelease, LoopKitUpdateCheckError>
  private let delayNanoseconds: UInt64
  private var calls = 0

  init(
    result: Result<GitHubRelease, LoopKitUpdateCheckError>,
    delayNanoseconds: UInt64 = 0
  ) {
    self.result = result
    self.delayNanoseconds = delayNanoseconds
  }

  func latestRelease() async throws -> GitHubRelease {
    calls += 1
    if delayNanoseconds > 0 {
      try? await Task.sleep(nanoseconds: delayNanoseconds)
    }
    return try result.get()
  }

  func callCount() -> Int { calls }
}

private actor TestUpdatePersistence: LoopKitUpdatePersisting {
  private var lastAttempt: Date?
  private var release: GitHubRelease?
  private let lastAttemptReadDelayNanoseconds: UInt64

  init(
    lastAttempt: Date? = nil,
    cachedRelease: GitHubRelease? = nil,
    lastAttemptReadDelayNanoseconds: UInt64 = 0
  ) {
    self.lastAttempt = lastAttempt
    release = cachedRelease
    self.lastAttemptReadDelayNanoseconds = lastAttemptReadDelayNanoseconds
  }

  func lastAutomaticAttempt() async -> Date? {
    if lastAttemptReadDelayNanoseconds > 0 {
      try? await Task.sleep(nanoseconds: lastAttemptReadDelayNanoseconds)
    }
    return lastAttempt
  }

  func setLastAutomaticAttempt(_ date: Date) {
    lastAttempt = date
  }

  func cachedRelease() -> GitHubRelease? { release }

  func setCachedRelease(_ release: GitHubRelease) {
    self.release = release
  }
}
