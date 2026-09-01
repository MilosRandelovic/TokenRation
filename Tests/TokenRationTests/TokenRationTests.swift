import Foundation
import UsageState
import XCTest

@testable import TokenRation

/// A provider stub that returns whatever the test asks for, and counts calls.
private struct StubProvider: UsageProviding {
  let provider: Provider
  let outcome: @Sendable () throws -> UsageSnapshot
  /// Stands in for the credentials on disk; read through a box so a test can swap them
  /// mid-flight the way the CLI rewriting the Keychain does.
  var credentials: Box<String>? = nil

  func fetch() async throws -> UsageSnapshot { try outcome() }
  func credentialFingerprint() async -> String? { credentials?.value }
}

/// A value a `@Sendable` provider can read and a test can change.
private final class Box<T>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: T
  init(_ value: T) { stored = value }
  var value: T {
    get {
      lock.lock();
      defer { lock.unlock() };
      return stored
    }
    set {
      lock.lock();
      stored = newValue;
      lock.unlock()
    }
  }
}

/// Mutable flag usable from a `@Sendable` closure.
private final class Flag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  func set() {
    lock.lock();
    value = true;
    lock.unlock()
  }
  var isSet: Bool {
    lock.lock();
    defer { lock.unlock() };
    return value
  }
}

private func makeDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
  let defaults = UserDefaults(suiteName: name)!
  defaults.removePersistentDomain(forName: name)
  return defaults
}

private func snapshot(_ id: String) -> UsageSnapshot {
  UsageSnapshot(
    metrics: [
      DisplayMetric(
        id: id, provider: .codex, title: "T", symbolName: "clock", barText: "1%", valueText: "1% used", fraction: 0.01, severity: .normal,
        resetsAt: nil)
    ], updatedAt: Date())
}

// MARK: - 1. Codex-only installs / unavailable pins

@MainActor final class PreferencesTests: XCTestCase {
  func testCodexOnlyMachineDefaultsToACodexPin() {
    let prefs = Preferences(available: [.codex], defaults: makeDefaults())
    XCTAssertEqual(prefs.shownMetricIDs, ["codex:primary"])
    XCTAssertFalse(
      prefs.shownMetricIDs.contains { $0.hasPrefix("claude:") }, "a Codex-only Mac must not pin an unpinnable Claude placeholder")
  }

  func testPinsForUndetectedProvidersArePruned() {
    let defaults = makeDefaults()
    defaults.set(["claude:session", "codex:primary"], forKey: "shownMetricIDs")
    defaults.set(true, forKey: "shownMetricIDs.namespaced")

    let prefs = Preferences(available: [.codex], defaults: defaults)
    XCTAssertEqual(prefs.shownMetricIDs, ["codex:primary"])
    // The pruning is persisted, so it doesn't reappear next launch.
    XCTAssertEqual(defaults.stringArray(forKey: "shownMetricIDs"), ["codex:primary"])
  }

  func testPruningNeverLeavesTheMenuBarEmpty() {
    let defaults = makeDefaults()
    defaults.set(["claude:session"], forKey: "shownMetricIDs")
    defaults.set(true, forKey: "shownMetricIDs.namespaced")

    let prefs = Preferences(available: [.codex], defaults: defaults)
    XCTAssertEqual(prefs.shownMetricIDs, ["codex:primary"])
  }

  func testLegacyUnnamespacedPinsMigrateToClaude() {
    let defaults = makeDefaults()
    defaults.set(["session", "weekly"], forKey: "shownMetricIDs")

    let prefs = Preferences(available: [.claude, .codex], defaults: defaults)
    XCTAssertEqual(prefs.shownMetricIDs, ["claude:session", "claude:weekly"])
  }
}

// MARK: - 5b. Pins for metrics that vanish from a snapshot

@MainActor final class PinReconciliationTests: XCTestCase {
  func testPinForVanishedPerModelMetricIsDropped() {
    let defaults = makeDefaults()
    defaults.set(["codex:primary", "codex:model:retired"], forKey: "shownMetricIDs")
    defaults.set(true, forKey: "shownMetricIDs.namespaced")
    let prefs = Preferences(available: [.codex], defaults: defaults)

    // Codex reported successfully, but the per-model limit is gone.
    prefs.reconcile(knownIDs: ["codex:primary"], settled: [.codex])

    XCTAssertEqual(prefs.shownMetricIDs, ["codex:primary"])
    XCTAssertEqual(defaults.stringArray(forKey: "shownMetricIDs"), ["codex:primary"])
  }

