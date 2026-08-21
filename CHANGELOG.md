# Changelog

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
