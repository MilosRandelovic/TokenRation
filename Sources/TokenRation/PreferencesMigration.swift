import Foundation

/// Carries preferences across a change of bundle identifier.
///
/// `UserDefaults.standard` is keyed by the bundle identifier, so renaming it starts the app on an
/// empty domain: pinned metrics revert to the default and every persisted backoff deadline is
/// lost, which also means an upgrade could fetch immediately against an endpoint that is still
/// rate-limiting. Copying the old domain over once keeps an upgrade invisible.
enum PreferencesMigration {
  /// The identifier used before the app moved to a reverse-DNS name under an owned domain.
  static let legacyDomain = "com.milos.tokenration"
  private static let markerKey = "migratedFromLegacyDomain"

  static func run(into defaults: UserDefaults = .standard) { run(into: defaults, legacy: defaults.persistentDomain(forName: legacyDomain)) }

  /// - Parameter legacy: the old domain's contents; injectable for tests.
  static func run(into defaults: UserDefaults, legacy: [String: Any]?) {
    guard !defaults.bool(forKey: markerKey) else { return }
    // Marked before copying: a half-finished migration should not run again and overwrite
    // whatever the user has since changed.
    defaults.set(true, forKey: markerKey)

    guard let legacy, !legacy.isEmpty else { return }
    var carried = 0
    for (key, value) in legacy where defaults.object(forKey: key) == nil {
      defaults.set(value, forKey: key)
      carried += 1
    }
    if carried > 0 { Log.write("carried \(carried) preferences over from \(legacyDomain)") }
  }
}
