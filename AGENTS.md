# Allowance Bar — Agent Context

macOS menu bar app (SwiftUI, Swift Package, macOS 14+) showing AI coding usage
limits for Codex (multiple accounts), Cursor, Claude Code, Gemini, Claude API reporting, and
pay-as-you-go balances for OpenRouter, DeepSeek, Kimi, Z.ai, and Venice.
Public repo: https://github.com/gilitos92/AllowanceBar, a fork of
https://github.com/fdtorres1/AgentMeter (MIT; remote `origin` = this
repo; upstream has no remote). Rebranded to Allowance Bar at 2.0.0 (bundle ID
`com.ggv.AllowanceBar`, URL scheme `allowancebar://`, CLI `allowancebar`).
Source folders, Swift targets/modules, and type names deliberately keep the
`AgentMeter` naming to ease upstream merges; only user-facing names changed.
Test suite: `swift test`.

**If `HANDOFF.md` exists in the repo root, read it first.** It is the
gitignored, machine-local session handoff (current state, pending work,
announcement drafts, environment specifics) and complements this file.

## Architecture

- One file per provider in `Sources/AgentMeter/Providers/`, each implementing
  the `UsageProvider` protocol (`id`, `displayName`, `shortCode`, `isDetected`,
  `fetch() -> ProviderUsage`, optional `assessCredential()`,
  `credentialHelpText`, `apiKeyPlaceholder`, `dashboardURL`). Built by
  `UsageStore.defaultProviders(extraAccounts:)` — the list is DYNAMIC: extra
  Codex accounts (`CodexProvider(accountConfig:)`, id `codex:<uuid>`) are
  inserted after the primary `codex`, and `UsageStore.rebuildProviders()` runs
  when `SettingsStore.codexExtraAccounts` changes.
- `UsageStore` (@MainActor ObservableObject): per-provider `ProviderState`
  (`loading`/`ready`/`stale`/`error`), refresh timer, `DispatchSource` file
  watcher on the newest Codex session file, wake/credential-change observers,
  menu bar title/entries + spoken `menuBarAccessibilityDescription`, and the
  post-refresh `StatusSnapshotWriter` call.
- `SettingsStore` (UserDefaults): per-provider visibility (`auto`/`on`/`off`;
  `auto` = show only when `isDetected`), refresh interval (30s/1m/5m),
  notifications + thresholds, count direction, reset-time style, menu bar
  style (full/compact/icon), `agentAccessEnabled`, `codexExtraAccounts`
  (`[CodexAccountConfig]`, JSON), `subscriptionRenewals`
  (`[providerID: SubscriptionRenewal]`, JSON).
- UI: `MenuContent` (dropdown with a display-bounded scrolling provider list
  and a fixed footer; short lists shrink to their content; provider sections live in
  `ProviderUsageSections.swift` and are shared with `UsageDetailsView`, the
  ⌘D / `allowancebar://details` window), `SettingsWindow` (native tabbed
  Settings: General / Providers / Display / Alerts; includes
  `CodexAccountsSection` with auto-discovery of `~/.codex-*` homes and
  `CodexSubscriptionSettings`), `AboutWindow`. Menu bar title is a rendered
  `NSImage` (`MenuBarTitleRenderer`) with an `accessibilityDescription`.
- Cross-cutting: `CredentialAssessment` (key-type detection + plain-language
  explainers), `UsageMeterSeverity` (shared 60/85% thresholds, symbols,
  spoken qualifiers), `NotificationManager` (`ThresholdTracker`,
  `RenewalTracker`), `SubscriptionRenewal` (anniversary math; billing dates
  are NEVER merged with usage windows), `ErrorRedaction`, `Diagnostics`,
  `DebugLog` (`ALLOWANCEBAR_DEBUG=1` stderr tracing; never credentials).
