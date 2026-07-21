# TokenRation

A native macOS menu-bar app that shows your **Claude** and **Codex** usage at a glance — session
and weekly windows, per-model limits (e.g. Fable, Codex-Spark), and spend/credits.

Pin one metric for a single icon, or several to stack them. Each provider uses a distinct icon
family so you can tell them apart at a glance, and all icons are template images, so they look
right on light and dark menu bars. When both providers are set up, the panel gets a tab each.

## Install

Requires macOS 14+ and at least one of the Claude Code or Codex CLIs, signed in. Whichever are
present are detected automatically.

```sh
brew tap MilosRandelovic/tokenration
brew install tokenration
```

On first launch, click **Always Allow** on the one-time Keychain prompt — that lets TokenRation
read the access token the Claude Code CLI saved there. There's no separate sign-in.

## Agent access (MCP)

TokenRation bundles an MCP server so coding agents can check your remaining quota — e.g. before
starting expensive work — without anyone hitting a usage API a second time. Register it once:

```sh
claude mcp add tokenration -- tokenration-mcp     # Claude Code
codex mcp add tokenration -- tokenration-mcp      # Codex
```

One tool, **`get_usage`** — takes no arguments and returns every limit, kept separate per
provider (`claude` and `codex` each with their own status, metrics and reset times), plus how
old the reading is. Poll it as often as you like: it reads a local file, so calling it costs
nothing upstream.

It **only reads** the app's published reading (`~/Library/Application Support/TokenRation/usage.json`)
and never calls a usage API itself — MCP servers are spawned per session, so a fetching server
would multiply request load across every concurrent agent. Results carry `ageSeconds` and
`stale` so a caller can judge freshness; if the app isn't running, the data is simply old.

## Build from source

macOS 14+, Swift 6 (Xcode 16+):

```sh
swift test                      # unit tests (also run by CI)
swift run                       # run from source (dies with the shell — fine for a quick check)
./build-app.sh                  # TokenRation.app, ad-hoc signed (local use)
./release.sh                    # notarized build for distribution (needs a Developer ID cert)
```

Launch the built app with `open TokenRation.app`, or copy it to `/Applications` and start it
from Finder/Spotlight. **Don't run `TokenRation.app/Contents/MacOS/TokenRation &` from a
terminal** — that makes the app a child of the shell, so it is killed the moment the shell
exits (silently, with no crash report). `open` detaches it properly. For a menu-bar app you
want running all the time, add it to **System Settings ▸ General ▸ Login Items**.

## How it works

- **Claude data:** `GET https://api.anthropic.com/api/oauth/usage` — the same endpoint Claude
  Code's `/usage` uses. Polled every ~5 minutes, paused while the Mac sleeps or is offline, with
  exponential backoff and a long hold-off after a rate limit (all persisted, so restarts and
  wakes can't bypass it).
- **Codex data:** JSON-RPC `account/rateLimits/read` against a local `codex app-server`
  subprocess. The ChatGPT HTTP backend rejects non-client callers (403 bot protection), and going
  through the local CLI means no credential handling of our own and no model quota consumed.
- **Auth:** the Claude Code CLI stores an OAuth access token in your login Keychain
  (`Claude Code-credentials`); TokenRation reads that token via `/usr/bin/security` to
  authenticate the Claude request. Codex needs nothing — its own CLI is already signed in.
  Credentials are **never written or refreshed**; the CLIs stay the only things that manage them.
- **Independence:** each provider polls on its own schedule with its own persisted backoff, so
  one being throttled or signed out never stalls the other.
- **Diagnostics:** every attempt and its outcome is logged to `~/Library/Logs/TokenRation.log`
  (rotated at 512 KB) for troubleshooting.

## Architecture

```
Sources/TokenRation/
├── Main.swift · AppDelegate.swift   entry point; wires providers + prefs + status bar
├── Provider.swift                   the two providers: detection + per-provider icon family
├── ProvidersModel.swift             one UsageModel per detected provider; tab selection
├── UsageModel.swift                 polling loop + state (per-provider, persisted backoff)
├── ClaudeUsageProvider.swift        /api/oauth/usage → DisplayMetrics
├── CodexUsageProvider.swift         codex app-server JSON-RPC → DisplayMetrics
├── CodexBinary.swift                locates the codex executable
├── KeychainToken.swift              reads the Claude token via /usr/bin/security
├── StatusBarController.swift        menu-bar item + the custom dropdown panel
├── UsagePanelView.swift             SwiftUI panel: tabs, meters, pins, states, About
└── UsageSnapshot.swift              value types the UI renders

Sources/UsageState/                  shared state file format (app writes, MCP server reads)
Sources/TokenRationMCP/              the bundled stdio MCP server
```

Distributed as a Homebrew cask via the
[homebrew-tokenration](https://github.com/MilosRandelovic/homebrew-tokenration) tap.

## License

MIT — see [LICENSE](LICENSE).
