import Foundation

/// Reads Codex usage by speaking JSON-RPC to `codex app-server` over stdio and calling
/// `account/rateLimits/read`.
///
/// Why a subprocess rather than HTTP: the ChatGPT backend (`/backend-api/codex/usage`) sits
/// behind bot protection that rejects non-client callers with a 403 HTML page, even with the
/// right bearer token and headers. The local `codex` binary is the trusted client, so going
/// through it needs no credential handling of our own and consumes no model quota.
struct CodexUsageProvider: UsageProviding {
  let provider = Provider.codex

  /// Hard ceiling for the whole exchange — spawn, initialize, query, parse.
  var timeout: TimeInterval = 20

  func fetch() async throws -> UsageSnapshot {
    guard let binary = CodexBinary.resolve() else { throw UsageError.notSignedIn }
    let payload = try await Self.readRateLimits(binary: binary, timeout: timeout)
    let metrics = Self.metrics(from: payload)
    guard !metrics.isEmpty else { throw UsageError.badResponse }
    return UsageSnapshot(metrics: metrics, updatedAt: Date())
  }

  // MARK: - JSON-RPC exchange

  /// Internal (not private) so tests can drive the timeout/cancellation paths directly.
  static func readRateLimits(binary: String, timeout: TimeInterval) async throws -> RateLimitsResult {
    let exchange = CodexExchange(binary: binary)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in exchange.start(timeout: timeout, continuation: continuation) }
    } onCancel: {
      exchange.finish(.failure(CancellationError()))
    }
  }

  // MARK: - Wire format

  struct Envelope: Decodable {
    let id: Int?
    let result: RateLimitsResult?
  }

  struct RateLimitsResult: Decodable, Sendable {
    let rateLimits: Bucket?
    let rateLimitsByLimitId: [String: Bucket]?
  }

  struct Bucket: Decodable, Sendable {
    let limitId: String?
    let limitName: String?
    let primary: Window?
    let secondary: Window?
    let credits: Credits?

    struct Window: Decodable, Sendable {
      let usedPercent: Double?
      let windowDurationMins: Int?
      /// Unix epoch seconds.
      let resetsAt: Double?
    }

    struct Credits: Decodable, Sendable {
      let hasCredits: Bool?
      let unlimited: Bool?
      let balance: String?
    }
  }

  // MARK: - Mapping

  static func metrics(from result: RateLimitsResult) -> [DisplayMetric] {
    var metrics: [DisplayMetric] = []
    let provider = Provider.codex

    if let main = result.rateLimits {
      // Which slot holds which window is a property of the plan, not of the protocol: some plans
      // put a short window in `primary`, some in `secondary`, and some have no short window at
      // all. Role and order therefore come from each window's own duration — shortest first, so a
      // short limit reads above the weekly one, as Claude's session row does.
      let slots = [(main.secondary, provider.metricID("secondary")), (main.primary, provider.metricID("primary"))]
      let present = slots.compactMap { slot -> (Bucket.Window, String)? in slot.0.map { ($0, slot.1) } }.sorted {
        ($0.0.windowDurationMins ?? .max) < ($1.0.windowDurationMins ?? .max)
      }
      for (limit, id) in present { metrics.append(window(limit, id: id, kind: kind(for: limit), title: label(for: limit))) }
      // Only show credits when the account actually has a balance to track.
      if let credits = main.credits, credits.hasCredits == true, let balance = credits.balance {
        metrics.append(
          DisplayMetric(
            id: provider.metricID("credits"), provider: provider, title: "Credits", symbolName: provider.symbol(for: .money),
            barText: credits.unlimited == true ? "∞" : balance, valueText: credits.unlimited == true ? "Unlimited" : "\(balance) remaining",
            fraction: nil, severity: .normal, resetsAt: nil))
      }
    }

    // Per-model buckets. The "codex" entry duplicates `rateLimits`, so skip it.
    let perModel = (result.rateLimitsByLimitId ?? [:]).filter { $0.key != "codex" }.sorted { $0.key < $1.key }
    for (limitID, bucket) in perModel {
      guard let primary = bucket.primary else { continue }
      let name = bucket.limitName ?? limitID
      metrics.append(window(primary, id: provider.metricID("model:\(limitID)"), kind: .model, title: name))
    }
    return metrics
  }

  private static func window(_ window: Bucket.Window, id: String, kind: MetricKind, title: String) -> DisplayMetric {
    let percent = Int((window.usedPercent ?? 0).rounded())
    return DisplayMetric(
      id: id, provider: .codex, title: title, symbolName: Provider.codex.symbol(for: kind), barText: "\(percent)%",
      valueText: "\(percent)% used", fraction: Double(percent) / 100, severity: severity(percent: percent),
      resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: $0) })
  }

  /// Codex reports no severity, so derive it from how much is consumed.
  private static func severity(percent: Int) -> Severity {
    switch percent {
    case ..<50: .normal
    case ..<80: .warning
    default: .critical
    }
  }

  /// Whether a window is a short rolling allowance or a long one, judged by its length rather
  /// than by the slot it arrived in. Anything under a day counts as the short one.
  private static func kind(for window: Bucket.Window) -> MetricKind {
    guard let minutes = window.windowDurationMins, minutes < 1440 else { return .window }
    return .session
  }

  /// Name a window by its duration, e.g. 10080 mins -> "Weekly (7-day)".
  private static func label(for window: Bucket.Window) -> String {
    guard let minutes = window.windowDurationMins else { return "Usage limit" }
    switch minutes {
    case ..<120: return "Session (\(minutes)-minute)"
    case ..<1440: return "Session (\(minutes / 60)-hour)"
    case 10080: return "Weekly (7-day)"
    default: return "Rolling (\(minutes / 1440)-day)"
    }
  }
}

