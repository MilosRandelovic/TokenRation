import Foundation

/// Locates the `codex` executable. It ships inside the ChatGPT app and the VS Code extension
/// rather than being installed on `PATH`, so check the known bundle locations first and fall
/// back to the user's login shell (which picks up Homebrew/npm installs).
enum CodexBinary {
  /// Cached because detection runs on every provider list rebuild.
  private nonisolated(unsafe) static var cached: String??

  static func resolve() -> String? {
    if let cached { return cached }
    let found = search()
    cached = found
    return found
  }

  private static func search() -> String? {
    let manager = FileManager.default
    let home = manager.homeDirectoryForCurrentUser

    var candidates = ["/Applications/ChatGPT.app/Contents/Resources/codex"]

    // VS Code extension: openai.chatgpt-<version>-darwin-<arch>/bin/macos-<arch>/codex
    let extensionsDir = home.appendingPathComponent(".vscode/extensions")
    if let entries = try? manager.contentsOfDirectory(atPath: extensionsDir.path) {
      for entry in entries.sorted().reversed() where entry.hasPrefix("openai.chatgpt-") {
        let base = extensionsDir.appendingPathComponent(entry).appendingPathComponent("bin")
        if let archDirs = try? manager.contentsOfDirectory(atPath: base.path) {
          for arch in archDirs where arch.hasPrefix("macos-") {
            candidates.append(base.appendingPathComponent(arch).appendingPathComponent("codex").path)
          }
        }
      }
    }

    candidates.append(contentsOf: ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"])

    for path in candidates where manager.isExecutableFile(atPath: path) { return path }
    return loginShellLookup()
  }

  /// `zsh -lc "command -v codex"`, so a shell-managed install (nvm, asdf) is still found.
  private static func loginShellLookup() -> String? {
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: shell)
    process.arguments = ["-lc", "command -v codex"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return nil }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0, let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !path.isEmpty, FileManager.default.isExecutableFile(atPath: path)
    else { return nil }
    return path
  }
}
