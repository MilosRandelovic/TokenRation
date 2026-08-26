# Changelog

## [0.1.4]

- Empty credentials are reported as signed out. The CLI writes the credential back with empty
  strings when its refresh token has expired, and an empty bearer token earns an HTTP 429 — so the
  app used to report a throttle, and back off for hours, over a sign-in problem. Signing back in
  now clears the hold immediately.
- A cold start shows the last known reading immediately instead of a spinner. The app was
  already writing it to disk for the MCP server; now it reads it back, and the footer reports the
  reading's real age.
- The provider tabs use the system segmented control, so they follow the current macOS design
  rather than a hand-drawn imitation of one release's appearance.

## [0.1.3]

- The bundle identifier is now `com.milosrandelovic.tokenration`, a reverse-DNS name under an
  owned domain. Preferences are keyed by it, so pinned metrics start from the default again.
- Adds an app icon, shown in the panel header, Finder, Spotlight and on update notifications.
- The update check runs on its own half-hourly cadence and when the panel is opened, so a
  long-running app notices a release instead of relying on a launch or a wake.
- A new version is announced once with a notification, alongside the panel's banner.
- Update checks are logged, so a failed or skipped check can be seen.

## [0.1.2]

- Replacing rejected credentials ends the hold they caused, so signing in again through the CLI
  restores readings on the next refresh rather than at the end of the interval.
- A rate-limit hold is unaffected: a 429 asks for quiet regardless of which credentials are used.

## [0.1.1]

- A rejected access token is retried within a few minutes, so one the CLI rotates mid-session is
  picked up promptly instead of parking usage readings for a quarter of an hour. A token that stays
  rejected still settles onto the long interval, since only signing in again will fix it.
- Missing credentials and a rejected token are reported separately, in both the panel and the log.

## [0.1.0]

- Initial release: native macOS menu-bar app showing **Claude and Codex** usage — session and
  weekly windows, per-model limits (e.g. Fable, Codex-Spark), and spend/credits.
- Claude is read from `/api/oauth/usage`; Codex from a local `codex app-server` over JSON-RPC.
- Providers are detected automatically; the panel shows a tab per provider when both are set up,
  and each polls independently with its own backoff.
- Pin one or more metrics as menu-bar icons; theme-adaptive template rendering.
- Dropdown panel with per-metric gauges, loading and rate-limited states, and an About view.
- Authenticates with the access token the Claude Code CLI already stores in the Keychain;
  never writes or refreshes it.
- Bundled MCP server (`tokenration-mcp`) exposing `get_usage`, so agents can check remaining
  quota mid-session. Reads the app's published reading; never calls an API itself.
- Distributed as a Homebrew cask (`MilosRandelovic/tokenration`), which also symlinks
  `tokenration-mcp` onto the PATH.
