import AppKit

/// Process entry point — starts the AppKit menu-bar app as an accessory
/// (no Dock icon, no main window).
@main enum EntryPoint {
  static func main() {
    MainActor.assumeIsolated {
      // Before anything reads preferences: the models load persisted backoff at init.
      PreferencesMigration.run()
      let app = NSApplication.shared
      let delegate = AppDelegate()
      app.delegate = delegate
      app.setActivationPolicy(.accessory)
      app.run()
    }
  }
}
