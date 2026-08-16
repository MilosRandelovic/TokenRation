import Foundation

/// Append-only diagnostics log at `~/Library/Logs/TokenRation.log`.
///
/// Every network attempt, skip and outcome is recorded with a timestamp so incidents like
/// unexpected rate limiting can be diagnosed after the fact instead of guessed at. Writes are
/// serialised on a background queue; the file is rotated once past `maxBytes` (one previous
/// generation is kept as `.1`).
enum Log {
  static let fileURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/TokenRation.log")

  private static let maxBytes = 512 * 1024
  private static let queue = DispatchQueue(label: "com.milos.tokenration.log")

  static func write(_ message: String) {
    let url = fileURL
    queue.async {
      let stamp = ISO8601DateFormatter().string(from: Date())
      guard let data = "\(stamp)  \(message)\n".data(using: .utf8) else { return }

      let manager = FileManager.default
      if let size = try? manager.attributesOfItem(atPath: url.path)[.size] as? Int, size > maxBytes {
        let previous = url.appendingPathExtension("1")
        try? manager.removeItem(at: previous)
        try? manager.moveItem(at: url, to: previous)
      }

      if manager.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
      } else {
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
      }
    }
  }
}
