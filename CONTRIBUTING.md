# Contributing to Allowance Bar

Thanks for your interest! PRs are welcome. For anything beyond a small fix,
please open an issue first so we can agree on the approach before you invest
time.

## Building and testing

```bash
swift build          # debug build
swift test           # unit tests (network-dependent tests are opt-in and skip by default)
scripts/bundle.sh    # produce Allowance Bar.app in the repo root
```

Requirements: macOS 14+ to run; building needs Xcode 26 or later (the macOS 26 SDK).

## Project layout

- `Sources/AgentMeter/Providers/` — one file per provider plus the `UsageProvider`
  protocol; each reads local credentials and maps the response to `UsageWindow`s.
  `CodexAppServerClient.swift` talks to the Codex CLI; `ProviderAccountConfig.swift`
  holds every provider's extra-account config and discovery.
- `Sources/AgentMeter/UsageStore.swift` — dynamic provider list, refresh timer, Codex file watcher, menu bar title and spoken summary.
- `Sources/AgentMeter/SettingsStore.swift` — visibility, refresh cadence, display/alert preferences, extra accounts, renewal dates.
- `Sources/AgentMeter/MenuContent.swift` + `ProviderUsageSections.swift` — dropdown UI (shared with the Usage Details window); `SettingsWindow.swift` — native tabbed Settings.
- `Sources/AgentMeter/CredentialAssessment.swift` — key-type detection and plain-language explainers.
- `Sources/AgentMeter/SubscriptionRenewal.swift` — renewal-date model and reminder math.
- `Sources/AgentMeter/StatusSnapshotWriter.swift` — opt-in `status.json`; `Sources/AgentMeterStatusKit/` — shared snapshot schema, CLI parsing, embedded agent skill; `Sources/agentmeter-cli/` — the read-only CLI (product `allowancebar-cli`, installed in the app as `Contents/Helpers/allowancebar`).
- `Sources/AgentMeter/Updater.swift` — Sparkle auto-updates.
- `docs/` — [providers](docs/PROVIDERS.md), [agent interface](docs/AGENT_INTERFACE.md), [Codex accounts guide](docs/CODEX_ACCOUNTS.md), [agent skill](docs/agent-skill/SKILL.md), [releasing](docs/RELEASING.md).
- `scripts/bundle.sh` / `scripts/release.sh` — bundling and signed release with a Sparkle appcast.

Source folders and Swift modules keep the original `AgentMeter` names so
upstream changes stay easy to merge.

## Adding a provider

Each provider is one file in `Sources/AgentMeter/Providers/` implementing the
`UsageProvider` protocol:

1. `isDetected` must be cheap and prompt-free (file existence checks only —
   no Keychain reads, no network).
2. `fetch()` reads credentials fresh from the provider's own local storage,
   calls the provider's API, and maps the response to `UsageWindow`s
   (percent used + optional reset date).
3. Credentials must never be written to disk or sent anywhere except the
   provider's own API. This is the project's core promise.
4. Register the provider in `UsageStore.defaultProviders` and add unit tests
   for the response mapping (see `Tests/AgentMeterTests/` for examples).

## Ground rules

- Keep it small: this is a menu bar utility, not a dashboard suite.
- No analytics, no telemetry, no third-party dependencies without discussion.
- Issues marked `good first issue` are a fine place to start.

## Releases

Maintainer-only; see [docs/RELEASING.md](docs/RELEASING.md).
