import Foundation

/// Supplies usage readings for one provider. Implementations run off the main actor, so they
/// must be `Sendable` and return a `Sendable` snapshot.
protocol UsageProviding: Sendable {
  /// Which source this reads — used to namespace persisted state and log lines.
  var provider: Provider { get }
  func fetch() async throws -> UsageSnapshot

  /// A marker for the credentials this provider would use right now — enough to notice they
  /// were replaced, never enough to authenticate with. When credentials are rejected, this is
  /// what a held-off model watches: a new value means the rejection may already be resolved.
  /// `nil` for providers with nothing to fingerprint, which simply never gets an early retry.
  func credentialFingerprint() async -> String?

  /// What is wrong with the credentials this provider needs *right now*, asked of the credential
  /// store rather than inferred from the last attempt, and nil when nothing is. A relaunch restores
  /// the backoff but not the reason for it, and this is checkable rather than remembered — so it is
  /// also correct the moment credentials are fixed while the app is still held off. Reporting the
  /// error rather than a flag lets the panel say which of the two it is.
  func credentialProblem() async -> UsageError?
}

extension UsageProviding {
  func credentialFingerprint() async -> String? { nil }
  /// A provider holding no credentials of its own never reports a problem: Codex defers to its
  /// own CLI, which is signed in or not without this app's involvement.
  func credentialProblem() async -> UsageError? { nil }
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
