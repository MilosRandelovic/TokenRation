import AppKit

/// Wires the providers, preferences, and status-bar controller together, and starts polling.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  // Providers first: Preferences constrains pinned metrics to what's actually detected, so a
  // Codex-only Mac never shows an unpinnable Claude placeholder.
  private let providers = ProvidersModel()
  private lazy var prefs = Preferences(available: providers.available)
  private let updates = UpdateChecker()
  private var statusBar: StatusBarController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    Log.write("app launched (version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"))")
    providers.onMetricsSettled = { [weak self] knownIDs, settled in self?.prefs.reconcile(knownIDs: knownIDs, settled: settled) }
    statusBar = StatusBarController(providers: providers, prefs: prefs, updates: updates)
    providers.startAll()
    updates.start()

    // Stop polling while the machine is asleep and resume on wake. The resumed loops' first
    // attempts still pass through the guards in `refresh`, so frequent wakes (power naps on
    // a closed lid) can't turn into a burst of requests.
    let workspaceCenter = NSWorkspace.shared.notificationCenter
    workspaceCenter.addObserver(self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
    workspaceCenter.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
  }

  func applicationWillTerminate(_ notification: Notification) {
    Log.write("app terminating")
    providers.stopAll()
    updates.stop()
  }

  @objc private func systemWillSleep() {
    Log.write("system sleeping")
    providers.stopAll()
    updates.stop()
  }

  @objc private func systemDidWake() {
    Log.write("system woke")
    providers.startAll()
    updates.start()
  }
}
