import Foundation

/// A usage source TokenRation can read. Deliberately a closed set of two — the app is not a
/// general multi-provider framework.
enum Provider: String, CaseIterable, Sendable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    /// Whether this provider looks set up on this Mac. Filesystem checks only — detection must
    /// never prompt for Keychain access or spawn a process.
    var isDetected: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claude:
            // Claude Code's config directory; the token itself lives in the Keychain, which we
            // deliberately don't touch until an actual fetch.
            return FileManager.default.fileExists(
                atPath: home.appendingPathComponent(".claude").path)
        case .codex:
            return FileManager.default.fileExists(
                atPath: home.appendingPathComponent(".codex/auth.json").path)
                && CodexBinary.resolve() != nil
        }
    }

    /// Providers that are set up, in a stable order.
    static var detected: [Provider] {
        allCases.filter(\.isDetected)
    }

    /// Menu-bar/panel glyphs. Each provider uses a **distinct symbol family** for the same
    /// concepts, which is how the menu bar tells them apart: template images are monochrome
    /// (so colour is unavailable), and adding letters or dividers would cost width.
    ///
    ///   Claude — clock · calendar · cpu · dollarsign.circle
    ///   Codex  — hourglass · calendar.badge.clock · cpu.fill · creditcard
    func symbol(for kind: MetricKind) -> String {
        switch (self, kind) {
        case (.claude, .session): "clock"
        case (.claude, .window): "calendar"
        case (.claude, .model): "cpu"
        case (.claude, .money): "dollarsign.circle"
        case (.codex, .session): "hourglass.bottomhalf.filled"
        case (.codex, .window): "hourglass"
        case (.codex, .model): "cpu.fill"
        case (.codex, .money): "creditcard"
        }
    }

    /// Namespaced metric id, e.g. `claude:session`, `codex:model:bengalfox`.
    func metricID(_ suffix: String) -> String {
        "\(rawValue):\(suffix)"
    }

    /// The metric pinned by default for this provider — its tightest headline window.
    var defaultMetricID: String {
        switch self {
        case .claude: metricID("session")
        case .codex: metricID("primary")
        }
    }

    /// The provider a namespaced metric id belongs to, or nil if it isn't one of ours.
    static func owning(metricID: String) -> Provider? {
        guard let prefix = metricID.split(separator: ":").first else { return nil }
        return Provider(rawValue: String(prefix))
    }
}

/// What a metric measures, independent of provider — used to pick the provider's glyph.
enum MetricKind: Sendable {
    /// A short rolling window (Claude's 5-hour, Codex's secondary).
    case session
    /// A longer window (weekly).
    case window
    /// A per-model limit.
    case model
    /// Spend or credits.
    case money
}
