import Foundation
import Combine

enum CountDirection: String {
    case used, remaining

    nonisolated func displayPercent(_ usedPercent: Double) -> Double {
        switch self {
        case .used: return usedPercent
        case .remaining: return 100 - usedPercent
        }
    }

    nonisolated func percentLabel(_ usedPercent: Double, menuBar: Bool = false) -> String {
        let value = Int(displayPercent(usedPercent).rounded())
        switch self {
        case .used: return L("\(value)%")
        case .remaining: return menuBar ? L("\(value)%") : L("\(value)% left")
        }
    }
}

enum ResetTimeStyle: String {
    case relative, absolute
}

enum MenuBarStyle: String {
    case full, compact, icon
}

/// User preferences: per-provider visibility and refresh cadence.
@MainActor
final class SettingsStore: ObservableObject {
    @Published var refreshInterval: TimeInterval {
        didSet { defaults.set(refreshInterval, forKey: Keys.refreshInterval) }
    }

    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled) }
    }

    @Published var notificationThreshold: Double {
        didSet { defaults.set(notificationThreshold, forKey: Keys.notificationThreshold) }
    }

    @Published var countDirection: CountDirection {
        didSet { defaults.set(countDirection.rawValue, forKey: Keys.countDirection) }
    }

    @Published var resetTimeStyle: ResetTimeStyle {
        didSet { defaults.set(resetTimeStyle.rawValue, forKey: Keys.resetTimeStyle) }
    }

    @Published var balanceNotificationThreshold: Double {
        didSet { defaults.set(balanceNotificationThreshold, forKey: Keys.balanceNotificationThreshold) }
    }

    @Published var menuBarStyle: MenuBarStyle {
        didSet { defaults.set(menuBarStyle.rawValue, forKey: Keys.menuBarStyle) }
    }

    /// Menu bar shows every limit window per provider, e.g. "Cx 8% (35%)",
    /// instead of only the most constrained one.
    @Published var menuBarShowsAllLimits: Bool {
        didSet { defaults.set(menuBarShowsAllLimits, forKey: Keys.menuBarShowsAllLimits) }
    }

    /// Same as `menuBarShowsAllLimits`, for the nano Usage Details panel.
    @Published var nanoShowsAllLimits: Bool {
        didSet { defaults.set(nanoShowsAllLimits, forKey: Keys.nanoShowsAllLimits) }
    }

    @Published var usageDetailsAlwaysOnTop: Bool {
        didSet { defaults.set(usageDetailsAlwaysOnTop, forKey: Keys.usageDetailsAlwaysOnTop) }
    }

    @Published var usageDetailsCompact: Bool {
        didSet { defaults.set(usageDetailsCompact, forKey: Keys.usageDetailsCompact) }
    }

    /// The smallest Usage Details panel: only the menu bar text. Takes
    /// precedence over `usageDetailsCompact`.
    @Published var usageDetailsNano: Bool {
        didSet { defaults.set(usageDetailsNano, forKey: Keys.usageDetailsNano) }
    }

    /// Either chrome-free panel (compact or nano) is showing.
    var usageDetailsChromeless: Bool {
        usageDetailsCompact || usageDetailsNano
    }

    /// Opacity of the Usage Details window's translucent background, 0...1.
    /// Text and meters stay fully opaque.
    @Published var usageDetailsBackgroundOpacity: Double {
        didSet { defaults.set(usageDetailsBackgroundOpacity, forKey: Keys.usageDetailsBackgroundOpacity) }
    }

    /// Legacy background preference, retained for compatibility with older
    /// builds. The window now uses standard material with adjustable opacity.
    @Published var usageDetailsClearGlass: Bool {
        didSet { defaults.set(usageDetailsClearGlass, forKey: Keys.usageDetailsClearGlass) }
    }

    /// Only applies while `usageDetailsAlwaysOnTop` is on.
    @Published var usageDetailsOnAllSpaces: Bool {
        didSet { defaults.set(usageDetailsOnAllSpaces, forKey: Keys.usageDetailsOnAllSpaces) }
    }

    @Published var agentAccessEnabled: Bool {
        didSet {
            defaults.set(agentAccessEnabled, forKey: Keys.agentAccessEnabled)
            if !agentAccessEnabled {
                StatusSnapshotWriter.deleteSnapshotFile()
            }
        }
    }

    /// Extra accounts for every provider, in the order they were added.
    @Published var extraAccounts: [ProviderAccountConfig] {
        didSet {
            if let data = try? JSONEncoder().encode(extraAccounts) {
                defaults.set(data, forKey: Keys.extraAccounts)
            } else {
                defaults.removeObject(forKey: Keys.extraAccounts)
            }
            // Keep the Codex-only list that versions up to 2.3 read, so a
            // downgrade still finds its Codex accounts.
            let legacy = extraAccounts.compactMap(LegacyCodexAccount.init(account:))
            if let data = try? JSONEncoder().encode(legacy) {
                defaults.set(data, forKey: Keys.codexExtraAccounts)
            }
        }
    }

    @Published var subscriptionRenewals: [String: SubscriptionRenewal] {
        didSet {
            if let data = try? JSONEncoder().encode(subscriptionRenewals) {
                defaults.set(data, forKey: Keys.subscriptionRenewals)
            } else {
                defaults.removeObject(forKey: Keys.subscriptionRenewals)
            }
        }
    }

    /// CLIProxyAPI server address as typed; empty means the default.
    @Published var cliProxyURL: String {
        didSet { defaults.set(cliProxyURL, forKey: CLIProxyConfig.urlDefaultsKey) }
    }

    /// Proxy login email per Claude provider id; missing means match by email.
    @Published var cliProxyClaudeEmails: [String: String] {
        didSet { defaults.set(cliProxyClaudeEmails, forKey: CLIProxyConfig.claudeEmailsDefaultsKey) }
    }

    private let defaults: UserDefaults
    private var modeCache: [String: ProviderMode] = [:]
    private var menuBarCache: [String: Bool] = [:]

    static let refreshOptions: [(label: String, seconds: TimeInterval)] = [
        (L("30 seconds"), 30),
        (L("1 minute"), 60),
        (L("5 minutes"), 300),
    ]

    static let notificationThresholdOptions: [Double] = [70, 80, 90]
    static let balanceThresholdOptions: [Double] = [1, 5, 10]

    private enum Keys {
        static let refreshInterval = "refreshInterval"
        static let notificationsEnabled = "notificationsEnabled"
        static let notificationThreshold = "notificationThreshold"
        static let countDirection = "countDirection"
        static let resetTimeStyle = "resetTimeStyle"
        static let balanceNotificationThreshold = "balanceNotificationThreshold"
        static let menuBarStyle = "menuBarStyle"
        static let menuBarShowsAllLimits = "menuBarShowsAllLimits"
        static let nanoShowsAllLimits = "nanoShowsAllLimits"
        static let agentAccessEnabled = "agentAccessEnabled"
        static let usageDetailsAlwaysOnTop = "usageDetailsAlwaysOnTop"
        static let usageDetailsOnAllSpaces = "usageDetailsOnAllSpaces"
        static let usageDetailsCompact = "usageDetailsCompact"
        static let usageDetailsNano = "usageDetailsNano"
        static let usageDetailsBackgroundOpacity = "usageDetailsBackgroundOpacity"
        static let usageDetailsClearGlass = "usageDetailsClearGlass"
        static let codexExtraAccounts = "codexExtraAccounts"
        static let extraAccounts = "providerExtraAccounts"
        static let subscriptionRenewals = "subscriptionRenewals"
        static let compactMenuBar = "compactMenuBar"
        static func mode(_ id: String) -> String { "provider.\(id).mode" }
        static func inMenuBar(_ id: String) -> String { "provider.\(id).inMenuBar" }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.double(forKey: Keys.refreshInterval)
        self.refreshInterval = stored > 0 ? stored : 60
        self.notificationsEnabled = defaults.bool(forKey: Keys.notificationsEnabled)
        let storedThreshold = defaults.double(forKey: Keys.notificationThreshold)
        self.notificationThreshold = Self.notificationThresholdOptions.contains(storedThreshold)
            ? storedThreshold
            : 80
        let storedDirection = defaults.string(forKey: Keys.countDirection)
        self.countDirection = storedDirection.flatMap(CountDirection.init(rawValue:)) ?? .used
        let storedResetStyle = defaults.string(forKey: Keys.resetTimeStyle)
        self.resetTimeStyle = storedResetStyle.flatMap(ResetTimeStyle.init(rawValue:)) ?? .relative
        let storedBalanceThreshold = defaults.double(forKey: Keys.balanceNotificationThreshold)
        self.balanceNotificationThreshold = Self.balanceThresholdOptions.contains(storedBalanceThreshold)
            ? storedBalanceThreshold
            : 5
        if let storedStyle = defaults.string(forKey: Keys.menuBarStyle),
           let style = MenuBarStyle(rawValue: storedStyle) {
            self.menuBarStyle = style
        } else if defaults.object(forKey: Keys.compactMenuBar) != nil,
                  defaults.bool(forKey: Keys.compactMenuBar) {
            self.menuBarStyle = .compact
        } else {
            self.menuBarStyle = .full
        }
        self.menuBarShowsAllLimits = defaults.bool(forKey: Keys.menuBarShowsAllLimits)
        // Until set on its own, follows the menu bar setting it was split from.
        self.nanoShowsAllLimits = defaults.object(forKey: Keys.nanoShowsAllLimits) as? Bool
            ?? defaults.bool(forKey: Keys.menuBarShowsAllLimits)
        self.usageDetailsAlwaysOnTop = defaults.bool(forKey: Keys.usageDetailsAlwaysOnTop)
        self.usageDetailsOnAllSpaces = defaults.bool(forKey: Keys.usageDetailsOnAllSpaces)
        self.usageDetailsCompact = defaults.bool(forKey: Keys.usageDetailsCompact)
        self.usageDetailsNano = defaults.bool(forKey: Keys.usageDetailsNano)
        if defaults.object(forKey: Keys.usageDetailsBackgroundOpacity) != nil {
            self.usageDetailsBackgroundOpacity = min(1, max(0, defaults.double(forKey: Keys.usageDetailsBackgroundOpacity)))
        } else {
            self.usageDetailsBackgroundOpacity = 1
        }
        self.usageDetailsClearGlass = defaults.bool(forKey: Keys.usageDetailsClearGlass)
        self.agentAccessEnabled = defaults.bool(forKey: Keys.agentAccessEnabled)
        if let data = defaults.data(forKey: Keys.extraAccounts),
           let accounts = try? JSONDecoder().decode([ProviderAccountConfig].self, from: data) {
            self.extraAccounts = accounts
        } else if let data = defaults.data(forKey: Keys.codexExtraAccounts),
                  let legacy = try? JSONDecoder().decode([LegacyCodexAccount].self, from: data) {
            // Same UUIDs, so ids, visibility, and renewals carry over.
            self.extraAccounts = legacy.map(\.account)
        } else {
            self.extraAccounts = []
        }
        if let data = defaults.data(forKey: Keys.subscriptionRenewals),
           let renewals = try? JSONDecoder().decode([String: SubscriptionRenewal].self, from: data) {
            self.subscriptionRenewals = renewals
        } else {
            self.subscriptionRenewals = [:]
        }
        self.cliProxyURL = defaults.string(forKey: CLIProxyConfig.urlDefaultsKey) ?? ""
        self.cliProxyClaudeEmails = defaults.dictionary(forKey: CLIProxyConfig.claudeEmailsDefaultsKey)
            as? [String: String] ?? [:]
    }

    func addAccount(_ account: ProviderAccountConfig) {
        extraAccounts.append(account)
    }

    func accounts(for baseProviderID: String) -> [ProviderAccountConfig] {
        extraAccounts.filter { $0.baseProviderID == baseProviderID }
    }

    /// Empty labels are ignored. The id stays the same, so the account keeps
    /// its settings, key, and renewal date.
    func renameAccount(id: UUID, to label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = extraAccounts.firstIndex(where: { $0.id == id }) else { return }
        extraAccounts[index].label = trimmed
    }

    func removeAccount(id: UUID) {
        guard let account = extraAccounts.first(where: { $0.id == id }) else { return }
        removeRenewal(for: account.providerID)
        cliProxyClaudeEmails.removeValue(forKey: account.providerID)
        extraAccounts.removeAll { $0.id == id }
    }

    func renewal(for providerID: String) -> SubscriptionRenewal? {
        subscriptionRenewals[providerID]
    }

    func setRenewal(_ renewal: SubscriptionRenewal, for providerID: String) {
        subscriptionRenewals[providerID] = renewal
    }

    func removeRenewal(for providerID: String) {
        subscriptionRenewals.removeValue(forKey: providerID)
    }

    func mode(for providerID: String) -> ProviderMode {
        if let cached = modeCache[providerID] { return cached }
        let raw = defaults.string(forKey: Keys.mode(providerID))
        let mode = raw.flatMap(ProviderMode.init(rawValue:)) ?? .auto
        modeCache[providerID] = mode
        return mode
    }

    func setMode(_ mode: ProviderMode, for providerID: String) {
        modeCache[providerID] = mode
        defaults.set(mode.rawValue, forKey: Keys.mode(providerID))
        objectWillChange.send()
    }

    func showsInMenuBar(_ providerID: String) -> Bool {
        if let cached = menuBarCache[providerID] { return cached }
        let shows: Bool
        if defaults.object(forKey: Keys.inMenuBar(providerID)) == nil {
            shows = true
        } else {
            shows = defaults.bool(forKey: Keys.inMenuBar(providerID))
        }
        menuBarCache[providerID] = shows
        return shows
    }

    func setShowsInMenuBar(_ shows: Bool, for providerID: String) {
        menuBarCache[providerID] = shows
        defaults.set(shows, forKey: Keys.inMenuBar(providerID))
        objectWillChange.send()
    }
}

/// The `codexExtraAccounts` entry format used up to 2.3.
private struct LegacyCodexAccount: Codable {
    let id: UUID
    var label: String
    var codexHomePath: String

    init?(account: ProviderAccountConfig) {
        guard account.baseProviderID == "codex", let path = account.homePath else { return nil }
        self.id = account.id
        self.label = account.label
        self.codexHomePath = path
    }

    var account: ProviderAccountConfig {
        ProviderAccountConfig(id: id, baseProviderID: "codex", label: label, homePath: codexHomePath)
    }
}
