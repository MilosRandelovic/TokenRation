import Foundation

/// Supplies usage readings for one provider. Implementations run off the main actor, so they
/// must be `Sendable` and return a `Sendable` snapshot.
protocol UsageProviding: Sendable {
  /// Which source this reads — used to namespace persisted state and log lines.
  var provider: Provider { get }
  func fetch() async throws -> UsageSnapshot
}

/// Failures shared by the Keychain reader and the live provider, phrased for the UI.
enum UsageError: LocalizedError {
  case notSignedIn
  case sessionExpired
  case rateLimited(retryAfter: TimeInterval?)
  case requestFailed(Int)
  case badResponse

  var errorDescription: String? {
    switch self {
    case .notSignedIn: "Not signed in to Claude Code."
    case .sessionExpired: "Session expired — open Claude Code to refresh."
    case .rateLimited: "Rate-limited; retrying soon."
    case .requestFailed(let code): "Usage request failed (HTTP \(code))."
    case .badResponse: "Couldn't read the usage response."
    }
  }
}
