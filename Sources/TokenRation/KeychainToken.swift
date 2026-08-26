import CryptoKit
import Foundation

/// Reads the Claude Code OAuth access token from the login Keychain by invoking
/// `/usr/bin/security`, the same way the Claude Code CLI does.
///
/// Why shell out instead of calling `SecItemCopyMatching` directly: the item
/// "Claude Code-credentials" is owned by Claude Code, so any *other* binary reading it
/// triggers a one-time macOS "allow access" prompt. When the accessor is `/usr/bin/security`
/// (Apple-signed and stable), clicking "Always Allow" once grants access that persists —
/// even across rebuilds of this app, whose own signature would otherwise change. That is
/// what makes it keep "just working" without re-prompting.
///
/// We only read the current token; we never write or refresh it, so we ride Claude Code's
/// own refresh cycle.
enum KeychainToken {
  static func read(service: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = ["find-generic-password", "-s", service, "-w"]
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = Pipe()

    do { try process.run() } catch { throw UsageError.notSignedIn }
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw UsageError.notSignedIn }

    // `security -w` prints the secret plus a trailing newline; trim before parsing.
    guard let text = String(data: data, encoding: .utf8) else { throw UsageError.notSignedIn }
    return try token(fromSecret: text)
  }

  /// A short digest of the current token: enough to tell that it changed, not enough to use.
  static func fingerprint(service: String) throws -> String {
    let token = try read(service: service)
    return SHA256.hash(data: Data(token.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
  }

  /// Pulls the access token out of the stored blob.
  ///
  /// An empty token counts as signed out. The CLI writes the credential back with empty strings
  /// when its refresh token has expired and the refresh fails, and sending `Bearer ` with nothing
  /// after it earns an HTTP 429 rather than a 401 — so without this check the app reads a
  /// throttle where the real answer is "sign in again", and backs off for hours over it.
  static func token(fromSecret text: String) throws -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let jsonData = trimmed.data(using: .utf8), let blob = try? JSONDecoder().decode(CredentialsBlob.self, from: jsonData) else {
      throw UsageError.notSignedIn
    }
    guard !blob.claudeAiOauth.accessToken.isEmpty else { throw UsageError.notSignedIn }
    return blob.claudeAiOauth.accessToken
  }

  /// The stored secret is a JSON blob: { "claudeAiOauth": { "accessToken": "..." } }
  private struct CredentialsBlob: Decodable {
    let claudeAiOauth: OAuth
    struct OAuth: Decodable { let accessToken: String }
  }
}