- Agent/CLI interface (v1.9.0): opt-in `status.json` snapshot in Application
  Support written by `StatusSnapshotWriter` after each refresh; shared schema
  lives in the `AgentMeterStatusKit` library target; target `agentmeter-cli`
  builds the read-only executable product `allowancebar-cli`, installed as
  `Contents/Helpers/allowancebar`. The app binary is product `AllowanceBar`
  (target `AgentMeter`). GOTCHA: the CLI product MUST keep its `-cli` suffix
  and ship in `Helpers/` — "allowancebar" and "AllowanceBar" clobber each
  other on case-insensitive APFS (both in `.build/release/` and in
  `Contents/MacOS/`). Schema doc:
  docs/AGENT_INTERFACE.md (additive changes only within schemaVersion 1).
  `allowancebar skill` prints `docs/agent-skill/SKILL.md`, embedded as
  `AgentSkill.markdown` — a test enforces byte identity, so edit the .md and
  regenerate the Swift constant together (see Conventions).

## Provider data sources (validated formats)

- **Codex** (v1.11.0+): primary source is the Codex CLI app-server protocol.
  `CodexAppServerClient` spawns `codex app-server` (resolved from
  /opt/homebrew/bin, /usr/local/bin, ~/.local/bin, PATH, then `zsh -lc`),
  speaks newline-delimited JSON-RPC over stdio: `initialize` (clientInfo) →
  `initialized` notification → `account/read` (`{account:{email,planType}}`
  or `account:null`) → `account/rateLimits/read` (`rateLimits.primary/
  secondary{usedPercent,windowDurationMins,resetsAt(epoch s)}`, `credits`,
  `planType`; error "authentication required" when signed out). Pipelining
  all four lines up front is fine; skip lines without our ids. ~1 s round
  trip; process is terminated afterwards — never persistent. Polled at most
  every 5 min per account (`CodexAppServerClient.pollInterval`), cached in
  `CodexAccountCache`. Extra accounts = `CodexAccountConfig` entries in
  `SettingsStore.codexExtraAccounts`, each with its own `CODEX_HOME`; the
  user signs in via `mkdir -p <home> && CODEX_HOME=<home> codex login` (Codex refuses a nonexistent CODEX_HOME) — Allowance Bar never logs
  in or reads auth.json. The protocol has NO account-switch method;
  `~/.codex/accounts.json` is written by the Codex desktop app only.
  FALLBACK (primary account only): parse newest
  `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` backwards for the last
  `rate_limits` snapshot (`primary`/`secondary`, `used_percent`, `resets_at`,
  `plan_type`); also preferred when its timestamp is newer than the cache.
  `allowancebar` tracing: `ALLOWANCEBAR_DEBUG=1` (DebugLog) prints structural
  info to stderr — NOTE: when launched directly from a shell (not via `open`)
  the initial refresh may not complete; test with `open`.
- **Cursor**: reads `cursorAuth/accessToken` from
  `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
  (SQLite, read-only, queried in place — the DB is multi-GB, do not copy it).
  Cookie is `WorkosCursorSessionToken=<jwt-sub>::<token>` (percent-encoded);
  the `sub` claim MUST come from the JWT payload — the short `userId` from
  `~/.cursor/cli-config.json` only works on the legacy `/api/usage` endpoint,
  not `GET https://cursor.com/api/usage-summary`. Summary has
  `individualUsage.plan.{totalPercentUsed,autoPercentUsed,apiPercentUsed}`,
  with fallbacks to `individualUsage.overall` and `teamUsage.pooled`
  (used/limit cents) for team/enterprise accounts.
- **Claude**: OAuth creds from `~/.claude/.credentials.json`, falling back to
  Keychain item `Claude Code-credentials` via `/usr/bin/security
  find-generic-password` (`ClaudeKeychainReader`, five-second timeout,
  cancellable, stdout held in memory only). Direct Security.framework secret
  reads are avoided: Claude renewals can reset the app's partition grant even
  while its trusted-app entry remains. Detection is a metadata-only,
  no-interaction Security.framework query. `expiresAt` is in **milliseconds**.
  Usage: `GET https://api.anthropic.com/api/oauth/usage` with
  `anthropic-beta: oauth-2025-04-20` and a `claude-code/x.y.z` User-Agent;
  windows `five_hour`/`seven_day`/`seven_day_opus` with `utilization` percent
  and `resets_at` ISO8601. NEVER refresh these tokens: rotating them in memory
  revokes Claude Code's saved refresh token and signs the user out. When they
  have expired, show `refreshRequired` and ask the user to run Claude Code.
