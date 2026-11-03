import Foundation
import Combine
import AppKit

/// Holds the latest usage for all providers and refreshes them on a timer,
/// plus a file watcher so Codex numbers update right after CLI activity.
@MainActor
final class UsageStore: ObservableObject {
    /// Per-provider state, keyed by provider id.
    @Published private(set) var states: [String: ProviderState] = [:]
    @Published var lastRefreshed: Date?

    @Published private(set) var providers: [any UsageProvider]
    let settings: SettingsStore
    lazy var notificationManager = NotificationManager()

    private let codexReader = CodexUsageReader()
    private var timer: Timer?
    private var sessionWatcher: DispatchSourceFileSystemObject?
    private var watchedFile: URL?

    private var credentialsObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var refreshRequestObserver: NSObjectProtocol?
    private var accountsObserver: AnyCancellable?
    private var credentialGenerations: [String: Int] = [:]
    /// Nil when the provider list was injected (tests): the proxy's logins
    /// then never change it.
    private let proxyConfig: (@Sendable () -> CLIProxyConfig?)?

    init(
        settings: SettingsStore,
        providers: [any UsageProvider]? = nil,
        proxyConfig: (@Sendable () -> CLIProxyConfig?)? = nil
    ) {
        self.settings = settings
        if let proxyConfig {
            self.proxyConfig = proxyConfig
        } else if providers == nil {
            self.proxyConfig = { @Sendable in CLIProxyConfig.current() }
        } else {
            self.proxyConfig = nil
        }
        self.providers = providers ?? Self.defaultProviders(
            extraAccounts: settings.extraAccounts,
            proxyLogins: settings.cliProxyLogins
        )
        for provider in self.providers {
            states[provider.id] = .loading
        }
        refresh()
        rescheduleTimer()
        accountsObserver = settings.$extraAccounts
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] accounts in
                // @Published emits before the property changes, so use the value.
                self?.rebuildProviders(extraAccounts: accounts)
            }
        credentialsObserver = NotificationCenter.default.addObserver(
            forName: .providerCredentialsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refreshRequestObserver = NotificationCenter.default.addObserver(
            forName: .agentMeterRefreshRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh(forceRefresh: true) }
        }
    }

    nonisolated static var defaultProviders: [any UsageProvider] {
        defaultProviders(extraAccounts: [])
    }

    /// Base providers in display order, each followed by its extra accounts
    /// and then its CLIProxyAPI logins. Antigravity has no local provider, so
    /// its proxy logins follow Gemini's.
    nonisolated static func defaultProviders(
        extraAccounts: [ProviderAccountConfig],
        proxyLogins: [CLIProxyLoginKey] = []
    ) -> [any UsageProvider] {
        let bases: [any UsageProvider] = [
            CodexProvider(), CursorProvider(), ClaudeProvider(), ClaudeAPIProvider(), GeminiProvider(),
            OpenRouterProvider(), DeepSeekProvider(), MoonshotProvider(),
            ZaiProvider(), VeniceProvider(),
        ]
        func proxyRows(_ baseID: String) -> [any UsageProvider] {
            proxyLogins
                .filter { $0.kind.baseProviderID == baseID }
                .map { CLIProxyAccountProvider(login: $0) }
        }
        return bases.flatMap { base -> [any UsageProvider] in
            var rows: [any UsageProvider] = [base]
            rows += extraAccounts
                .filter { $0.baseProviderID == base.id }
                .compactMap { $0.makeProvider() }
            rows += proxyRows(base.id)
            if base.id == "gemini" {
                rows += proxyRows(CLIProxyLoginKind.antigravity.baseProviderID)
            }
            return rows
        }
    }

    func rebuildProviders(
        extraAccounts: [ProviderAccountConfig]? = nil,
        proxyLogins: [CLIProxyLoginKey]? = nil,
        forceRefresh: Bool = false
    ) {
        let newProviders = Self.defaultProviders(
            extraAccounts: extraAccounts ?? settings.extraAccounts,
            proxyLogins: proxyLogins ?? settings.cliProxyLogins
        )
        let oldIDs = Set(providers.map(\.id))
        let newIDs = Set(newProviders.map(\.id))
        providers = newProviders
        for removed in oldIDs.subtracting(newIDs) {
            states.removeValue(forKey: removed)
            CodexAccountCache.shared.clear(providerID: removed)
        }
        for added in newIDs.subtracting(oldIDs) {
            states[added] = .loading
        }
        refresh(forceRefresh: forceRefresh)
    }

    deinit {
        timer?.invalidate()
        sessionWatcher?.cancel()
        if let credentialsObserver {
            NotificationCenter.default.removeObserver(credentialsObserver)
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if let refreshRequestObserver {
            NotificationCenter.default.removeObserver(refreshRequestObserver)
        }
    }

    func rescheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            withTimeInterval: settings.refreshInterval,
            repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.refresh() }
        }
    }

    /// Providers currently visible per settings (mode + detection). A
    /// CLIProxyAPI login left on Auto is hidden while an account on this Mac
    /// shows the same email for the same provider.
    var visibleProviders: [any UsageProvider] {
        let shown = providers.filter { settings.mode(for: $0.id).isVisible(detected: $0.isDetected) }
        let local = localAccountEmails(among: shown)
        return shown.filter { provider in
            guard let proxy = provider as? CLIProxyAccountProvider,
                  settings.mode(for: provider.id) == .auto else { return true }
            return Self.localDuplicate(of: proxy.login, in: local) == nil
        }
    }

    /// The name of the account on this Mac that a proxy row duplicates, if any.
    func localDuplicateName(of provider: any UsageProvider) -> String? {
        guard let proxy = provider as? CLIProxyAccountProvider else { return nil }
        let shown = providers.filter { settings.mode(for: $0.id).isVisible(detected: $0.isDetected) }
        return Self.localDuplicate(of: proxy.login, in: localAccountEmails(among: shown))
    }

    /// How long a local account may fail (showing stale data) before its
    /// proxy row takes over. Short failures don't make rows come and go.
    static let localFailureGrace: TimeInterval = 10 * 60

    /// Email of every shown non-proxy account: from its latest data, or the
    /// last known one while it loads. An account in error, or stale for
    /// longer than `localFailureGrace`, has none, so its proxy row takes over.
    private func localAccountEmails(among shown: [any UsageProvider]) -> [(providerID: String, name: String, email: String)] {
        let remembered = settings.localAccountEmails
        let now = Date()
        return shown.compactMap { provider in
            guard !(provider is CLIProxyAccountProvider) else { return nil }
            let email: String?
            switch state(for: provider.id) {
            case .ready(let usage): email = usage.accountEmail
            case .stale(let usage, _, let since):
                email = now.timeIntervalSince(since) < Self.localFailureGrace ? usage.accountEmail : nil
            case .loading: email = remembered[provider.id]
            case .error: email = nil
            }
            guard let email, !email.isEmpty else { return nil }
            return (provider.id, provider.displayName, email)
        }
    }

    nonisolated static func localDuplicate(
        of login: CLIProxyLoginKey,
        in local: [(providerID: String, name: String, email: String)]
    ) -> String? {
        local.first { entry in
            ProviderAccountConfig.baseProviderID(of: entry.providerID) == login.kind.baseProviderID
                && entry.email.caseInsensitiveCompare(login.email) == .orderedSame
        }?.name
    }

    func state(for providerID: String) -> ProviderState {
        states[providerID] ?? .loading
    }

    /// A replacement key may identify a different organization. Clear the old
    /// report and prevent an in-flight request from restoring it afterwards.
    func credentialDidChange(for providerID: String) {
        credentialsDidChange(for: [providerID])
    }

    /// Same as `credentialDidChange(for:)` for several providers, with one refresh.
    func credentialsDidChange(for providerIDs: [String]) {
        for providerID in providerIDs {
            credentialGenerations[providerID, default: 0] += 1
            states[providerID] = .loading
        }
        refresh()
    }

    func refresh(forceRefresh: Bool = false) {
        watchNewestCodexSession()
        lastRefreshed = Date()
        Task {
            // A changed login list rebuilds the rows, which starts a new refresh.
            if await syncProxyLogins(forceRefresh: forceRefresh) { return }
            var fetched = Set<String>()
            var pending = visibleProviders
            // A local account that fails can reveal its proxy row, so fetch
            // rows that became visible during the first pass too.
            while !pending.isEmpty {
                fetched.formUnion(pending.map(\.id))
                await withTaskGroup(of: Void.self) { group in
                    for provider in pending {
                        group.addTask {
                            await self.refreshProvider(provider, forceRefresh: forceRefresh)
                            DebugLog.write("refresh: \(provider.id) done")
                        }
                    }
                }
                pending = visibleProviders.filter { !fetched.contains($0.id) }
            }
            DebugLog.write("refresh: all done, writing snapshot")
            StatusSnapshotWriter.writeIfEnabled(store: self, settings: settings)
        }
    }

    /// Updates the rows to match the proxy's logins. Returns true when the
    /// list changed and the rows were rebuilt. When the proxy can't be
    /// reached, the last known rows stay and show the error themselves.
    private func syncProxyLogins(forceRefresh: Bool) async -> Bool {
        guard let proxyConfig else { return false }
        let logins: [CLIProxyLoginKey]
        if let config = proxyConfig() {
            guard let accounts = try? await CLIProxyClient(config: config).logins() else { return false }
            logins = CLIProxyLoginKey.keys(from: accounts)
        } else {
            logins = []
        }
        guard logins != settings.cliProxyLogins else { return false }
        settings.cliProxyLogins = logins
        rebuildProviders(proxyLogins: logins, forceRefresh: forceRefresh)
        return true
    }

    private func refreshProvider(_ provider: any UsageProvider, forceRefresh: Bool) async {
        let generation = credentialGenerations[provider.id, default: 0]
        do {
            let usage = try await provider.fetch(forceRefresh: forceRefresh)
            guard credentialGenerations[provider.id, default: 0] == generation else { return }
            states[provider.id] = .ready(usage)
            if !(provider is CLIProxyAccountProvider), let email = usage.accountEmail,
               settings.localAccountEmails[provider.id] != email {
                settings.localAccountEmails[provider.id] = email
            }
            notificationManager.notifyIfNeeded(
                provider: provider,
                usage: usage,
                settings: settings
            )
        } catch {
            guard credentialGenerations[provider.id, default: 0] == generation else { return }
            let previous = states[provider.id] ?? .loading
            states[provider.id] = ProviderState.nextState(
                after: previous,
                failure: ErrorRedaction.redact(error.localizedDescription),
                at: Date()
            )
        }
    }

    private var titleProviders: [any UsageProvider] {
        visibleProviders.filter { settings.showsInMenuBar($0.id) }
    }

    /// Colored menu bar segments with per-provider severity.
    var menuBarEntries: [(text: String, severity: MenuBarSeverity)] {
        menuBarEntries(allWindows: settings.menuBarShowsAllLimits)
    }

    private func menuBarEntries(
        allWindows: Bool,
        showsPace: Bool = false
    ) -> [(text: String, severity: MenuBarSeverity)] {
        let providers = titleProviders
        guard !providers.isEmpty else { return [("Allowance Bar", .normal)] }

        switch settings.menuBarStyle {
        case .full:
            return providers.map { providerMenuBarEntry(for: $0, allWindows: allWindows, showsPace: showsPace) }
        case .compact:
            if let entry = mostConstrainedMenuBarEntry(from: providers, allWindows: allWindows, showsPace: showsPace) {
                return [entry]
            }
            return providers.map { providerMenuBarEntry(for: $0, allWindows: allWindows, showsPace: showsPace) }
        case .icon:
            return []
        }
    }

    /// The menu bar text for the nano Usage Details panel, with its own
    /// all-limits setting. With the icon-only menu bar style it falls back to
    /// every menu bar provider, since a lone icon would tell nothing.
    var nanoEntries: [(text: String, severity: MenuBarSeverity)] {
        let allWindows = settings.nanoShowsAllLimits
        let showsPace = settings.nanoShowsPace
        guard settings.menuBarStyle == .icon else {
            return menuBarEntries(allWindows: allWindows, showsPace: showsPace)
        }
        let providers = titleProviders
        guard !providers.isEmpty else { return [("Allowance Bar", .normal)] }
        return providers.map { providerMenuBarEntry(for: $0, allWindows: allWindows, showsPace: showsPace) }
    }

    /// One menu-bar-style entry per visible provider for the compact Usage
    /// Details window. Unlike `menuBarEntries`, it ignores the menu bar style
    /// and per-provider menu bar visibility.
    var compactEntries: [CompactUsageEntry] {
        visibleProviders.map { provider in
            let providerState = state(for: provider.id)
            return CompactUsageEntry(
                provider: provider,
                windows: providerState.usage?.windows ?? [],
                summary: providerSummaryText(for: providerState),
                severity: MenuBarTitleRenderer.severity(
                    for: providerState,
                    balanceThreshold: settings.balanceNotificationThreshold
                ),
                accessibilityLabel: MenuBarAccessibilitySummary.providerSegment(
                    displayName: provider.displayName,
                    state: providerState,
                    countDirection: settings.countDirection,
                    balanceThreshold: settings.balanceNotificationThreshold
                )
            )
        }
    }

    /// Worst severity across title providers (for icon-only menu bar style).
    var worstMenuBarSeverity: MenuBarSeverity {
        let providers = titleProviders
        guard !providers.isEmpty else { return .normal }

        let severities = providers.map {
            MenuBarTitleRenderer.severity(
                for: state(for: $0.id),
                balanceThreshold: settings.balanceNotificationThreshold
            )
        }
        return Self.worstSeverity(severities)
    }

    /// Menu bar text, e.g. "Cx 5% · Cu 20%". Only visible providers with menu-bar
    /// visibility appear; compact mode shows the single most constrained entry.
    var menuBarTitle: String {
        menuBarEntries.map(\.text).joined(separator: " · ")
    }

    /// Spoken summary for the raster menu bar title (VoiceOver).
    var menuBarAccessibilityDescription: String {
        accessibilityDescription(allWindows: settings.menuBarShowsAllLimits)
    }

    /// Spoken summary for the nano panel, matching `nanoEntries`.
    var nanoAccessibilityDescription: String {
        accessibilityDescription(allWindows: settings.nanoShowsAllLimits, includesPace: settings.nanoShowsPace)
    }

    private func accessibilityDescription(allWindows: Bool, includesPace: Bool = false) -> String {
        MenuBarAccessibilitySummary.build(
            providers: menuBarSummaryProviders.map {
                MenuBarAccessibilitySummary.ProviderInput(
                    displayName: $0.displayName,
                    state: state(for: $0.id)
                )
            },
            countDirection: settings.countDirection,
            balanceThreshold: settings.balanceNotificationThreshold,
            allWindows: allWindows,
            includesPace: includesPace
        )
    }

    /// Providers included in the spoken menu bar summary (icon mode always lists all).
    private var menuBarSummaryProviders: [any UsageProvider] {
        let providers = titleProviders
        guard !providers.isEmpty else { return [] }

        switch settings.menuBarStyle {
        case .full, .icon:
            return providers
        case .compact:
            if let provider = mostConstrainedMenuBarProvider(from: providers) {
                return [provider]
            }
            return providers
        }
    }

    private func providerMenuBarEntry(
        for provider: any UsageProvider,
        allWindows: Bool,
        showsPace: Bool = false
    ) -> (text: String, severity: MenuBarSeverity) {
        let providerState = state(for: provider.id)
        let summary = providerSummaryText(for: providerState, allWindows: allWindows, showsPace: showsPace)
        return (
            "\(provider.shortCode) \(summary)",
            MenuBarTitleRenderer.severity(
                for: providerState,
                balanceThreshold: settings.balanceNotificationThreshold
            )
        )
    }

    private func providerSummaryText(
        for state: ProviderState,
        allWindows: Bool = false,
        showsPace: Bool = false
    ) -> String {
        switch state {
        case .loading:
            return "…"
        case .error:
            return "!"
        case .ready(let usage), .stale(let usage, _, _):
            return usage.menuSummary(
                direction: settings.countDirection,
                allWindows: allWindows,
                showsPace: showsPace
            ) ?? "?"
        }
    }

    private func mostConstrainedMenuBarProvider(
        from providers: [any UsageProvider]
    ) -> (any UsageProvider)? {
        var bestPercent: (provider: any UsageProvider, used: Double)?
        var firstBalance: (provider: any UsageProvider, usage: ProviderUsage)?

        for provider in providers {
            guard let usage = state(for: provider.id).usage else { continue }
            if let worst = usage.worstWindow {
                if bestPercent == nil || worst.usedPercent > bestPercent!.used {
                    bestPercent = (provider, worst.usedPercent)
                }
            } else if usage.balance != nil, firstBalance == nil {
                firstBalance = (provider, usage)
            }
        }

        if let best = bestPercent {
            return best.provider
        }
        if let balance = firstBalance {
            return balance.provider
        }
        return nil
    }

    private func mostConstrainedMenuBarEntry(
        from providers: [any UsageProvider],
        allWindows: Bool,
        showsPace: Bool = false
    ) -> (text: String, severity: MenuBarSeverity)? {
        guard let provider = mostConstrainedMenuBarProvider(from: providers) else { return nil }
        return providerMenuBarEntry(for: provider, allWindows: allWindows, showsPace: showsPace)
    }

    nonisolated private static func worstSeverity(_ severities: [MenuBarSeverity]) -> MenuBarSeverity {
        let rank: (MenuBarSeverity) -> Int = { severity in
            switch severity {
            case .critical: return 3
            case .warning: return 2
            case .stale: return 1
            case .normal: return 0
            }
        }
        return severities.max(by: { rank($0) < rank($1) }) ?? .normal
    }

    // MARK: - Codex session file watching

    /// Watches the newest rollout file so appended token_count events update the
    /// Codex meter immediately, without waiting for the next timer tick.
    private func watchNewestCodexSession() {
        let primaryCodex = providers.first { $0.id == "codex" }
        guard let primaryCodex,
              settings.mode(for: "codex").isVisible(detected: primaryCodex.isDetected),
              let newest = codexReader.recentSessionFiles(limit: 1).first,
              newest != watchedFile else {
            return
        }

        sessionWatcher?.cancel()
        sessionWatcher = nil
        watchedFile = nil

        let descriptor = open(newest.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.refreshProvider(primaryCodex, forceRefresh: false) }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        sessionWatcher = source
        watchedFile = newest
    }
}

/// A provider's limit windows plus its menu-bar-style summary, e.g. "42%",
/// for the compact Usage Details window. The summary is shown for providers
/// without limit windows (balances, loading, errors).
struct CompactUsageEntry: Identifiable {
    let provider: any UsageProvider
    let windows: [UsageWindow]
    let summary: String
    let severity: MenuBarSeverity
    let accessibilityLabel: String

    var id: String { provider.id }
}