  func testPinsAreKeptForProvidersThatHaveNotReportedYet() {
    let defaults = makeDefaults()
    defaults.set(["claude:session", "codex:primary"], forKey: "shownMetricIDs")
    defaults.set(true, forKey: "shownMetricIDs.namespaced")
    let prefs = Preferences(available: [.claude, .codex], defaults: defaults)

    // Only Codex has data; Claude's pin must survive until Claude actually reports.
    prefs.reconcile(knownIDs: ["codex:primary"], settled: [.codex])
    XCTAssertEqual(prefs.shownMetricIDs, ["claude:session", "codex:primary"])
  }

  func testReconcileKeepsAtLeastOnePin() {
    let defaults = makeDefaults()
    defaults.set(["codex:model:retired"], forKey: "shownMetricIDs")
    defaults.set(true, forKey: "shownMetricIDs.namespaced")
    let prefs = Preferences(available: [.codex], defaults: defaults)

    prefs.reconcile(knownIDs: ["codex:primary"], settled: [.codex])
    XCTAssertEqual(prefs.shownMetricIDs, ["codex:primary"], "reconciling must never leave the menu bar with nothing pinned")
  }

  func testReconcileIsANoOpBeforeAnyProviderReports() {
    let defaults = makeDefaults()
    defaults.set(["codex:model:retired"], forKey: "shownMetricIDs")
    defaults.set(true, forKey: "shownMetricIDs.namespaced")
    let prefs = Preferences(available: [.codex], defaults: defaults)

    prefs.reconcile(knownIDs: [], settled: [])
    XCTAssertEqual(prefs.shownMetricIDs, ["codex:model:retired"])
  }
}

// MARK: - Codex plan shapes

/// Codex plans differ in which rate-limit windows exist and which slot each arrives in. These
/// decode the wire payload the way the provider does, so plans nobody here can sign in to are
/// still covered.
final class CodexWindowTests: XCTestCase {
  private func metrics(_ json: String) throws -> [DisplayMetric] {
    let envelope = try JSONDecoder().decode(CodexUsageProvider.Envelope.self, from: Data(json.utf8))
    return CodexUsageProvider.metrics(from: try XCTUnwrap(envelope.result))
  }

