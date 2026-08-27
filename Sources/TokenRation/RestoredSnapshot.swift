import Foundation
import UsageState

extension UsageSnapshot {
  /// Rebuilds a reading from the state file the app published on its last run.
  ///
  /// Without this a cold start shows "Loading usage…" until the first fetch lands — and the
  /// request guards mean that can be minutes away, since relaunching inside the minimum gap or
  /// an active backoff skips the fetch entirely. The numbers were already on disk; the panel
  /// just wasn't reading them. `updatedAt` is carried over rather than reset, so the footer
  /// reports the real age and `isStale()` still decides whether to top up.
  ///
  /// Returns nil when there is nothing worth showing, so a first-ever launch still shows the
  /// loading state rather than an empty panel.
  init?(restoring published: ProviderUsage) {
    guard let updatedAt = published.updatedAt, !published.metrics.isEmpty else { return nil }
    self.init(
      metrics: published.metrics.map { metric in
        DisplayMetric(
          id: metric.id,
          // The id carries the provider, so a stored reading rebuilds without being told which
          // model it belongs to.
          provider: Provider.owning(metricID: metric.id) ?? .claude, title: metric.title,
          symbolName: DisplayMetric.symbolName(for: metric.id), barText: metric.value, valueText: metric.detail,
          fraction: metric.usedPercent.map { $0 / 100 }, severity: Severity(apiValue: metric.severity), resetsAt: metric.resetsAt)
      }, updatedAt: updatedAt)
  }
}
