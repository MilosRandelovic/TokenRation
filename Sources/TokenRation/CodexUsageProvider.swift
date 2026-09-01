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
    /// Monthly credit cap, on plans that have one. Absent elsewhere.
    let individualLimit: IndividualLimit?
    /// True once a spend control has stopped further usage.
    let spendControlReached: Bool?

    struct Window: Decodable, Sendable {
      let usedPercent: Double?
      let windowDurationMins: Int?
      /// Unix epoch seconds.
      let resetsAt: Double?
    }

    /// A value that may arrive as a string or a number.
    ///
    /// The credit fields are documented as strings, but this projection is not schema-locked
    /// and no account here can produce one to check. A mismatch on a single present field
    /// would fail the whole payload, taking the windows that do work down with it, so both
    /// forms are accepted.
    struct Loose: Decodable, Sendable {
      let text: String?
      let number: Double?

      init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
          text = value
          number = Double(value)
        } else if let value = try? container.decode(Double.self) {
          number = value
          text = nil
        } else {
          text = nil
          number = nil
        }
      }

      /// What to show: the string as given, or the number without trailing noise.
      var display: String? {
        if let text { return text }
        guard let number else { return nil }
        return number == number.rounded() ? String(Int(number)) : String(number)
      }
    }

    /// A monthly credit cap: consumed against a total, with a percentage and a reset.
    struct IndividualLimit: Decodable, Sendable {
      let limit: Loose?
      let used: Loose?
      let remainingPercent: Loose?
      let resetsAt: Loose?
    }

    struct Credits: Decodable, Sendable {
      let hasCredits: Bool?
      let unlimited: Bool?
      let balance: String?
      /// Roughly how many more messages the balance covers, split by where they run.
      let approxLocalMessages: Loose?
      let approxCloudMessages: Loose?
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
      let slots = [main.secondary, main.primary].compactMap { $0 }
      // The id names the role, since the slot it arrived in carries no meaning.
      for limit in slots.sorted(by: { ($0.windowDurationMins ?? .max) < ($1.windowDurationMins ?? .max) }) {
        let role = kind(for: limit)
        metrics.append(window(limit, id: provider.metricID(role == .session ? "session" : "window"), kind: role, title: label(for: limit)))
      }
      // A monthly credit cap behaves like Claude's extra usage: consumed against a total, so
      // it gets a proportion and a reset rather than a bare number.
      if let cap = main.individualLimit, let metric = spend(cap, reached: main.spendControlReached) { metrics.append(metric) }
      // Only show credits when the account actually has a balance to track.
      if let credits = main.credits, credits.hasCredits == true, let balance = credits.balance {
        let unlimited = credits.unlimited == true
        var detail = unlimited ? "Unlimited" : "\(balance) remaining"
        // Approximate message counts say more than a credit figure whose unit is opaque.
        let approximate = [
          credits.approxLocalMessages?.display.map { "~\($0) local" }, credits.approxCloudMessages?.display.map { "~\($0) cloud" },
        ].compactMap { $0 }
        if !approximate.isEmpty { detail += " · " + approximate.joined(separator: ", ") + " msgs" }
        metrics.append(
          DisplayMetric(
            id: provider.metricID("credits"), provider: provider, title: "Credits", symbolName: provider.symbol(for: .money),
            barText: unlimited ? "∞" : balance, valueText: detail, fraction: nil,
            // A balance carries no denominator, so exhaustion can only come from the flag.
            severity: main.spendControlReached == true ? .critical : .normal, resetsAt: nil))
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

  /// A monthly credit cap as a metric. Skipped unless a percentage is present: without one
  /// there is no proportion to draw, and inventing one would misreport spend.
  private static func spend(_ cap: Bucket.IndividualLimit, reached: Bool?) -> DisplayMetric? {
    guard let remaining = cap.remainingPercent?.number else { return nil }
    let used = Int(min(max(100 - remaining, 0), 100).rounded())
    var detail = "\(used)% used"
    if let usedText = cap.used?.display, let limitText = cap.limit?.display { detail = "\(usedText) / \(limitText) · \(used)%" }
    return DisplayMetric(
      id: Provider.codex.metricID("spend"), provider: .codex, title: "Monthly credits", symbolName: Provider.codex.symbol(for: .money),
      barText: "\(used)%", valueText: detail, fraction: Double(used) / 100, severity: reached == true ? .critical : severity(percent: used),
      resetsAt: cap.resetsAt?.number.map { Date(timeIntervalSince1970: $0) })
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
