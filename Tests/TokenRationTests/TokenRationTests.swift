import Foundation
import XCTest
import UsageState
@testable import TokenRation

/// A provider stub that returns whatever the test asks for, and counts calls.
private struct StubProvider: UsageProviding {
    let provider: Provider
    let outcome: @Sendable () throws -> UsageSnapshot

    func fetch() async throws -> UsageSnapshot { try outcome() }
}

/// Mutable flag usable from a `@Sendable` closure.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

private func makeDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private func snapshot(_ id: String) -> UsageSnapshot {
    UsageSnapshot(metrics: [
        DisplayMetric(id: id, provider: .codex, title: "T", symbolName: "clock",
                      barText: "1%", valueText: "1% used", fraction: 0.01,
                      severity: .normal, resetsAt: nil),
    ], updatedAt: Date())
}

// MARK: - 1. Codex-only installs / unavailable pins

@MainActor
final class PreferencesTests: XCTestCase {
    func testCodexOnlyMachineDefaultsToACodexPin() {
        let prefs = Preferences(available: [.codex], defaults: makeDefaults())
        XCTAssertEqual(prefs.shownMetricIDs, ["codex:primary"])
        XCTAssertFalse(prefs.shownMetricIDs.contains { $0.hasPrefix("claude:") },
                       "a Codex-only Mac must not pin an unpinnable Claude placeholder")
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

@MainActor
final class PinReconciliationTests: XCTestCase {
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
        XCTAssertEqual(prefs.shownMetricIDs, ["codex:primary"],
                       "reconciling must never leave the menu bar with nothing pinned")
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

// MARK: - 2. Backoff persistence · 4. Retry-After as a strict lower bound

@MainActor
final class BackoffTests: XCTestCase {
    /// An auth failure must survive stop/start — it used to live only as a sleep in the task,
    /// so a sleep/wake cycle fell back to the 120s minimum gap.
    func testAuthBackoffSurvivesStopStart() async {
        let defaults = makeDefaults()
        let provider = StubProvider(provider: .codex) { throw UsageError.sessionExpired }
        let model = UsageModel(provider: provider, defaults: defaults)

        let first = await model.refresh(trigger: "test")
        XCTAssertGreaterThan(first, 10 * 60, "auth failures should hold off ~15 minutes")

        // Simulate stop/start: the very next attempt must be refused, not retried.
        model.stop()
        model.start()
        let second = await model.refresh(trigger: "after-restart")
        XCTAssertGreaterThan(second, 10 * 60,
                             "restarting the loop must not discard the auth backoff")
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
        XCTAssertGreaterThan(afterRelaunch, 30,
                             "a relaunch must not discard a backoff that is still in force")
    }

    /// Upgrading mid-throttle: an older build persisted only `rateLimitedUntil.<provider>`.
    /// That deadline must still be honoured, not bypassed after the 120s minimum gap.
    func testLegacyRateLimitDeadlineIsHonouredAfterUpgrade() async {
        let defaults = makeDefaults()
        let future = Date().addingTimeInterval(45 * 60)
        defaults.set(future, forKey: "rateLimitedUntil.codex")   // only the legacy key

        let fetched = Flag()
        let provider = StubProvider(provider: .codex) {
            fetched.set()
            return snapshot("codex:primary")
        }
        let model = UsageModel(provider: provider, defaults: defaults)
        let wait = await model.refresh(trigger: "after-upgrade")

        XCTAssertFalse(fetched.isSet,
                       "must not fetch while a legacy 429 deadline is still in force")
        XCTAssertGreaterThan(wait, 30 * 60, "should wait out the stored deadline")
        XCTAssertNotNil(defaults.object(forKey: "nextAttemptAt.codex"),
                        "the legacy deadline should be migrated forward")
    }

    func testSuccessClearsBackoff() async {
        let defaults = makeDefaults()
        let model = UsageModel(provider: StubProvider(provider: .codex) { snapshot("codex:primary") },
                               defaults: defaults)
        let wait = await model.refresh(trigger: "test")
        XCTAssertGreaterThan(wait, 60, "a success returns the normal poll interval")
        XCTAssertNil(defaults.object(forKey: "nextAttemptAt.codex"))
        XCTAssertNil(model.rateLimitedUntil)
    }

    /// Retry-After is a hard floor: jitter must never schedule earlier than the server asked.
    func testRetryAfterIsAStrictLowerBound() async {
        let retryAfter: TimeInterval = 3600   // above the local floor, so jitter is the only risk
        for _ in 0..<200 {
            let defaults = makeDefaults()
            let provider = StubProvider(provider: .codex) {
                throw UsageError.rateLimited(retryAfter: retryAfter)
            }
            let model = UsageModel(provider: provider, defaults: defaults)
            let wait = await model.refresh(trigger: "test")
            XCTAssertGreaterThanOrEqual(wait, retryAfter,
                                        "never retry before the server's Retry-After")
        }
    }

    func testRateLimitUsesLocalFloorWhenServerAsksForLess() async {
        let defaults = makeDefaults()
        let provider = StubProvider(provider: .codex) {
            throw UsageError.rateLimited(retryAfter: 1)
        }
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
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenration-hang-\(UUID().uuidString).sh")
        // Ignores its arguments and stdin, and stays alive until signalled.
        try "#!/bin/sh\nwhile :; do sleep 0.2; done\n"
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: url.path)
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
            _ = try await CodexUsageProvider.readRateLimits(binary: fixture.url.path,
                                                            timeout: timeout)
            XCTFail("a hanging child must not return a result")
        } catch {
            let elapsed = Date().timeIntervalSince(started)
            // Proves the watchdog fired rather than the child dying on its own.
            XCTAssertGreaterThanOrEqual(elapsed, timeout - 0.5,
                                        "should have waited for the watchdog")
            XCTAssertLessThan(elapsed, timeout + 8, "must not block indefinitely")
            if case UsageError.badResponse = error {} else {
                XCTFail("expected a badResponse timeout, got \(error)")
            }
        }
        XCTAssertEqual(fixture.waitForExit(), 0, "the child must be terminated on timeout")
    }

    /// Cancelling must unblock immediately and tear the child down.
    func testCancellationTerminatesTheChild() async throws {
        let fixture = try HangingFixture()
        defer { fixture.cleanUp() }

        let task = Task {
            try await CodexUsageProvider.readRateLimits(binary: fixture.url.path, timeout: 120)
        }
        // Let it actually launch, so cancellation races a live process.
        try await Task.sleep(for: .milliseconds(400))
        let started = Date()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("cancellation should surface an error")
        } catch {
            XCTAssertLessThan(Date().timeIntervalSince(started), 10,
                              "cancellation must not wait out the 120s timeout")
        }
        XCTAssertEqual(fixture.waitForExit(), 0, "the child must be terminated on cancellation")
    }