- **Claude API** (`claude-api`, v1.12.0): separate from subscription Claude.
  Keychain API key must have organization reporting access. Read-only GET
  `/v1/organizations/cost_report` and `/v1/organizations/usage_report/messages`
  return organization-wide UTC monthly spend and token categories. Costs are
  decimal-string cents; convert to USD. Daily report end is next UTC midnight
  to include today's partial bucket. Paginate both reports. Cache for five
  minutes (60-second failure cooldown), keyed by credential digest and month;
  explicit menu/CLI refresh bypasses successful cached reports. Concurrent
  refreshes share a request; failed refreshes cannot reuse an old cached success.
  Actual coverage `periodEnd` comes from returned bucket ends, capped at fetch
  time, using the older of cost and token coverage. API `asOf` is last checked;
  do not claim the current day is reported just because a fetch succeeded.
  do not log keys or response bodies. No public prepaid-credit endpoint:
  explicitly unavailable plus billing link, never an estimated balance.
  `ProviderUsage.apiUsage` holds the detail; `.spent` balance supports menu
  summaries and old CLI readers. Key changes clear state and ignore old fetches.
- **Gemini**: OAuth creds from `~/.gemini/oauth_creds.json` (`expiry_date` in
  ms). Refresh via `oauth2.googleapis.com/token` with the Gemini CLI's public
  installed-app client (constants in `GeminiProvider`, split into string
  fragments only so GitHub secret scanning doesn't false-positive — Google
  documents installed-app secrets as non-confidential). Quota: POST
  `https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota` (body
  `{"project": id}` when `:loadCodeAssist` returns one); buckets have
  `modelId`, `remainingFraction` (0..1 remaining, invert for used), `resetTime`.

## Ground rules (project's core promise — do not violate)

- Credentials are read fresh from the other apps' own stores on each refresh,
  never written to disk, never logged, never sent anywhere except that
  provider's own API. Refreshed tokens live in memory only.
- `isDetected` must be cheap and prompt-free: file existence only. No Keychain
  reads (prompts), no network. (Claude's Keychain check uses
  `SecItemCopyMatching` without returning data, which does not prompt.)
- No analytics/telemetry, no third-party dependencies.
- Reading the desktop app containers (Claude.app cookies, Gemini.app auth blob)
  was considered and REJECTED: values are AES-encrypted via Keychain
  "Safe Storage" keys; decrypting them is fragile and trust-damaging. The CLI
  credential files are the intended source.

## Build / test

```bash
swift build                 # NOTE: run outside the tool sandbox; SwiftPM's own
                            # sandbox conflicts and errors with "sandbox_apply:
                            # Operation not permitted". Use full permissions.
swift test                  # live-network tests are opt-in via env
                            # (CURSOR_LIVE_TEST=1) and skip by default.
scripts/bundle.sh [--install]   # builds "Allowance Bar.app" (ad-hoc signed by default)
```

