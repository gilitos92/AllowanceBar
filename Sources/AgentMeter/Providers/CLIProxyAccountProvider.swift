import CryptoKit
import Foundation

/// Identifies one login on the CLIProxyAPI server across refreshes. Holds no
/// credential; the proxy's `auth_index` is looked up fresh on each fetch.
struct CLIProxyLoginKey: Codable, Equatable, Hashable, Sendable {
    let kind: CLIProxyLoginKind
    let email: String
    /// Gemini only: CLIProxyAPI can hold one login per project for the same
    /// email, and each project has its own quota.
    let projectID: String?
    /// Codex only: the ChatGPT workspace. One email can sign in to a personal
    /// and a team workspace, and each has its own limits.
    let accountID: String?
    /// Codex only: the workspace's plan, used to tell which proxy login an
    /// account on this Mac matches. Not part of the row's id.
    let planType: String?

    init(
        kind: CLIProxyLoginKind,
        email: String,
        projectID: String? = nil,
        accountID: String? = nil,
        planType: String? = nil
    ) {
        self.kind = kind
        self.email = email
        self.projectID = kind == .gemini ? projectID : nil
        self.accountID = kind == .codex ? accountID : nil
        self.planType = kind == .codex ? planType : nil
    }

    init(account: CLIProxyClient.Account) {
        self.init(
            kind: account.kind,
            email: account.email,
            projectID: account.projectID,
            accountID: account.chatgptAccountID,
            planType: account.planType
        )
    }

    /// Stable id, e.g. `codex:proxy-1a2b3c4d5e6f`. The prefix before ":" is
    /// the base provider, so badges and per-provider rules treat the row like
    /// that provider's other accounts.
    var providerID: String {
        var parts = [kind.rawValue, email.lowercased(), projectID ?? ""]
        if let accountID { parts.append(accountID) }
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\n").utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(kind.baseProviderID):\(Self.idPrefix)\(hex.prefix(12))"
    }

    static let idPrefix = "proxy-"

    func matches(_ account: CLIProxyClient.Account) -> Bool {
        account.kind == kind
            && account.email.caseInsensitiveCompare(email) == .orderedSame
            && (projectID == nil || account.projectID == projectID)
            && (accountID == nil || account.chatgptAccountID == accountID)
    }

    /// One key per enabled login, in a steady order (kind, then email).
    /// Turned-off logins are left out: the user turned them off on the proxy.
    static func keys(from accounts: [CLIProxyClient.Account]) -> [CLIProxyLoginKey] {
        var seen = Set<String>()
        return accounts
            .filter { !$0.disabled }
            .map(CLIProxyLoginKey.init(account:))
            .sorted { lhs, rhs in
                let lhsOrder = CLIProxyLoginKind.allCases.firstIndex(of: lhs.kind) ?? 0
                let rhsOrder = CLIProxyLoginKind.allCases.firstIndex(of: rhs.kind) ?? 0
                if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
                let byEmail = lhs.email.localizedCaseInsensitiveCompare(rhs.email)
                if byEmail != .orderedSame { return byEmail == .orderedAscending }
                return (lhs.projectID ?? lhs.accountID ?? "") < (rhs.projectID ?? rhs.accountID ?? "")
            }
            .filter { seen.insert($0.providerID).inserted }
    }
}

/// One login on the CLIProxyAPI server shown as its own row: a Claude, Codex,
/// Antigravity or Gemini account that needs no setup in Allowance Bar.
///
/// Every request goes through the proxy's management API, which adds the
/// login's token on the proxy machine. No token reaches Allowance Bar.
struct CLIProxyAccountProvider: UsageProvider {
    let login: CLIProxyLoginKey
    var session: URLSession = HTTP.session
    var proxyConfig: @Sendable () -> CLIProxyConfig? = { CLIProxyConfig.current() }
    var accountCache: CLIProxyAccountCache = .shared
    var usageCache: CLIProxyUsageCache = .shared
    var planCache: CLIProxyPlanCache = .shared
    var claudeRateLimits: ClaudeRateLimitGate = .shared

    init(login: CLIProxyLoginKey) {
        self.login = login
    }

    var id: String { login.providerID }
    var displayName: String { "\(login.kind.displayName) — \(login.email)" }

    var shortCode: String {
        let initial = login.email.trimmingCharacters(in: .whitespaces).prefix(1).uppercased()
        return login.kind.shortCode + initial
    }

    /// The row exists only while the proxy lists this login, so it is
    /// always detected. Removing the management key removes the rows.
    var isDetected: Bool { true }

    var credentialHelpText: String? {
        L("This account comes from CLIProxyAPI. Turn it off or remove it there to hide it here.")
    }

    var dashboardURL: URL? {
        switch login.kind {
        case .claude: return URL(string: "https://claude.ai/settings/usage")
        case .codex: return URL(string: "https://chatgpt.com/codex/settings/usage")
        case .antigravity: return URL(string: "https://antigravity.google")
        case .gemini: return URL(string: "https://aistudio.google.com/usage")
        }
    }

