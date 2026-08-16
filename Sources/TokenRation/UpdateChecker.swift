import Foundation
import Observation

/// Checks GitHub Releases for a newer version and remembers the answer.
///
/// Deliberately low-traffic: at most one request per 24h (persisted across launches), fired
/// on launch and on wake rather than on a timer. The last result is cached in UserDefaults so
/// the panel can show a known update immediately, before any network call completes.
@Observable @MainActor final class UpdateChecker {
  /// Latest released version (e.g. "0.2"), if a check has ever succeeded.
  private(set) var latestVersion: String?

  @ObservationIgnored private let repository = "MilosRandelovic/TokenRation"
  @ObservationIgnored private let checkInterval: TimeInterval = 24 * 60 * 60
  @ObservationIgnored private let defaults = UserDefaults.standard
  @ObservationIgnored private static let lastCheckKey = "lastUpdateCheck"
  @ObservationIgnored private static let latestVersionKey = "latestKnownVersion"

  init() { latestVersion = defaults.string(forKey: Self.latestVersionKey) }

  /// The running app's version, or nil when run without a bundle (e.g. `swift run`).
  var currentVersion: String? { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String }

  /// True when GitHub has a version newer than the running one.
  var updateAvailable: Bool {
    guard let current = currentVersion, let latest = latestVersion else { return false }
    return Self.isNewer(latest, than: current)
  }

  var releasesURL: URL { URL(string: "https://github.com/\(repository)/releases/latest")! }

  /// Fetch the latest release tag, unless we checked recently.
  func check() async {
    guard currentVersion != nil else { return }  // unbundled build; nothing to compare
    if let last = defaults.object(forKey: Self.lastCheckKey) as? Date, Date().timeIntervalSince(last) < checkInterval { return }

    var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
    request.timeoutInterval = 10
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("TokenRation", forHTTPHeaderField: "User-Agent")

    guard let (data, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse,
      http.statusCode == 200, let release = try? JSONDecoder().decode(Release.self, from: data)
    else {
      return  // offline, rate-limited, or no releases yet — try again next window
    }

    // Record the check only on success, so a failure retries at the next opportunity.
    defaults.set(Date(), forKey: Self.lastCheckKey)
    let version = Self.normalize(release.tagName)
    latestVersion = version
    defaults.set(version, forKey: Self.latestVersionKey)
  }

  private struct Release: Decodable {
    let tagName: String

    enum CodingKeys: String, CodingKey { case tagName = "tag_name" }
  }

  /// "v0.2" -> "0.2"
  private static func normalize(_ tag: String) -> String { tag.hasPrefix("v") ? String(tag.dropFirst()) : tag }

  /// Numeric component-wise compare, so 0.10 correctly beats 0.9.
  static func isNewer(_ candidate: String, than current: String) -> Bool {
    let left = candidate.split(separator: ".").map { Int($0) ?? 0 }
    let right = current.split(separator: ".").map { Int($0) ?? 0 }
    for index in 0..<max(left.count, right.count) {
      let lhs = index < left.count ? left[index] : 0
      let rhs = index < right.count ? right[index] : 0
      if lhs != rhs { return lhs > rhs }
    }
    return false
  }
}