- CI (`.github/workflows/ci.yml`) runs build+test on `macos-26` (Xcode 26+ SDK, needed for Liquid Glass APIs) for push/PR.
- There is no release workflow: releases are cut LOCALLY (see runbook below).
- Every build is signed with the hardened runtime (blocks `DYLD_*` code
  injection that would inherit the app's Keychain access). Builds without a
  Team ID add `Resources/AllowanceBar.entitlements`
  (disable-library-validation) so the self-signed Sparkle framework loads.
  The inherited Developer ID/notarization workflow was removed in 2.0.1.

## Release runbook (the actual, tested end-to-end flow)

Releases are cut locally. Full detail in [docs/RELEASING.md](docs/RELEASING.md).

Credentials (do NOT prompt for them; never print them):
- Signing identity: self-signed `GGV` certificate in the login keychain
  (default `SIGN_IDENTITY` in `release.sh`). No Developer ID, so builds are
  NOT notarized.
- Sparkle EdDSA key: login keychain, account `AllowanceBar`
  (`generate_keys --account AllowanceBar`).
- Backup of both: 1Password vault Personal, item "Allowance Bar Release Keys"
  (Sparkle keys, attached `GGV.p12`, and its password).
- Never sign public builds with the Apple Development certificate: it embeds
  the owner's legal name.

Steps (bump `X.Y.Z`, keep `CHANGELOG.md` updated first):
1. Branch `Release-X.Y.Z` from `Development`, commit "Prepare Allowance Bar
   X.Y.Z release", merge `--no-ff` into `main` and `Development`.
2. `ALLOWANCEBAR_VERSION=X.Y.Z scripts/release.sh` — builds, signs with GGV
   (inside-out incl. Sparkle), zips `AllowanceBar.zip`, writes a signed
   `appcast.xml`.
3. `git tag vX.Y.Z` on `main`; `git push origin main Development vX.Y.Z`.
4. `gh release create vX.Y.Z AllowanceBar.zip appcast.xml -R gilitos92/AllowanceBar
   --title "Allowance Bar X.Y.Z" --notes ...` — BOTH assets; the app's
   SUFeedURL is `releases/latest/download/appcast.xml`. Notes mention the
   self-signed, not-notarized build and the one-time "Open Anyway" step.
5. Install locally to verify (`cp -R "Allowance Bar.app" /Applications/`).

Gotchas:
- `generate_appcast` or `codesign` may trigger a Keychain prompt for the
  Sparkle or GGV key. Approve with "Always Allow".
- `appcast.xml` and `AllowanceBar.zip` are gitignored (release assets only).
  The old `AgentMeter.zip` is still tracked (historical); leave it alone.
- `.build/`, `*.app/`, `HANDOFF.md` are gitignored.
- Running the app binary directly from a shell (for `ALLOWANCEBAR_DEBUG`) can
  leave the initial refresh incomplete; verify behavior with `open`.

## Conventions

- Keep PR titles human-readable; they show up in the repo history.
- Public issue tracking only (no Discussions).
- Avoid rewriting history (the upstream history was recreated once to strip a
  secret-scanner false positive).
- Localization: every user-facing string goes through `L()` and gets en + es
  entries in `Sources/AgentMeter/Resources/Localizable.xcstrings`; then run
  `xcrun xcstringstool compile Sources/AgentMeter/Resources/Localizable.xcstrings
  --output-directory Sources/AgentMeter/Resources` (bundle.sh does this too).
  CLI output and docs are English-only.
- App icon: `Resources/AppIcon.svg` is canonical (drawn for Allowance Bar;
  never reuse AgentMeter artwork). After editing it run `scripts/make-icon.sh`
  (needs `brew install librsvg`) to regenerate `AppIcon.icns` and
  `AppIcon-source.png`.
- Agent skill: `docs/agent-skill/SKILL.md` is canonical; after editing it,
  regenerate `Sources/AgentMeterStatusKit/AgentSkill.swift` so the raw-string
  constant is byte-identical (`AgentSkillTests` fails otherwise).
- Snapshot schema (`AgentMeterStatusKit`): additive optional fields only
  within `schemaVersion` 1; update docs/AGENT_INTERFACE.md tables and the
  fixture test in the same change.
- Accessibility: every new meter/row is one accessibility element with a
  label + value; severity is never color-only (`UsageMeterSeverity`); state
  changes post `AccessibilityNotification.Announcement`.
- Delegation pattern that has worked: spec bounded implementation tasks to a
  subagent, then review every diff, run the suite, and live-test against the
  installed app before releasing. Subagents sometimes create a stray branch
  at HEAD — `git checkout main` carries the working tree back.
