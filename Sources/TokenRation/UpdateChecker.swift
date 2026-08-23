import Foundation
import Observation
import UserNotifications

/// Checks GitHub Releases for a newer version, remembers the answer, and notifies once per
/// version.
///
/// Runs on its own cadence rather than only at launch and wake: a menu-bar app can stay up for
/// days without either happening, and a check that lands minutes before a release would then be
/// the last one for the rest of the session. The persisted deadline is what keeps the traffic
/// low — restart storms and repeated wakes all collapse onto the same gap.
@Observable @MainActor final class UpdateChecker {
  /// Latest released version (e.g. "0.1.2"), if a check has ever succeeded.
  private(set) var latestVersion: String?

  @ObservationIgnored private let repository = "MilosRandelovic/TokenRation"
  /// Minimum spacing between requests. GitHub allows 60 an hour unauthenticated; this uses two.
  @ObservationIgnored private static let checkInterval: TimeInterval = 30 * 60
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private var loop: Task<Void, Never>?
  @ObservationIgnored private var loggedDenial = false
  @ObservationIgnored private static let lastCheckKey = "lastUpdateCheck"
  @ObservationIgnored private static let latestVersionKey = "latestKnownVersion"
  @ObservationIgnored private static let notifiedVersionKey = "notifiedVersion"
  @ObservationIgnored private static let forceKey = "forceUpdateCheck"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    latestVersion = defaults.string(forKey: Self.latestVersionKey)
  }

  /// The running app's version, or nil when run without a bundle (e.g. `swift run`).
  var currentVersion: String? { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String }

  /// True when GitHub has a version newer than the running one.
  var updateAvailable: Bool {
    guard let current = currentVersion, let latest = latestVersion else { return false }
    return Self.isNewer(latest, than: current)
  }

  var releasesURL: URL { URL(string: "https://github.com/\(repository)/releases/latest")! }

  /// Begin checking, and keep checking for as long as the app is awake.
  func start() {
    guard loop == nil else { return }
    // Ask for notification permission now: the prompt has to be answered before a notification
    // can be posted, and asking at launch puts it in front of someone who is already here,
    // rather than whenever a release happens to land.
    Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    loop = Task { [weak self] in
      while !Task.isCancelled {
        await self?.check()
        try? await Task.sleep(for: .seconds(Self.checkInterval))
      }
    }
  }

  func stop() {
    loop?.cancel()
    loop = nil
  }

  /// Whether a check runs now, and on whose behalf.
  enum Decision: Equatable {
    /// A check succeeded recently; leave it alone.
    case skip
    /// The spacing has elapsed.
    case due
    /// Asked for by hand, which also waives the once-per-version guard.
    case forced
  }

  /// Decides whether to check, consuming the force flag if one is set.
  ///
  /// Forcing exists because the notification is otherwise only reachable by running an older
  /// build: `defaults write com.milos.tokenration forceUpdateCheck -bool true`. The flag is
  /// consumed here rather than left standing, so a forgotten one cannot turn into a request
  /// on every tick.
  func decide() -> Decision {
    if defaults.bool(forKey: Self.forceKey) {
      defaults.set(false, forKey: Self.forceKey)
      Log.write("[update] forced check requested")
      return .forced
    }
    if let last = defaults.object(forKey: Self.lastCheckKey) as? Date, Date().timeIntervalSince(last) < Self.checkInterval { return .skip }
    return .due
  }

  /// Fetch the latest release tag, unless a check succeeded recently.
  func check() async {
    guard let current = currentVersion else { return }  // unbundled build; nothing to compare
    let decision = decide()
    guard decision != .skip else { return }

    var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
    request.timeoutInterval = 10
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("TokenRation", forHTTPHeaderField: "User-Agent")

    guard let (data, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse else {
      Log.write("[update] check failed: no response")
      return  // offline; try again next window
    }
    guard http.statusCode == 200, let release = try? JSONDecoder().decode(Release.self, from: data) else {
      Log.write("[update] check failed: HTTP \(http.statusCode)")
      return  // rate-limited, or no releases yet
    }

    // Record the check only on success, so a failure retries at the next opportunity.
    defaults.set(Date(), forKey: Self.lastCheckKey)
    let version = Self.normalize(release.tagName)
    latestVersion = version
    defaults.set(version, forKey: Self.latestVersionKey)

    guard Self.isNewer(version, than: current) else {
      Log.write("[update] \(current) is current (latest \(version))")
      return
    }
    Log.write("[update] \(version) available (running \(current))")
    await notify(about: version, forced: decision == .forced)
  }

  /// Tell the user once per version. Announcing the same release on every launch would train
  /// them to ignore it, so the version announced is persisted rather than held in memory.
  private func notify(about version: String, forced: Bool) async {
    guard forced || defaults.string(forKey: Self.notifiedVersionKey) != version else { return }

    let center = UNUserNotificationCenter.current()
    var status = await center.notificationSettings().authorizationStatus
    if status == .notDetermined {
      // The request made at launch may still be sitting in front of the user. Waiting for their
      // answer here keeps the very first announcement from being dropped on a fresh install.
      _ = try? await center.requestAuthorization(options: [.alert, .sound])
      status = await center.notificationSettings().authorizationStatus
    }
    guard status == .authorized || status == .provisional else {
      // Only once per run: an update stays pending across many checks, and repeating this
      // every half hour would bury the log.
      if !loggedDenial {
        Log.write("[update] notifications not permitted; the panel still shows the update")
        loggedDenial = true
      }
      return
    }

    let content = UNMutableNotificationContent()
    content.title = "TokenRation \(version) is available"
    content.body = "Run brew upgrade tokenration to update."
    do {
      // Reusing an identifier updates the existing notification in place instead of alerting
      // again, which would defeat the point of asking for it by hand.
      let identifier = forced ? "update-\(version)-\(UUID().uuidString)" : "update-\(version)"
      try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
      defaults.set(version, forKey: Self.notifiedVersionKey)
    } catch { Log.write("[update] could not post notification: \(error.localizedDescription)") }
  }

  private struct Release: Decodable {
    let tagName: String

    enum CodingKeys: String, CodingKey { case tagName = "tag_name" }
  }

  /// "v0.1.2" -> "0.1.2"
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