  private func payload(_ limits: String) -> String { #"{"id":2,"result":{"rateLimits":{"# + limits + #"}}}"# }

  /// A weekly-only plan: one window, named and glyphed as the long one.
  func testWeeklyOnlyPlan() throws {
    let result = try metrics(payload(#""primary":{"usedPercent":41,"windowDurationMins":10080,"resetsAt":2000000}"#))
    XCTAssertEqual(result.map(\.title), ["Weekly (7-day)"])
    XCTAssertEqual(result.map(\.id), ["codex:primary"])
  }

  /// A plan with both windows, short one in `secondary`.
  func testShortWindowInSecondary() throws {
    let result = try metrics(
      payload(#""primary":{"usedPercent":41,"windowDurationMins":10080},"secondary":{"usedPercent":12,"windowDurationMins":300}"#))
    XCTAssertEqual(result.map(\.title), ["Session (5-hour)", "Weekly (7-day)"], "shortest window first")
  }

  /// The same plan shape with the slots swapped. Titles, order and glyphs must not change, because
  /// the slot carries no meaning — this is the case a weekly-only account cannot exercise.
  func testShortWindowInPrimary() throws {
    let result = try metrics(
      payload(#""primary":{"usedPercent":12,"windowDurationMins":300},"secondary":{"usedPercent":41,"windowDurationMins":10080}"#))
    XCTAssertEqual(result.map(\.title), ["Session (5-hour)", "Weekly (7-day)"], "order follows duration, not slot")
    // Paired with the title rather than checked by position: a positional check passes if order
    // and glyph are both wrong in the same direction.
    let glyphs = Dictionary(uniqueKeysWithValues: result.map { ($0.title, $0.symbolName) })
    XCTAssertEqual(glyphs["Session (5-hour)"], Provider.codex.symbol(for: .session), "a 5-hour limit must not wear the weekly glyph")
    XCTAssertEqual(glyphs["Weekly (7-day)"], Provider.codex.symbol(for: .window))
  }

  /// A window with no stated duration must not be guessed at.
  func testWindowWithoutADurationIsUnnamed() throws {
    let result = try metrics(payload(#""primary":{"usedPercent":5}"#))
    XCTAssertEqual(result.map(\.title), ["Usage limit"])
    XCTAssertEqual(result.map(\.symbolName), [Provider.codex.symbol(for: .window)], "an unknown window is the long one")
  }
}

// MARK: - Credentials

final class KeychainTokenTests: XCTestCase {
  /// The CLI writes the credential back with empty strings when its refresh token has expired
  /// and the refresh fails. Sending that as a bearer token earns an HTTP 429, so treating it as
  /// a real token makes the app report a throttle and back off for hours over a sign-in problem.
  func testEmptyAccessTokenIsSignedOut() {
    let secret = #"{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}"#
    XCTAssertThrowsError(try KeychainToken.token(fromSecret: secret)) { error in
      guard case UsageError.notSignedIn = error else { return XCTFail("expected notSignedIn, got \(error)") }
    }
  }

  func testTokenIsReadFromTheBlob() throws {
    let secret = #"{"claudeAiOauth":{"accessToken":"sk-test-value","refreshToken":"r"}}"# + "\n"
    XCTAssertEqual(try KeychainToken.token(fromSecret: secret), "sk-test-value")
  }

  func testGarbageIsSignedOut() {
    XCTAssertThrowsError(try KeychainToken.token(fromSecret: "not json")) { error in
      guard case UsageError.notSignedIn = error else { return XCTFail("expected notSignedIn, got \(error)") }
    }
  }
}

// MARK: - Cold start

@MainActor final class RestoredReadingTests: XCTestCase {
  private func published(updatedAt: Date?) -> UsageState {
    UsageState(
      writtenAt: Date(), pollIntervalSeconds: 300,
      providers: [
        ProviderUsage(
          provider: "codex", displayName: "Codex", status: "ok", error: nil, updatedAt: updatedAt, rateLimitedUntil: nil,
          metrics: [
            MetricUsage(
              id: "codex:primary", title: "Weekly (7-day)", usedPercent: 41, value: "41%", detail: "41% used", severity: "warning",
              resetsAt: Date(timeIntervalSince1970: 2_000_000))
          ])
      ])
  }

  /// A cold start must show the last known numbers, not a spinner: the guards can defer the
  /// first fetch for minutes, and the reading is already on disk.
  func testLastReadingIsShownBeforeAnyFetch() {
    let updatedAt = Date(timeIntervalSinceNow: -600)
    let model = UsageModel(
      provider: StubProvider(provider: .codex) { snapshot("codex:primary") }, defaults: makeDefaults(),
      restoring: published(updatedAt: updatedAt))

    XCTAssertTrue(model.snapshot.hasData, "the stored reading should be on screen immediately")
    XCTAssertEqual(model.snapshot.metrics.first?.barText, "41%")
    XCTAssertEqual(model.snapshot.metrics.first?.fraction, 0.41, "percent is stored 0-100 and displayed 0-1")
    XCTAssertEqual(model.snapshot.metrics.first?.severity, .warning, "severity must survive the round trip")
    XCTAssertEqual(model.snapshot.metrics.first?.provider, .codex, "the provider comes back from the namespaced id")
    XCTAssertFalse(model.snapshot.metrics.first?.symbolName.isEmpty ?? true, "a glyph is rebuilt from the id")
    XCTAssertEqual(model.snapshot.updatedAt, updatedAt, "age must be the reading's own, so the footer isn't misleading")
    XCTAssertTrue(model.isStale(), "a ten-minute-old reading should still trigger a top-up")
  }

  /// A reading with no timestamp is not worth showing: the panel would claim data of unknown age.
  func testReadingWithoutATimestampIsIgnored() {
    let model = UsageModel(
      provider: StubProvider(provider: .codex) { snapshot("codex:primary") }, defaults: makeDefaults(), restoring: published(updatedAt: nil)
    )
    XCTAssertFalse(model.snapshot.hasData)
  }

  /// Another provider's reading must not be adopted.
  func testOnlyTheMatchingProviderIsRestored() {
    let model = UsageModel(
      provider: StubProvider(provider: .claude) { snapshot("claude:session") }, defaults: makeDefaults(),
      restoring: published(updatedAt: Date()))
    XCTAssertFalse(model.snapshot.hasData, "a Codex reading must not appear under Claude")
  }
}

// MARK: - Update checking

@MainActor final class UpdateCheckerTests: XCTestCase {
  /// Three-part versions must order numerically, not lexically: the whole point of the check is
  /// noticing 0.1.2 while running 0.1.1, and "0.1.10" must beat "0.1.9" rather than lose to it.
  func testVersionOrdering() {
    XCTAssertTrue(UpdateChecker.isNewer("0.1.2", than: "0.1.1"))
    XCTAssertTrue(UpdateChecker.isNewer("0.1.10", than: "0.1.9"))
    XCTAssertTrue(UpdateChecker.isNewer("0.2.0", than: "0.1.99"))
    XCTAssertTrue(UpdateChecker.isNewer("1.0.0", than: "0.9.9"))
    XCTAssertFalse(UpdateChecker.isNewer("0.1.1", than: "0.1.1"))
    XCTAssertFalse(UpdateChecker.isNewer("0.1.1", than: "0.1.2"))
    // A shorter version is the same as one zero-padded, so neither direction is "newer".
    XCTAssertFalse(UpdateChecker.isNewer("0.1", than: "0.1.0"))
    XCTAssertFalse(UpdateChecker.isNewer("0.1.0", than: "0.1"))
  }

  /// A recorded check must suppress the next request for the whole gap; without this the panel
  /// trigger would fire a request on every click.
  func testRecentCheckIsSkipped() async {
    let defaults = makeDefaults()
    defaults.set(Date(), forKey: "lastUpdateCheck")
    defaults.set("0.9.9", forKey: "latestKnownVersion")
    let checker = UpdateChecker(defaults: defaults)

    await checker.check()
    XCTAssertEqual(checker.latestVersion, "0.9.9", "a skipped check must not disturb the cached answer")
  }

  /// With no record of a previous check, the first one has to run.
  func testFirstCheckIsDue() { XCTAssertTrue(UpdateChecker(defaults: makeDefaults()).isDue) }

  /// A check that just happened must suppress the next one, or the panel trigger would fire a
  /// request on every click.
  func testRecentCheckIsNotDue() {
    let defaults = makeDefaults()
    defaults.set(Date(), forKey: "lastUpdateCheck")
    XCTAssertFalse(UpdateChecker(defaults: defaults).isDue)
  }

  /// The cached answer has to be readable before any network call completes, or the panel shows
  /// nothing on launch even when an update is already known.
  func testCachedVersionIsRestoredAtInit() {
    let defaults = makeDefaults()
    defaults.set("1.2.3", forKey: "latestKnownVersion")
    XCTAssertEqual(UpdateChecker(defaults: defaults).latestVersion, "1.2.3")
  }
}

// MARK: - 2. Backoff persistence · 4. Retry-After as a strict lower bound

@MainActor final class BackoffTests: XCTestCase {
  /// An auth failure must survive stop/start. A backoff held only in the polling task's sleep
  /// is lost when the loop restarts, falling back to the 120s minimum gap.
  func testAuthBackoffSurvivesStopStart() async {
    let defaults = makeDefaults()
    let provider = StubProvider(provider: .codex) { throw UsageError.notSignedIn }
    let model = UsageModel(provider: provider, defaults: defaults)

    let first = await model.refresh(trigger: "test")
    XCTAssertGreaterThan(first, 10 * 60, "missing credentials should hold off ~15 minutes")

    // Simulate stop/start: the very next attempt must be refused, not retried.
    model.stop()
    model.start()
    let second = await model.refresh(trigger: "after-restart")
    XCTAssertGreaterThan(second, 10 * 60, "restarting the loop must not discard the auth backoff")
  }

  /// A rejected token is usually one the CLI has just rotated, so the first rejection must come
  /// back quickly rather than parking the provider for a quarter of an hour. A rejection that
  /// repeats does need a sign-in, so it must then settle onto the long interval.
  func testRejectedTokenRetriesSoonThenSettles() async {
    let defaults = makeDefaults()
    let provider = StubProvider(provider: .codex) { throw UsageError.sessionExpired }

    let first = await UsageModel(provider: provider, defaults: defaults).refresh(trigger: "test")
    XCTAssertGreaterThan(first, 120, "must exceed the minimum gap, or the retry is skipped instead of attempted")
    XCTAssertLessThan(first, 5 * 60, "a rotated token should be picked up within minutes")

    // Let the first deadline lapse. A fresh model is what a relaunch looks like, and it restores
    // the stored failure count, so this stands in for the second consecutive rejection.
    defaults.set(Date().addingTimeInterval(-1), forKey: "nextAttemptAt.codex")
    defaults.set(Date().addingTimeInterval(-10 * 60), forKey: "lastAttemptAt.codex")
    let second = await UsageModel(provider: provider, defaults: defaults).refresh(trigger: "retry")
    XCTAssertGreaterThan(second, 10 * 60, "a token that stays rejected needs a sign-in, so stop retrying quickly")
  }

  /// The same, across a relaunch: a fresh model reading the same defaults must still hold off.
  func testBackoffSurvivesRelaunch() async {
    let defaults = makeDefaults()
    let failing = StubProvider(provider: .codex) { throw UsageError.badResponse }
    let first = UsageModel(provider: failing, defaults: defaults)
    let wait = await first.refresh(trigger: "test")
    XCTAssertGreaterThan(wait, 30, "a general failure should back off at least a minute-ish")

    // A brand-new model is what a relaunch looks like. It must honour the stored deadline
    // even though the 120s minimum gap alone would have allowed a retry much sooner.
    let relaunched = UsageModel(provider: failing, defaults: defaults)
    let afterRelaunch = await relaunched.refresh(trigger: "relaunch")
    XCTAssertGreaterThan(afterRelaunch, 30, "a relaunch must not discard a backoff that is still in force")
  }

  /// Upgrading mid-throttle: an older build persisted only `rateLimitedUntil.<provider>`.
  /// That deadline must still be honoured, not bypassed after the 120s minimum gap.
  func testLegacyRateLimitDeadlineIsHonouredAfterUpgrade() async {
    let defaults = makeDefaults()
    let future = Date().addingTimeInterval(45 * 60)
    defaults.set(future, forKey: "rateLimitedUntil.codex")  // only the legacy key

    let fetched = Flag()
    let provider = StubProvider(provider: .codex) {
      fetched.set()
      return snapshot("codex:primary")
    }
    let model = UsageModel(provider: provider, defaults: defaults)
    let wait = await model.refresh(trigger: "after-upgrade")

    XCTAssertFalse(fetched.isSet, "must not fetch while a legacy 429 deadline is still in force")
    XCTAssertGreaterThan(wait, 30 * 60, "should wait out the stored deadline")
    XCTAssertNotNil(defaults.object(forKey: "nextAttemptAt.codex"), "the legacy deadline should be migrated forward")
  }

  /// Replacing rejected credentials must end the hold they caused. Without this the panel tells
  /// you to refresh the CLI and then ignores the result for the rest of the interval.
  func testReplacedCredentialsEndTheAuthHold() async {
    let defaults = makeDefaults()
    let credentials = Box("token-a")
    let reject = Box(true)
    let provider = StubProvider(
      provider: .codex, outcome: { if reject.value { throw UsageError.sessionExpired } else { return snapshot("codex:primary") } },
      credentials: credentials)
    let model = UsageModel(provider: provider, defaults: defaults)

    let held = await model.refresh(trigger: "test")
    XCTAssertGreaterThan(held, 120, "a rejection should hold off")

    // Same credentials: the hold must stand.
    let stillHeld = await model.refresh(trigger: "unchanged")
    XCTAssertGreaterThan(stillHeld, 0)
    XCTAssertNotNil(defaults.object(forKey: "nextAttemptAt.codex"), "an unchanged token must not clear the hold")

    // The CLI writes a new token: the next attempt must go through and succeed.
    credentials.value = "token-b"
    reject.value = false
    let afterRefresh = await model.refresh(trigger: "after-cli-refresh")
    XCTAssertGreaterThan(afterRefresh, 60, "a success returns the normal poll interval")
    XCTAssertNil(defaults.object(forKey: "nextAttemptAt.codex"), "replaced credentials should have cleared the hold")
  }

  /// A 429 is the server asking for quiet, not a credential problem, so new credentials must
  /// not be treated as licence to retry early.
  func testReplacedCredentialsDoNotCutShortARateLimitHold() async {
    let defaults = makeDefaults()
    let credentials = Box("token-a")
    let provider = StubProvider(provider: .codex, outcome: { throw UsageError.rateLimited(retryAfter: 3600) }, credentials: credentials)
    let model = UsageModel(provider: provider, defaults: defaults)

    let held = await model.refresh(trigger: "test")
    XCTAssertGreaterThan(held, 30 * 60, "a 429 with retry-after should hold for the hour")

    credentials.value = "token-b"
    let afterRefresh = await model.refresh(trigger: "after-cli-refresh")
    XCTAssertGreaterThan(afterRefresh, 30 * 60, "new credentials must not shorten a rate-limit hold")
  }

  func testSuccessClearsBackoff() async {
    let defaults = makeDefaults()
    let model = UsageModel(provider: StubProvider(provider: .codex) { snapshot("codex:primary") }, defaults: defaults)
    let wait = await model.refresh(trigger: "test")
    XCTAssertGreaterThan(wait, 60, "a success returns the normal poll interval")
    XCTAssertNil(defaults.object(forKey: "nextAttemptAt.codex"))
    XCTAssertNil(model.rateLimitedUntil)
  }

  /// Retry-After is a hard floor: jitter must never schedule earlier than the server asked.
  func testRetryAfterIsAStrictLowerBound() async {
    let retryAfter: TimeInterval = 3600  // above the local floor, so jitter is the only risk
    for _ in 0..<200 {
      let defaults = makeDefaults()
      let provider = StubProvider(provider: .codex) { throw UsageError.rateLimited(retryAfter: retryAfter) }
      let model = UsageModel(provider: provider, defaults: defaults)
      let wait = await model.refresh(trigger: "test")
      XCTAssertGreaterThanOrEqual(wait, retryAfter, "never retry before the server's Retry-After")
    }
  }

  func testRateLimitUsesLocalFloorWhenServerAsksForLess() async {
    let defaults = makeDefaults()
    let provider = StubProvider(provider: .codex) { throw UsageError.rateLimited(retryAfter: 1) }
    let model = UsageModel(provider: provider, defaults: defaults)
    let wait = await model.refresh(trigger: "test")
    XCTAssertGreaterThan(wait, 10 * 60, "a tiny Retry-After must not defeat the local floor")
    XCTAssertNotNil(model.rateLimitedUntil)
  }
}

// MARK: - 3. Codex subprocess timeout and cancellation

/// A real hanging child. `/bin/sleep` was useless here: `CodexExchange` always appends
/// `app-server`, so `sleep app-server` died instantly with "invalid time interval" and the
/// tests passed without ever reaching the watchdog or the cancellation path.
private struct HangingFixture {
  let url: URL
  /// Unique, so `pgrep -f` can prove the child is gone afterwards.
  var marker: String { url.lastPathComponent }

  init() throws {
    url = FileManager.default.temporaryDirectory.appendingPathComponent("tokenration-hang-\(UUID().uuidString).sh")
    // Ignores its arguments and stdin, and stays alive until signalled.
    try "#!/bin/sh\nwhile :; do sleep 0.2; done\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  }

  func cleanUp() { try? FileManager.default.removeItem(at: url) }

  /// How many live processes still match this fixture.
  func liveProcessCount() -> Int {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-f", marker]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return -1 }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""
    return text.split(separator: "\n").filter { !$0.isEmpty }.count
  }

  /// pgrep also matches this test process's own argv in some setups; poll for it to settle.
  func waitForExit(timeout: TimeInterval = 5) -> Int {
    let deadline = Date().addingTimeInterval(timeout)
    var count = liveProcessCount()
    while count > 0, Date() < deadline {
      usleep(100_000)
      count = liveProcessCount()
    }
    return count
  }
}

final class CodexTimeoutTests: XCTestCase {
  /// A child that never writes must hit the watchdog — and be terminated by it.
  func testHangingSubprocessTimesOutAndIsTerminated() async throws {
    let fixture = try HangingFixture()
    defer { fixture.cleanUp() }
    let timeout: TimeInterval = 2

    let started = Date()
    do {
      _ = try await CodexUsageProvider.readRateLimits(binary: fixture.url.path, timeout: timeout)
      XCTFail("a hanging child must not return a result")
    } catch {
      let elapsed = Date().timeIntervalSince(started)
      // Proves the watchdog fired rather than the child dying on its own.
      XCTAssertGreaterThanOrEqual(elapsed, timeout - 0.5, "should have waited for the watchdog")
      XCTAssertLessThan(elapsed, timeout + 8, "must not block indefinitely")
      if case UsageError.badResponse = error {} else { XCTFail("expected a badResponse timeout, got \(error)") }
    }
    XCTAssertEqual(fixture.waitForExit(), 0, "the child must be terminated on timeout")
  }

  /// Cancelling must unblock immediately and tear the child down.
  func testCancellationTerminatesTheChild() async throws {
    let fixture = try HangingFixture()
    defer { fixture.cleanUp() }

    let task = Task { try await CodexUsageProvider.readRateLimits(binary: fixture.url.path, timeout: 120) }
    // Let it actually launch, so cancellation races a live process.
    try await Task.sleep(for: .milliseconds(400))
    let started = Date()
    task.cancel()

    do {
      _ = try await task.value
      XCTFail("cancellation should surface an error")
    } catch { XCTAssertLessThan(Date().timeIntervalSince(started), 10, "cancellation must not wait out the 120s timeout") }
    XCTAssertEqual(fixture.waitForExit(), 0, "the child must be terminated on cancellation")
  }

  /// Cancelling during launch must not leak an unmonitored child.
  func testCancellationDuringLaunchDoesNotLeak() async throws {
    let fixture = try HangingFixture()
    defer { fixture.cleanUp() }

    let task = Task { try await CodexUsageProvider.readRateLimits(binary: fixture.url.path, timeout: 120) }
    // Cancel immediately, so it lands while `process.run()` is in flight.
    task.cancel()
    _ = try? await task.value
    XCTAssertEqual(fixture.waitForExit(), 0, "a child launched as cancellation landed must still be reaped")
  }

  /// A child that exits without answering resolves via EOF, not the watchdog.
  func testProcessExitingWithoutAnswerFailsPromptly() async {
    let started = Date()
    _ = try? await CodexUsageProvider.readRateLimits(binary: "/usr/bin/true", timeout: 30)
    XCTAssertLessThan(Date().timeIntervalSince(started), 10, "EOF should resolve the exchange without waiting for the timeout")
  }
}

// MARK: - 5. MCP freshness reflects the provider reading, not the file

final class FreshnessTests: XCTestCase {
  private func provider(updatedAt: Date?) -> ProviderUsage {
    ProviderUsage(
      provider: "claude", displayName: "Claude", status: "ok", error: nil, updatedAt: updatedAt, rateLimitedUntil: nil, metrics: [])
  }

  /// The app rewrites the file on refresh starts, errors and connectivity changes, so a
  /// just-written file can still hold an old reading. Age must come from `updatedAt`.
  func testAgeComesFromTheProviderReadingNotTheFile() {
    let now = Date()
    let old = provider(updatedAt: now.addingTimeInterval(-3600))
    let state = UsageState(writtenAt: now, pollIntervalSeconds: 300, providers: [old])

    XCTAssertEqual(old.readingAge(now: now) ?? 0, 3600, accuracy: 2)
    XCTAssertTrue(
      old.isStale(pollIntervalSeconds: state.pollIntervalSeconds, now: now),
      "an hour-old reading is stale even though the file was just written")
  }

  func testFreshReadingIsNotStale() {
    let now = Date()
    let fresh = provider(updatedAt: now.addingTimeInterval(-30))
    XCTAssertFalse(fresh.isStale(pollIntervalSeconds: 300, now: now))
  }

  func testProviderWithNoReadingCountsAsStale() {
    let never = provider(updatedAt: nil)
    XCTAssertNil(never.readingAge())
    XCTAssertTrue(never.isStale(pollIntervalSeconds: 300), "a provider that has never produced a reading must not look fresh")
  }

  func testStateRoundTripsThroughJSON() throws {
    let now = Date()
    let state = UsageState(writtenAt: now, pollIntervalSeconds: 300, providers: [provider(updatedAt: now)])
    let data = try UsageStateStore.makeEncoder().encode(state)
    let decoded = try UsageStateStore.makeDecoder().decode(UsageState.self, from: data)
    XCTAssertEqual(decoded.providers.count, 1)
    XCTAssertEqual(decoded.pollIntervalSeconds, 300)
    XCTAssertEqual(decoded.providers[0].updatedAt?.timeIntervalSince1970 ?? 0, now.timeIntervalSince1970, accuracy: 1)
  }
}
