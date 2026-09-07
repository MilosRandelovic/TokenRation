import Foundation

/// The human-readable rendering of a published reading, so the text a caller quotes and the JSON
/// it can parse describe the same state.
public enum UsageSummary {
  /// One line per provider: any warning first, then the metrics, then the reading's age.
  ///
  /// The warning leads deliberately. Callers are told to report this summary rather than the
  /// payload beside it, so a status placed after the percentages is a status that gets dropped —
  /// which is how an expired session came to be reported as hours-old numbers that read as
  /// current. The last known metrics still follow, because they are usually what was wanted.
  public static func text(for state: UsageState, now: Date = Date()) -> String {
    state.providers.map { line(for: $0, pollIntervalSeconds: state.pollIntervalSeconds, now: now) }.joined(separator: "\n")
  }

  private static func line(for provider: ProviderUsage, pollIntervalSeconds: Int, now: Date) -> String {
    var warnings: [String] = []
    if provider.status != "ok" { warnings.append(provider.error.map { "\(provider.status): \($0)" } ?? provider.status) }
    if provider.isStale(pollIntervalSeconds: pollIntervalSeconds, now: now) { warnings.append("stale reading") }

    var parts: [String] = []
    if !warnings.isEmpty { parts.append("⚠ " + warnings.joined(separator: " · ")) }
    let metrics = provider.metrics.map { metric -> String in
      let reset = metric.resetsAt.map { " (resets in \(shortDuration($0.timeIntervalSince(now))))" } ?? ""
      return "\(metric.title) \(metric.value)\(reset)"
    }
    if metrics.isEmpty {
      // A provider with nothing to show and nothing wrong still has to say something.
      if warnings.isEmpty { parts.append(provider.status) }
    } else {
      parts.append(metrics.joined(separator: ", "))
    }

    // Age is reported per provider — one can be hours old while the other just refreshed.
    let age = provider.readingAge(now: now).map { "reading \(ageText($0)) old" } ?? "no reading yet"
    return "\(provider.displayName): \(parts.joined(separator: " · ")) — \(age)"
  }

  /// Seconds while a reading is fresh enough to think of in seconds, coarser once it is not.
  private static func ageText(_ seconds: TimeInterval) -> String { seconds < 120 ? "\(Int(seconds))s" : shortDuration(seconds) }

  static func shortDuration(_ seconds: TimeInterval) -> String {
    let total = max(Int(seconds), 0)
    let days = total / 86400, hours = (total % 86400) / 3600, minutes = (total % 3600) / 60
    if days > 0 { return "\(days)d \(hours)h" }
    if hours > 0 { return "\(hours)h \(minutes)m" }
    return "\(minutes)m"
  }
}
