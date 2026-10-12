# Changelog

All notable changes to Allowance Bar (formerly AgentMeter). Format follows
[Keep a Changelog](https://keepachangelog.com); versions follow semantic-ish
`MAJOR.MINOR.PATCH`. Entries before 2.0.0 are AgentMeter releases (upstream
through 1.12.1, then this fork's 1.12.2–1.15.0).

## [Unreleased]

## [2.2.3] — 2026-10-12

### Fixed
- Claude Code credentials are read through Apple's trusted `security` tool,
  avoiding repeated Allowance Bar Keychain password prompts when Claude
  renews its token and resets the app's separate permission. Reads have a
  timeout and can be cancelled; credentials remain in memory and are never
  renewed or written back by Allowance Bar. A locked or restricted Keychain
  can still require authorization.

## [2.2.2] — 2026-10-11

### Fixed
- The mini and nano panels can be dragged past the screen edges again
  instead of bouncing back inward. Showing or hiding the nano panel's hover
  controls no longer pulls a panel back on screen either.

## [2.2.1] — 2026-10-11

### Changed
- The README now includes light and dark Nano window screenshots, how to
  open and expand the panel, its hover controls, and its independent
  show-all-limits setting.

## [2.2.0] — 2026-10-11

### Added
- **Nano panel** for the Usage Details window: the smallest view, showing
  only the menu bar text, e.g. `Cx 50% · Cl 30%`, in the same colors.
  Hovering shows the window controls (Close, Keep on Top, Show on All
  Desktops, Opacity, Expand) above the text, which stays in place. Drag
  anywhere outside the buttons to move it. Open it with **Nano View** in the
  full window's toolbar or the mini panel's controls. With the icon-only menu
  bar style it lists every menu bar provider. VoiceOver reads the same
  summary as the menu bar.
- Settings › Display › "Show all limits in the nano window", separate from
  the menu bar setting. It starts out matching the menu bar setting.

### Fixed
- Dragging the mini or nano panel quickly no longer makes it jump away from
  the pointer.

## [2.1.0] — 2026-10-11

### Added
- Settings › Display › "Show all limits in the menu bar": each provider shows
  every limit in dropdown order, e.g. `Cx 8% (35%)` for the Codex 5-hour and
  weekly limits, instead of only the most constrained one. VoiceOver names
  each limit. Off by default.

## [2.0.6] — 2026-10-11

### Fixed
- The About window credits AgentMeter by Felix Torres again (it said
  "Allowance Bar" since 2.0.0), and the credit line is now translated into
  Spanish.

## [2.0.5] — 2026-10-10

### Changed
- CI builds on macOS 26 (Xcode 26), which the Liquid Glass APIs need.
  Building from source now requires Xcode 26 or later.
- Removed VS Code launch configurations from the repository.

## [2.0.4] — 2026-10-10

### Security
- Builds are signed with the hardened runtime, so other processes can no
  longer inject code into Allowance Bar and borrow its Keychain access.
- Network requests refuse redirects, so a credential is never forwarded to
  another host.
- Error text is redacted (keys, tokens, home folder paths) before it appears
  in the menu, Copy Diagnostics, or the status file. Redaction now also
  catches base64 tokens and short `key=` values.
- The OpenRouter sign-in verifier stays in memory instead of preferences.
- CI pins its checkout action by commit and uses a read-only token.

### Fixed
- A Venice balance response with currencies that differ only by case no
  longer crashes the app.

## [2.0.3] — 2026-10-10

### Fixed
- Usage alerts fire once per known limit window, even when reset estimates
  drift or usage fluctuates. Alerted windows remain remembered after restart.

### Changed
- The README's Buy Me a Coffee link is now a visual button beneath the
  introduction.

## [2.0.2] — 2026-10-10

### Fixed
- Usage bars now follow light and dark appearance changes correctly.
- The mini window keeps its title bar hidden when it opens at launch.
- Each Usage Details toolbar button has its own VoiceOver label.
- The full and mini Usage Details windows use a standard frosted background
  that captures correctly in window screenshots. The opacity control is
  available on all supported macOS versions; the full-window toolbar keeps
  Liquid Glass on macOS 26 and later.

### Changed
- The README opens with Why Allowance Bar and fresh light and dark previews
  of the menu bar dropdown, full window, and mini window.

## [2.0.1] — 2026-10-10

### Removed
- The GitHub Actions release workflow inherited from AgentMeter. It needed a
  paid Apple Developer ID certificate and notarization key that this project
  does not use, so it could never run. Releases are built locally with
  `scripts/release.sh`; the build-and-test CI workflow stays.

## [2.0.0] — 2026-10-10

Allowance Bar is the new name for this fork of
[AgentMeter](https://github.com/fdtorres1/AgentMeter) by Felix Torres. It is a
separate app and does not replace or update the original AgentMeter.
Versions continue from this fork's last AgentMeter release (1.15.0); the
major bump marks the rename and keeps tags and releases from colliding with
the shared AgentMeter history.

### Changed
- New name and identity: **Allowance Bar** (`com.ggv.AllowanceBar`), URL
  scheme `allowancebar://`, command-line tool `allowancebar`, snapshot folder
  `~/Library/Application Support/AllowanceBar/`.
- Updates now come from this project's own GitHub releases, signed with its
  own update key. The pause on automatic updates added in 1.12.2 is removed.
- Releases are signed with a stable self-signed certificate ("GGV"), so
  macOS remembers Keychain "Always Allow" choices across updates. Builds are
  not notarized; the first launch needs **Open Anyway** in System Settings →
  Privacy & Security.
- New app icon: three usage bars on a floating glass panel, in warm orange.
  The editable source is `Resources/AppIcon.svg`.
- The About window and README credit the original AgentMeter, link to this
  project, and highlight the floating Usage Details window.
- The "Support ♥" link in the menu and About window now opens this
  project's Buy Me a Coffee page. The README credits section still links to
  the original author's page.

### Upgrading from AgentMeter fork builds
- Allowance Bar starts fresh: re-enter API keys, re-add extra Codex accounts,
  and approve Keychain prompts. Then quit and delete the old AgentMeter app.

## [1.15.0] — 2026-10-10

### Added
- On macOS 26 and later, the Usage Details window uses Liquid Glass. Its
  content sits inside the glass, so macOS keeps text readable over whatever
  is behind the window.
- A Regular / Clear glass choice replaces the opacity slider on macOS 26 and
  later. Clear glass dims what is behind it and uses light text. Earlier
  macOS versions keep the opacity slider.
- The expanded window's buttons float together in one Liquid Glass capsule.

### Changed
- Normal usage percentages, bars and healthy balances use the main text
  color instead of green. High and critical usage keep yellow and red.
- Provider titles show as plain text instead of blue links; they still open
  each provider's dashboard.
- Window option toggles show "on" with a filled gray symbol instead of blue.
- The faintest text (reset details, "Data as of") is a step darker.
- The compact panel shows the time until reset in parentheses.

## [1.14.2] — 2026-10-09

### Fixed
- The compact Usage Details panel's controls no longer disappear when the
  pointer moves onto them, so they can be clicked again.
- The expanded Usage Details window shows its title, window buttons and
  toolbar buttons again; the window background had been covering them.

## [1.14.1] — 2026-10-09

### Changed
- Larger, bolder text for easier reading. Usage text in the menu, the Usage
  Details window and the compact panel moves from 10 pt to 11–12 pt with
  heavier weights, and percentages are semibold. Settings and About text is
  larger too. The menu and details views are a little wider to fit.

### Fixed
- `swift build` works again with Swift 6.4's default build backend, which
  failed on duplicate `Localizable.strings` outputs.

## [1.14.0] — 2026-10-09

### Added
- Compact Usage Details panel: a toolbar button collapses the window into a
  small, chrome-free panel with one mini meter per limit (for example 5h and
  weekly) for each provider, plus the time until each limit resets. Drag it
  from anywhere. Close, Keep on Top, Show on All Desktops, Opacity and Expand
  controls appear on hover (always with VoiceOver).
- Opacity control for the Usage Details window, in the toolbar and the compact
  panel: a slider fades the translucent background while text and meters stay
  opaque.

### Changed
- The full Usage Details window is slightly wider so all toolbar buttons fit.

## [1.13.0] — 2026-10-08

### Added
- Usage Details window toolbar buttons: "Keep on Top" keeps the window above
  other windows, even when you switch apps; "Show on All Desktops" also shows
  it on every desktop (Space) and over full-screen apps (requires Keep on Top).
  Both are off by default and remembered.

### Changed
- The Usage Details window uses the menu dropdown's translucent material.
- The Usage Details window fits its content instead of keeping a fixed
  minimum height, and scrolls only when the content is taller than the screen.

## [1.12.2] — 2026-10-08

### Fixed
- AgentMeter no longer renews Claude Code's sign-in token. Renewing it rotated
  the shared refresh token without saving the new one, so Claude Code could be
  signed out. When the token has expired, AgentMeter now asks you to run
  Claude Code and then refresh.
- The menu bar popup resizes to fit its content instead of keeping empty space
  from its first layout.
- Packaging works with Swift 6.4 by building with SwiftPM's native build system.

### Changed
- Builds that set `AgentMeterLocalAuthRepair` in Info.plist pause Sparkle
  updates, so an official release without this fix cannot replace them.

## [1.12.1] — 2026-09-25

### Fixed
- Manual Refresh and CLI refresh request new Claude API reports instead of
  reusing the five-minute automatic-polling cache. Failed manual requests
  remain visible instead of being replaced by an older cached success.
- Show the Claude API report cutoff and distinguish when it was checked from
  how much usage Anthropic has reported. Flag when today's spending is absent.

## [1.12.0] — 2026-09-25

### Added
- A separate Claude API provider with Keychain key entry, organization-wide
  month-to-date spending, and input/output/cache token counts. Requires access
  to Anthropic's organization reporting API. Prepaid credits are explicitly
  unavailable via API, with a link to Console billing.
- Optional API report details in the read-only agent snapshot.

### Fixed
- Provider-specific API key guidance now appears in Settings. Failed Keychain
  saves/removals are reported, and changing a key clears the previous report.

## [1.11.6] — 2026-09-25

### Fixed
- Load localization resources from inside the installed app. Previously, launch
  could depend on a temporary build folder and crash after that folder vanished.
- Packaging now fails if the required resource bundle is missing.
- Synchronize the Codex executable cache so simultaneous account refreshes
  cannot corrupt its stored path during startup.

## [1.11.5] — 2026-09-24

### Added
- Exact reset times now include a remaining duration in parentheses, with days
  and hours, hours and minutes, or minutes. The smaller unit rounds to the
  nearest value; under a minute is shown explicitly. Countdowns update while
  the menu or Usage Details is open and are included in VoiceOver descriptions.

## [1.11.4] — 2026-09-22

### Fixed
- The menu bar panel now scrolls long provider lists while keeping Refresh,
  Usage Details, Settings, updates, Support, and Quit visible below the list.
  Its height follows the popup's display, and short lists remain compact.
- A translucent bottom fade and small down chevron indicate more providers
  below; the cue disappears when the list reaches the bottom.

## [1.11.3] — 2026-09-21

### Changed
- Agent skill (`agentmeter skill`) now explains multiple Codex accounts
  (`codex` vs `codex:<uuid>`, matching your own account by `accountEmail`),
  `planType`, and that `renewal` is billing information, not quota.

### Documentation
- New docs/CODEX_ACCOUNTS.md guide (multi-account setup, how accounts appear,
  renewal tracking, troubleshooting). README, docs/AGENT_INTERFACE.md (schema
  history, multi-account ids, refresh cadence, debugging), docs/RELEASING.md
  (actual local flow, artifact table), the agent skill, and AGENTS.md brought
  in line with 1.11.x.

## [1.11.2] — 2026-09-21

### Added
- Settings → Providers → Codex accounts now auto-discovers `~/.codex-*` homes
  that already have a Codex login and offers a one-click **Add** (label taken
  from the folder name), so accounts signed in from Terminal show up
  without retyping paths.

## [1.11.1] — 2026-09-21

### Fixed
- The "Copy login command" for extra Codex accounts now creates the home
  directory first (`mkdir -p … && CODEX_HOME=… codex login`); Codex refuses
  to start when `CODEX_HOME` does not exist yet. Paths with spaces are quoted.

## [1.11.0] — 2026-09-21

### Added
- **Multiple Codex accounts.** Add extra Codex homes in Settings → Providers
  (sign in with `CODEX_HOME=~/.codex-<label> codex login`); each account gets
  its own meter, menu bar entry (`CxW`, …), email and plan label, and snapshot
  entry (`codex:<id>`). AgentMeter never performs logins or reads tokens.
- **Live Codex data via the app-server protocol.** Codex usage now comes from
  `codex app-server` (`account/rateLimits/read`, `account/read`) — spawned for
  about a second, polled every 5 minutes — instead of only the last session
  log, which could be hours or days stale. Session logs remain the instant
  in-session update path and the offline fallback.
- **Subscription renewal tracking** for Codex accounts: record the renewal
  date and billing platform (ChatGPT / Apple / Google Play), see the expected
  next renewal as a distinct row (never mixed with usage windows), mark it
  confirmed, and get an optional reminder 1/3/7 days before.
- Snapshot schema (still v1, additive): `accountEmail`, `planType`, and
  `renewal { expectedAt, platform, confirmedAt }` per provider.
- `AGENTMETER_DEBUG=1` enables structural stderr tracing for development.

## [1.10.0] — 2026-09-21

### Added
- Agent skill: `agentmeter skill` prints a ready-to-install `SKILL.md`
  (canonical copy in docs/agent-skill/) that teaches Codex, Claude Code, and
  Cursor agents to check remaining quota before large tasks, interpret the
  snapshot, and never read credentials themselves.
- Settings → General → "Install Command-Line Tool…" symlinks the bundled CLI
  into `/usr/local/bin` (with the standard admin prompt when required) and
  shows whether `agentmeter` is already on your PATH.

### Fixed
- `agentmeter doctor` now prints balances with two decimals instead of raw
  floating-point values.

## [1.9.0] — 2026-07-28

### Added
- Agent & CLI access (opt-in, Settings → General): AgentMeter writes an
  atomic, schema-versioned `status.json` snapshot (usage numbers only, never
  credentials) to Application Support after each refresh.
- Bundled `agentmeter` CLI (`Contents/Helpers/agentmeter`, on PATH via
  Homebrew): `status [--json]`, `refresh [--wait N]`, and a redacted `doctor`
  report. The CLI is a thin read-only client — the app remains the only
  process that touches credentials or provider APIs.
- `agentmeter://refresh` and `agentmeter://details` URL actions.
- Usage Details window (⌘D from the dropdown): the same provider meters in a
  regular, resizable window — friendlier for screen sharing and
  computer-control agents.
- Schema and security model documented in docs/AGENT_INTERFACE.md.

## [1.8.0] — 2026-07-23

### Added
- VoiceOver support for the menu bar item: the rendered title now carries a
  spoken summary ("AgentMeter. Codex: 25% used. Cursor: 82% used, high
  usage…") in all display styles, including icon-only mode.
- Usage meters, balance rows, and provider sections are proper accessibility
  elements with spoken labels, values, reset times, and severity qualifiers
  ("high usage", "nearly used up", "low balance", "data is stale") that
  respect the used/remaining display setting.
- Severity is no longer color-only: meters and low balances show a small
  warning/critical symbol alongside the tinted bar and text.
- VoiceOver announcements for key actions: diagnostics copied, API key
  saved/removed, OpenRouter connected or failed.
- Copy Diagnostics now confirms visually with a checkmark.

### Changed
- Provider dashboard names and footer controls expose proper link/button
  semantics, tooltips, and accessibility labels.
- Disabled alert pickers explain that notifications must be enabled first.
- Low-balance tinting in the dropdown now follows the alert threshold setting
  instead of a hardcoded $5.

## [1.7.0] — 2026-07-23

### Added
- Key type detection: after saving or connecting an API key, Settings shows
  what kind of key it is (e.g. Venice Admin vs. Inference, OpenRouter
  management/limited/standard, Z.ai GLM Coding Plan vs. standard) with a
  plain-language summary written for non-technical users.
- An expandable "About this key" section under each saved credential explains
  what the key can do, confirms AgentMeter only reads usage/balance and can
  never spend, and links directly to the provider's key-management page.
- Least-privilege guidance: when a safer key type would work equally well
  (e.g. a Venice Inference key), AgentMeter says so instead of pushing users
  toward more powerful keys.

## [1.6.6] — 2026-07-23

### Fixed
- Venice Inference API keys now fall back to `/api_keys/rate_limits` for
  USD/DIEM balances when the Admin-only billing endpoint returns 401.
- Venice billing responses now decode the production lowercase, nullable, and
  string-encoded balance fields (not only the older uppercase test fixture).
- Venice Settings explain supported key types and the x402 wallet limitation.

## [1.6.5] — 2026-07-23

### Changed
- Z.ai credential setup is explicitly labeled as a GLM Coding Plan API key and
  explains that standard API billing/balance cannot be queried. The key field
  remains because Coding Plan monitoring itself authenticates with that key.

## [1.6.4] — 2026-07-23

### Fixed
- Z.ai no longer reports a valid standard API key as rejected when the account
  has no GLM Coding Plan. It now explains that quota monitoring is Coding
  Plan–only. Other API body errors are also reported accurately.

## [1.6.3] — 2026-07-23

### Fixed
- OpenRouter OAuth-provisioned keys now use the regular-key `/api/v1/key`
  endpoint, with account credits as optional enrichment. The previous
  implementation depended only on `/credits`, which OpenRouter documents as a
  management-key endpoint.
- OpenRouter PKCE verifier persists across app activation/relaunch during the
  browser callback; connection progress and failures are visible in Settings.
- OpenRouter Settings now offers manual API-key paste as a fallback.
- Fixed an extra parenthesis in the OpenRouter HTTP error message.

## [1.6.2] — 2026-07-23

### Changed
- Release tooling: notarization credentials now sourced from 1Password (op-sa) instead of machine-local paths. No user-facing changes.

## [1.6.1] — 2026-07-23

### Fixed
- App icon was distorted (non-square source stretched into the iconset); replaced with a correctly proportioned square icon.

## [1.6.0] — 2026-07-23

### Added
- Stale-data handling: when a refresh fails, the last-known meters stay visible
  (dimmed, with a "stale since" note) instead of being replaced by an error.
- Menu bar color states: provider entries tint yellow/red at the same
  thresholds as the meters; stale entries dim.
- Menu bar style picker: Full / Compact (worst only) / Icon only.
- Copy Diagnostics button (Settings → General): redacted troubleshooting
  report — never includes keys or tokens.
- About window with version, credits, and licenses.
- This changelog.

### Changed
- The menu bar title is now rendered as an image to support per-provider color.

## [1.5.0] — 2026-07-23

### Added
- Spanish localization; the app follows the macOS system language. All strings
  live in a String Catalog — community translations welcome.
- Homebrew tap: `brew install --cask fdtorres1/tap/agentmeter`.

## [1.4.0] — 2026-07-23

### Added
- Sparkle auto-updates with EdDSA-signed appcast served from the latest GitHub
  release. "Check for Updates…" now runs Sparkle's standard flow.

## [1.3.2] — 2026-07-23

### Changed
- Settings moved from the dropdown into a native tabbed window
  (General / Providers / Display / Alerts); the dropdown closes when opening it.
- Alert threshold labels follow the count-direction display setting.
- Provider monogram badges in Settings and the dropdown; unified footer styling.

## [1.3.0] — 2026-07-23

### Added
- Count direction display option ("% used" / "% left").
- Reset time display option (relative / exact date-time).
- Refresh on wake from sleep.
- Low-balance notifications for pay-as-you-go providers ($1/$5/$10).
- Menu bar options: per-provider visibility and compact mode.
- Click a provider's name to open its usage dashboard.

## [1.1.0] — 2026-07-22

### Added
- Five API-key providers: OpenRouter (OAuth PKCE or pasted key), DeepSeek,
  Kimi (Moonshot), Z.ai (coding-plan quota), Venice. Keys live in the macOS
  Keychain, masked in Settings, sent only to their own provider.
- Balance display for pay-as-you-go providers.
- Threshold notifications (opt-in, 70/80/90%, once per window).

## [1.0.0] — 2026-07-22

Initial release: menu bar meters for Codex/ChatGPT (5h + weekly), Cursor
(plan usage + billing cycle), Claude Code, and Gemini, with reset countdowns,
per-provider Auto/On/Off, launch at login, and zero telemetry. Signed and
notarized.
