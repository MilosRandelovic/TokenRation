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
    guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
      let jsonData = text.data(using: .utf8), let blob = try? JSONDecoder().decode(CredentialsBlob.self, from: jsonData)
    else { throw UsageError.notSignedIn }
    return blob.claudeAiOauth.accessToken
  }

  /// The stored secret is a JSON blob: { "claudeAiOauth": { "accessToken": "..." } }
  private struct CredentialsBlob: Decodable {
    let claudeAiOauth: OAuth
    struct OAuth: Decodable { let accessToken: String }
  }
}