    func fetch() async throws -> ProviderUsage {
        try await fetch(forceRefresh: false)
    }

    func fetch(forceRefresh: Bool) async throws -> ProviderUsage {
        guard let config = proxyConfig() else { throw CLIProxyError.notConfigured }
        let cacheKey = config.identity + "|" + id
        if !forceRefresh, let cached = await usageCache.usage(for: cacheKey) {
            return cached
        }
        let client = CLIProxyClient(config: config, session: session, claudeRateLimits: claudeRateLimits)
        let accounts = try await client.logins(force: false, cache: accountCache)
        let matches = accounts.filter(login.matches)
        guard let account = matches.first(where: { !$0.disabled }) else {
            throw CLIProxyError.loginRemoved
        }
        let usage = try await Self.usage(for: account, client: client, planCache: planCache, now: Date())
        await usageCache.store(usage, for: cacheKey)
        return usage
    }

    static func usage(
        for account: CLIProxyClient.Account,
        client: CLIProxyClient,
        planCache: CLIProxyPlanCache = .shared,
        now: Date
    ) async throws -> ProviderUsage {
        var usage: ProviderUsage
        switch account.kind {
        case .claude:
            // The plan waits for the usage answer: two requests at once from
            // one login can trip Anthropic's rate limit.
            let response = try await client.claudeUsage(authIndex: account.authIndex)
            let plan = await client.plan(for: account, cache: planCache)
            usage = ClaudeProvider.usage(from: response, plan: plan, now: now)
        case .codex:
            let data = try await client.codexUsage(account)
            usage = try codexUsage(from: data, fallbackPlan: account.planType, now: now)
        case .antigravity:
            async let plan = client.plan(for: account, cache: planCache)
            let data = try await client.antigravityUsage(account)
            usage = try antigravityUsage(from: data, plan: await plan, now: now)
        case .gemini:
            async let plan = client.plan(for: account, cache: planCache)
            let data = try await client.geminiUsage(account)
            guard let response = try? JSONDecoder().decode(GeminiProvider.QuotaResponse.self, from: data) else {
                throw CLIProxyError.badResponse
            }
            usage = GeminiProvider.usage(from: response, plan: await plan, now: now)
        }
        usage.accountEmail = account.email
        return usage
    }

    // MARK: - Codex

    /// Parses ChatGPT's `wham/usage` answer. Windows are named by their
    /// length, as in the Codex CLI: a Pro plan may report only a weekly window.
    static func codexUsage(from data: Data, fallbackPlan: String?, now: Date) throws -> ProviderUsage {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIProxyError.badResponse
        }
        let rateLimit = (json["rate_limit"] ?? json["rateLimit"]) as? [String: Any]
        let blocked = (rateLimit?["limit_reached"] as? Bool) == true || (rateLimit?["allowed"] as? Bool) == false
        var windows: [UsageWindow] = []
        for key in ["primary_window", "secondary_window"] {
            guard let window = rateLimit?[key] as? [String: Any] else { continue }
            let used = number(window["used_percent"]) ?? (blocked ? 100 : nil)
            guard let used else { continue }
            let seconds = number(window["limit_window_seconds"])
            let minutes = seconds.map { Int(($0 / 60).rounded()) } ?? 0
            let resetsAt = unixDate(window["reset_at"])
                ?? number(window["reset_after_seconds"]).map { now.addingTimeInterval($0) }
            windows.append(UsageWindow(
                label: CodexUsageReader.windowLabel(minutes: minutes),
                usedPercent: max(0, min(100, used)),
                resetsAt: resetsAt,
                duration: CodexUsageReader.windowDuration(minutes: minutes)
            ))
        }

        var balance: BalanceInfo?
        if let credits = json["credits"] as? [String: Any],
           (credits["has_credits"] as? Bool) == true,
           (credits["unlimited"] as? Bool) != true,
           let amount = number(credits["balance"]) {
            balance = BalanceInfo(remaining: amount, used: nil, currencySymbol: "$", kind: .remaining)
        }