/// Runs one `codex app-server` exchange: spawn, initialize, ask for rate limits, resume.
///
/// Reads are driven by `readabilityHandler` rather than `FileHandle.availableData` in a loop.
/// `availableData` blocks until data or EOF, so a hung `codex app-server` that never writes
/// anything would park the reader forever: the deadline is never re-checked, the continuation
/// never resumes, the child is never reaped, and the provider stays stuck "refreshing".
/// Here a watchdog fires independently of any output, and every exit path terminates and reaps
/// the child exactly once.
private final class CodexExchange: @unchecked Sendable {
  /// Writing to a child that has already exited raises SIGPIPE, which terminates this process
  /// by default instead of returning an error. Ignoring it once turns a dead `codex app-server`
  /// into a failed write that the timeout and EOF paths already handle.
  private static let ignoreBrokenPipes: Void = { signal(SIGPIPE, SIG_IGN) }()

  private let lock = NSLock()
  private let process = Process()
  private let input = Pipe()
  private let output = Pipe()
  private let errors = Pipe()
  private var continuation: CheckedContinuation<CodexUsageProvider.RateLimitsResult, Error>?
  private var buffer = Data()
  private var isFinished = false

  init(binary: String) {
    _ = Self.ignoreBrokenPipes
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = ["app-server"]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
  }

  func start(timeout: TimeInterval, continuation: CheckedContinuation<CodexUsageProvider.RateLimitsResult, Error>) {
    lock.lock()
    guard !isFinished else {
      lock.unlock()
      continuation.resume(throwing: CancellationError())
      return
    }
    self.continuation = continuation
    lock.unlock()

    output.fileHandleForReading.readabilityHandler = { [weak self] handle in
      // Called only when bytes are ready (or at EOF), so this never blocks.
      let chunk = handle.availableData
      guard !chunk.isEmpty else {
        self?.finish(.failure(UsageError.badResponse))  // EOF without an answer
        return
      }
      self?.consume(chunk)
    }
    // Drain stderr so a chatty child can't fill the pipe buffer and deadlock.
    errors.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }

    process.terminationHandler = { [weak self] _ in self?.finish(.failure(UsageError.badResponse)) }

    do { try process.run() } catch {
      finish(.failure(UsageError.notSignedIn))
      return
    }

    // Cancellation can land while `run()` is in flight: `finish` would have seen a process
    // that wasn't running yet and skipped termination, leaving this child unmonitored.
    // Re-check now that it definitely exists, and clean up if cancellation won the race.
    lock.lock()
    let alreadyFinished = isFinished
    lock.unlock()
    if alreadyFinished {
      terminateAndReap()
      return
    }

    send(
      #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"TokenRation","title":"TokenRation","version":"1"}}}"#)
    send(#"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}"#)

    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
      self?.finish(.failure(UsageError.badResponse))
    }
  }

  private func send(_ line: String) {
    guard let data = (line + "\n").data(using: .utf8) else { return }
    try? input.fileHandleForWriting.write(contentsOf: data)
  }

  /// Accumulate newline-delimited JSON and resume on the id=2 reply. The server also emits
  /// unsolicited notifications, so match on id rather than arrival order.
  private func consume(_ chunk: Data) {
    lock.lock()
    buffer.append(chunk)
    var lines: [Data] = []
    while let newline = buffer.firstIndex(of: 0x0A) {
      lines.append(Data(buffer[buffer.startIndex..<newline]))
      buffer.removeSubrange(buffer.startIndex...newline)
    }
    lock.unlock()

    for line in lines {
      guard let envelope = try? JSONDecoder().decode(CodexUsageProvider.Envelope.self, from: line), envelope.id == 2 else { continue }
      if let result = envelope.result { finish(.success(result)) } else { finish(.failure(UsageError.badResponse)) }
      return
    }
  }

  /// Resume the continuation at most once, then tear the child down.
  func finish(_ result: Result<CodexUsageProvider.RateLimitsResult, Error>) {
    lock.lock()
    if isFinished {
      lock.unlock()
      return
    }
    isFinished = true
    let pending = continuation
    continuation = nil
    lock.unlock()

    output.fileHandleForReading.readabilityHandler = nil
    errors.fileHandleForReading.readabilityHandler = nil
    process.terminationHandler = nil
    try? input.fileHandleForWriting.close()

    terminateAndReap()
    pending?.resume(with: result)
  }

  /// Terminate the child if it ever started, and reap it off the caller's thread so a slow
  /// exit can't stall the continuation. Safe to call more than once.
  private func terminateAndReap() {
    guard process.isRunning else { return }
    process.terminate()
    DispatchQueue.global(qos: .utility).async { [process] in process.waitUntilExit() }
  }
}
