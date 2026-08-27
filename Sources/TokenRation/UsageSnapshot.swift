import Foundation

/// How close a metric is to its limit. Drives the menu-bar tint — and only when it is
/// *not* normal, so the common case stays a fully theme-adaptive template icon.
enum Severity: Sendable {
  case normal, warning, critical

  /// Stable string used in the published state file.
  var name: String {
    switch self {
    case .normal: "normal"
    case .warning: "warning"
    case .critical: "critical"
    }
  }

  init(apiValue: String?) {
    switch apiValue?.lowercased() {
    case "warning", "warn", "approaching": self = .warning
    case "critical", "exceeded", "depleted", "over": self = .critical
    default: self = .normal
    }
  }
}

/// One thing shown to the user: a rate-limit window (Session / Weekly / per-model) or the
/// extra-usage spend. The AppKit layer renders entirely from these value types, so it
/// never touches the API's JSON shape.
struct DisplayMetric: Identifiable, Sendable, Equatable {
  /// Stable, provider-namespaced key — e.g. `claude:session`, `codex:model:bengalfox`.
  /// Preferences remember which ids are pinned to the menu bar.
  let id: String
  /// Which usage source this came from.
  let provider: Provider
  /// Full name for the dropdown, e.g. "Session (5-hour)".
  var title: String
  /// SF Symbol name; always rendered as a template image so it adapts to light/dark.
  var symbolName: String
  /// Compact text for the menu bar, e.g. "22%" or "$246".
  var barText: String
  /// Value text for the dropdown, e.g. "22% used" or "$246.40 / $1,000.00 · 25%".
  var valueText: String
  /// 0...1 fill, when meaningful.
  var fraction: Double?
  var severity: Severity
  /// When this window resets, if it has one (spend does not).
  var resetsAt: Date?
}

/// A full reading: every metric plus when it was fetched.
extension DisplayMetric {
  /// SF Symbol for a metric known only by its namespaced id (e.g. `codex:model:bengalfox`) —
  /// used when a pinned metric has no reading yet, and when rebuilding a stored one.
  static func symbolName(for id: String) -> String {
    let parts = id.split(separator: ":", maxSplits: 1)
    guard parts.count == 2, let provider = Provider(rawValue: String(parts[0])) else { return "gauge.with.dots.needle.bottom.50percent" }
    let suffix = String(parts[1])
    let kind: MetricKind
    switch suffix {
    case "session", "secondary": kind = .session
    case "weekly", "primary": kind = .window
    case "spend", "credits": kind = .money
    default: kind = suffix.hasPrefix("model:") ? .model : .window
    }
    return provider.symbol(for: kind)
  }
}

struct UsageSnapshot: Sendable, Equatable {
  var metrics: [DisplayMetric]
  var updatedAt: Date

  static let placeholder = UsageSnapshot(metrics: [], updatedAt: .distantPast)

  var hasData: Bool { updatedAt != .distantPast && !metrics.isEmpty }

  func metric(id: String) -> DisplayMetric? { metrics.first { $0.id == id } }
}

/// Short "1h 19m"-style countdown, shared by the menu-bar icon and the popover so the two always
/// agree. `RelativeDateTimeFormatter` is unsuitable here: it rounds to a single unit ("1 hr"),
/// hiding the minutes.
enum ResetText {
  static func short(until date: Date) -> String {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.day, .hour, .minute]
    formatter.unitsStyle = .abbreviated
    formatter.maximumUnitCount = 2
    return formatter.string(from: max(date.timeIntervalSinceNow, 0)) ?? ""
  }
}