        let plan = (json["plan_type"] as? String) ?? fallbackPlan
        return ProviderUsage(planName: CodexPlan.displayName(plan), windows: windows, asOf: now, balance: balance)
    }

    // MARK: - Antigravity

    /// Parses `retrieveUserQuotaSummary`: groups of models (e.g. "Gemini
    /// Models"), each with a 5-hour and a weekly bucket.
    static func antigravityUsage(from data: Data, plan: String? = nil, now: Date) throws -> ProviderUsage {
        guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIProxyError.badResponse
        }
        if json["groups"] == nil, let nested = json["body"] as? [String: Any] {
            json = nested
        }
        guard let groups = json["groups"] as? [[String: Any]] else { throw CLIProxyError.badResponse }

        var windows: [UsageWindow] = []
        for (groupIndex, group) in groups.enumerated() {
            let groupName = antigravityGroupName(
                (group["displayName"] ?? group["display_name"]) as? String,
                index: groupIndex
            )
            let buckets = (group["buckets"] as? [[String: Any]] ?? [])
                .compactMap { bucket -> (order: Int, window: UsageWindow)? in
                    guard let remaining = fraction(bucket["remainingFraction"] ?? bucket["remaining_fraction"]) else {
                        return nil
                    }
                    let period = (bucket["window"] as? String)?.lowercased()
                    let (order, label, duration) = antigravityPeriod(
                        period,
                        name: (bucket["displayName"] ?? bucket["display_name"] ?? bucket["description"]) as? String
                    )
                    let reset = ((bucket["resetTime"] ?? bucket["reset_time"]) as? String).flatMap(isoDate)
                    return (order, UsageWindow(
                        label: "\(groupName) · \(label)",
                        usedPercent: max(0, min(100, 100 - remaining * 100)),
                        resetsAt: reset,
                        duration: duration
                    ))
                }
                .sorted { $0.order < $1.order }
            windows += buckets.map(\.window)
        }
        return ProviderUsage(planName: plan, windows: windows, asOf: now)
    }

    /// "Gemini Models" → "Gemini"; "Claude and GPT models" → "Claude and GPT".
    static func antigravityGroupName(_ raw: String?, index: Int) -> String {
        var name = raw?.trimmingCharacters(in: .whitespaces) ?? ""
        for suffix in [" models", " model"] where name.lowercased().hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
            break
        }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? L("Group \(index + 1)") : name
    }

    private static func antigravityPeriod(_ period: String?, name: String?) -> (Int, String, TimeInterval?) {
        switch period {
        case "5h", "five-hour", "five_hour":
            return (0, L("5h limit"), 5 * 3600)
        case "weekly", "week":
            return (1, L("Weekly limit"), 7 * 24 * 3600)
        default:
            var label = name?.trimmingCharacters(in: .whitespaces) ?? ""
            if label.lowercased().hasSuffix(" remaining") {
                label = String(label.dropLast(" remaining".count))
            }
            return (2, label.isEmpty ? (period ?? L("Limit")) : label, nil)
        }
    }

    // MARK: - Value parsing

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber where !(value is Bool): return number.doubleValue
        case let string as String: return Double(string.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// 0...1, or a percent string such as "40%".
    private static func fraction(_ value: Any?) -> Double? {
        if let string = value as? String, string.hasSuffix("%") {
            return Double(string.dropLast()).map { $0 / 100 }
        }
        return number(value)
    }

    /// Seconds or milliseconds since 1970, told apart by size.
    private static func unixDate(_ value: Any?) -> Date? {
        guard let raw = number(value), raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw < 1e11 ? raw : raw / 1000)
    }

    private static func isoDate(_ value: String) -> Date? {
        ISO8601DateFormatter.flexible.date(from: value) ?? ISO8601DateFormatter.plain.date(from: value)
    }
}

/// Keeps each proxy row's last answer for a short while, so a 30-second
/// refresh interval doesn't send every login's usage request to its provider
/// twice a minute. An explicit refresh skips it.
/// Remembers each proxy login's plan for hours: plans rarely change, and
/// each lookup is one more request through the proxy. A failed lookup keeps
/// the last known plan and is tried again sooner.
actor CLIProxyPlanCache {
    static let shared = CLIProxyPlanCache()
    static let maxAge: TimeInterval = 6 * 3600
    static let retryAfter: TimeInterval = 15 * 60

    private struct Entry {
        let plan: String?
        let nextCheck: Date
    }

    private var entries: [String: Entry] = [:]
    private var running: [String: Task<String?, Never>] = [:]

    func plan(
        for key: String,
        now: Date = Date(),
        lookup: @escaping @Sendable () async -> String?
    ) async -> String? {
        if let entry = entries[key], now < entry.nextCheck { return entry.plan }
        if let task = running[key] {
            let fresh = await task.value
            return fresh ?? entries[key]?.plan
        }
        // Not tied to the caller: when a failed usage request ends the
        // caller, the answer already on its way is still kept, so the next
        // refresh doesn't ask again. Callers asking meanwhile share it.
        let task = Task { await lookup() }
        running[key] = task
        let fresh = await task.value
        running[key] = nil
        let plan = fresh ?? entries[key]?.plan
        let wait = fresh == nil ? Self.retryAfter : Self.maxAge
        entries[key] = Entry(plan: plan, nextCheck: now.addingTimeInterval(wait))
        return plan
    }
}

actor CLIProxyUsageCache {
    static let shared = CLIProxyUsageCache()
    static let maxAge: TimeInterval = 120

    private var entries: [String: (usage: ProviderUsage, at: Date)] = [:]

    func usage(for key: String, now: Date = Date()) -> ProviderUsage? {
        guard let entry = entries[key], now.timeIntervalSince(entry.at) < Self.maxAge else { return nil }
        return entry.usage
    }

    func store(_ usage: ProviderUsage, for key: String, now: Date = Date()) {
        entries[key] = (usage, now)
    }
}