    /// Cancelling during launch must not leak an unmonitored child.
    func testCancellationDuringLaunchDoesNotLeak() async throws {
        let fixture = try HangingFixture()
        defer { fixture.cleanUp() }

        let task = Task {
            try await CodexUsageProvider.readRateLimits(binary: fixture.url.path, timeout: 120)
        }
        // Cancel immediately, so it lands while `process.run()` is in flight.
        task.cancel()
        _ = try? await task.value
        XCTAssertEqual(fixture.waitForExit(), 0,
                       "a child launched as cancellation landed must still be reaped")
    }

    /// A child that exits without answering resolves via EOF, not the watchdog.
    func testProcessExitingWithoutAnswerFailsPromptly() async {
        let started = Date()
        _ = try? await CodexUsageProvider.readRateLimits(binary: "/usr/bin/true", timeout: 30)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10,
                          "EOF should resolve the exchange without waiting for the timeout")
    }
}

// MARK: - 5. MCP freshness reflects the provider reading, not the file

final class FreshnessTests: XCTestCase {
    private func provider(updatedAt: Date?) -> ProviderUsage {
        ProviderUsage(provider: "claude", displayName: "Claude", status: "ok", error: nil,
                      updatedAt: updatedAt, rateLimitedUntil: nil, metrics: [])
    }

    /// The app rewrites the file on refresh starts, errors and connectivity changes, so a
    /// just-written file can still hold an old reading. Age must come from `updatedAt`.
    func testAgeComesFromTheProviderReadingNotTheFile() {
        let now = Date()
        let old = provider(updatedAt: now.addingTimeInterval(-3600))
        let state = UsageState(writtenAt: now, pollIntervalSeconds: 300, providers: [old])

        XCTAssertEqual(old.readingAge(now: now) ?? 0, 3600, accuracy: 2)
        XCTAssertTrue(old.isStale(pollIntervalSeconds: state.pollIntervalSeconds, now: now),
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
        XCTAssertTrue(never.isStale(pollIntervalSeconds: 300),
                      "a provider that has never produced a reading must not look fresh")
    }

    func testStateRoundTripsThroughJSON() throws {
        let now = Date()
        let state = UsageState(writtenAt: now, pollIntervalSeconds: 300,
                               providers: [provider(updatedAt: now)])
        let data = try UsageStateStore.makeEncoder().encode(state)
        let decoded = try UsageStateStore.makeDecoder().decode(UsageState.self, from: data)
        XCTAssertEqual(decoded.providers.count, 1)
        XCTAssertEqual(decoded.pollIntervalSeconds, 300)
        XCTAssertEqual(decoded.providers[0].updatedAt?.timeIntervalSince1970 ?? 0,
                       now.timeIntervalSince1970, accuracy: 1)
    }
}
