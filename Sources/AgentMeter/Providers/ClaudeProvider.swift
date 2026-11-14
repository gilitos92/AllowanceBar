import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Claude Code usage from Anthropic's OAuth usage endpoint, authenticated with
/// the token that the Claude CLI stores locally (credentials file or Keychain).
///
/// The token is read fresh on each fetch and never refreshed or written back to
/// disk by this app. Claude Code owns renewal of its shared credentials. When
/// that login is missing or expired and a CLIProxyAPI server is set up, usage
/// comes through the proxy instead (`CLIProxyClient`).
struct ClaudeProvider: AccountConfigurableProvider {
    var id = "claude"
    var displayName = "Claude"
    var shortCode = "Cl"

    var credentialsPath = NSHomeDirectory() + "/.claude/.credentials.json"
    var keychainService = "Claude Code-credentials"
    /// Claude Code's account file; its email picks the matching proxy login.
    var accountInfoPath = NSHomeDirectory() + "/.claude.json"
    var session: URLSession = HTTP.session
    var keychainReader: @Sendable (String) async throws -> Data? = {
        try await ClaudeKeychainReader.read(service: $0)
    }
    var proxyConfig: @Sendable () -> CLIProxyConfig? = { CLIProxyConfig.current() }
    var proxyAccountCache: CLIProxyAccountCache = .shared
    var proxyPlanCache: CLIProxyPlanCache = .shared
    var rateLimits: ClaudeRateLimitGate = .shared
    /// Answers read through the proxy, kept for two minutes like the
    /// proxy's own rows.
    var proxyUsageCache: CLIProxyUsageCache = .shared

    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// The account profile Claude Code reads; it names the login's plan.
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    static let betaHeader = "oauth-2025-04-20"
    static let userAgent = "claude-code/2.1.0"

    var isDetected: Bool {
        FileManager.default.fileExists(atPath: credentialsPath)
            || Self.keychainItemExists(service: keychainService)
            || CLIProxyConfig.isConfigured
    }

    var dashboardURL: URL? {
        URL(string: "https://claude.ai/settings/usage")
    }

    func fetch() async throws -> ProviderUsage {
        try await fetch(forceRefresh: false)
    }

    /// `forceRefresh` (the Refresh button) skips the two-minute cache of
    /// answers read through the proxy; recent proxy numbers still come first.
    func fetch(forceRefresh: Bool) async throws -> ProviderUsage {
        if let usage = await proxyNumbers() { return usage }
        var plan: String?
        let localError: ClaudeError
        do {
            let creds = try await loadCredentials()
            plan = creds.subscriptionType
            guard !creds.isExpired else { throw ClaudeError.refreshRequired }
            let response = try await Self.fetchUsage(
                accessToken: creds.accessToken,
                session: session,
                rateLimits: rateLimits,
                key: ClaudeRateLimitGate.key(
                    email: Self.accountEmail(atPath: accountInfoPath),
                    fallback: "local|" + id
                )
            )
            var usage = Self.usage(from: response, plan: creds.subscriptionType, now: Date())
            usage.accountEmail = Self.accountEmail(atPath: accountInfoPath)
            return usage
        } catch let error as ClaudeError where error.proxyCanHelp {
            localError = error
        }
        guard let config = proxyConfig() else { throw localError }
        let client = CLIProxyClient(config: config, session: session, claudeRateLimits: rateLimits)
        let account = try await proxyLogin(client)
        // Like the proxy's own rows: one usage request per account every two
        // minutes, so a short refresh interval doesn't trip Anthropic's limit.
        let cacheKey = config.identity + "|local|" + id + "|" + account.authIndex
        if !forceRefresh, let cached = await proxyUsageCache.usage(for: cacheKey) {
            return cached
        }
        // The local plan describes the proxy login only if it is the same
        // account. Otherwise ask the proxy login's own profile, next to its usage.
        let localEmail = Self.accountEmail(atPath: accountInfoPath)
        let samePlan = localEmail.map { $0.caseInsensitiveCompare(account.email) == .orderedSame } ?? false
        let localPlan = samePlan ? plan : nil
        // The plan waits for the usage answer: two requests at once from one
        // login can trip Anthropic's rate limit.
        let response = try await client.claudeUsage(account)
        let proxyPlan = localPlan == nil ? await client.plan(for: account, cache: proxyPlanCache) : nil
        var usage = Self.usage(from: response, plan: localPlan ?? proxyPlan, now: Date())
        usage.accountEmail = account.email
        await proxyUsageCache.store(usage, for: cacheKey)
        return usage
    }

    // MARK: - CLIProxyAPI

    /// How long a local account waits for the proxy's login list before it
    /// reads its usage the usual way.
    static let proxyNumbersWait: TimeInterval = 3

    /// The limits CLIProxyAPI saw on this account's last message, when they
    /// are recent (`ClaudeProxyQuota`). They cost Anthropic nothing, so they
    /// come before this Mac's login and the proxy's usage request. Nil
    /// without a proxy, a matching login or recent numbers, and when the
    /// proxy answers slowly or fails: then the usual sources follow.
    func proxyNumbers(now: Date = Date()) async -> ProviderUsage? {
        guard let config = proxyConfig() else { return nil }
        let client = CLIProxyClient(config: config, session: session, claudeRateLimits: rateLimits)
        let provider = self
        guard let account = await Deadline.value(within: Self.proxyNumbersWait, {
            try? await provider.proxyLogin(client)
        }), let quota = account.claudeQuota, quota.isFresh(now: now) else {
            return nil
        }
        // Claude Code's saved plan describes the proxy login only when it is
        // the same account; otherwise the login's profile names it.
        let localEmail = Self.accountEmail(atPath: accountInfoPath)
        let sameAccount = localEmail.map { $0.caseInsensitiveCompare(account.email) == .orderedSame } ?? false
        var plan = sameAccount ? (try? await loadCredentials())?.subscriptionType : nil
        if plan == nil {
            plan = await client.plan(for: account, cache: proxyPlanCache)
        }
        var usage = quota.usage(plan: plan, now: now)
        usage.accountEmail = account.email
        return usage
    }

    /// The proxy login that matches this account.
    func proxyLogin(_ client: CLIProxyClient) async throws -> CLIProxyClient.Account {
        let config = client.config
        let accounts = try await client.claudeAccounts(cache: proxyAccountCache)
        let email = config.claudeEmails[id] ?? Self.accountEmail(atPath: accountInfoPath)
        guard let account = Self.proxyAccount(in: accounts, email: email, isDefaultAccount: id == "claude") else {
            throw CLIProxyError.loginNotFound
        }
        guard !account.disabled else { throw CLIProxyError.loginDisabled }
        return account
    }

    /// The plan in an account profile, in the words Claude Code saves for a
    /// local login ("pro", "max", "team", …), so both read alike. The profile
    /// has no display name, so this follows CLIProxyAPI's dashboard: an active
    /// Team organization, then the account's own Max or Pro, then Free when
    /// both flags say no. The organization type counts only for Enterprise,
    /// which the flags don't cover, and when the flags are missing: a
    /// canceled Pro can keep "claude_pro" with both flags false.
    static func plan(fromProfile data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let organization = json["organization"] as? [String: Any]
        let account = json["account"] as? [String: Any]
        let type = (organization?["organization_type"] as? String)?.lowercased()
        let status = (organization?["subscription_status"] as? String)?.lowercased()
        if type == "claude_team", status == "active" { return "team" }
        let hasMax = account?["has_claude_max"] as? Bool
        let hasPro = account?["has_claude_pro"] as? Bool
        if hasMax == true { return "max" }
        if hasPro == true { return "pro" }
        if type == "claude_enterprise" { return "enterprise" }
        if hasMax == false, hasPro == false { return "free" }
        if hasMax == nil, hasPro == nil, let type, type.hasPrefix("claude_") {
            let plan = String(type.dropFirst("claude_".count))
            if !plan.isEmpty, plan != "team" { return plan }
        }
        return nil
    }

    /// Matches by email, ignoring case. Without an email, only the default
    /// account may use a proxy that holds a single Claude login.
    static func proxyAccount(
        in accounts: [CLIProxyClient.Account],
        email: String?,
        isDefaultAccount: Bool
    ) -> CLIProxyClient.Account? {
        if let email = email?.trimmingCharacters(in: .whitespaces), !email.isEmpty {
            let matches = accounts.filter { $0.email.caseInsensitiveCompare(email) == .orderedSame }
            return matches.first { !$0.disabled } ?? matches.first
        }
        guard isDefaultAccount, accounts.count == 1 else { return nil }
        return accounts.first
    }

    /// `oauthAccount.emailAddress` from Claude Code's account file. Holds no
    /// credentials.
    static func accountEmail(atPath path: String) -> String? {
        struct AccountFile: Decodable {
            struct OAuthAccount: Decodable { let emailAddress: String? }
            let oauthAccount: OAuthAccount?
        }
        guard let data = FileManager.default.contents(atPath: path),
              let file = try? JSONDecoder().decode(AccountFile.self, from: data) else {
            return nil
        }
        return file.oauthAccount?.emailAddress
    }

    // MARK: - Credentials

    struct Credentials {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date?
        var subscriptionType: String?

        var isExpired: Bool {
            guard let expiresAt else { return false }
            // Treat credentials as expired a minute early to avoid racing the usage request.
            return expiresAt.timeIntervalSinceNow < 60
        }
    }

    private struct CredentialsFile: Decodable {
        struct OAuth: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresAt: Double?
            let subscriptionType: String?
        }
        let claudeAiOauth: OAuth
    }

    func loadCredentials() async throws -> Credentials {
        if let data = FileManager.default.contents(atPath: credentialsPath),
           let creds = Self.decodeCredentials(data) {
            return creds
        }
        let keychainData: Data?
        do {
            keychainData = try await keychainReader(keychainService)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ClaudeError.keychainUnavailable
        }
        if let data = keychainData,
           let creds = Self.decodeCredentials(data) {
            return creds
        }
        throw ClaudeError.notSignedIn
    }

    static func decodeCredentials(_ data: Data) -> Credentials? {
        guard let file = try? JSONDecoder().decode(CredentialsFile.self, from: data),
              let refresh = file.claudeAiOauth.refreshToken else {
            return nil
        }
        let expiresAt = file.claudeAiOauth.expiresAt.map {
            // Anthropic stores expiry in milliseconds since epoch.
            Date(timeIntervalSince1970: $0 / 1000)
        }
        return Credentials(
            accessToken: file.claudeAiOauth.accessToken,
            refreshToken: refresh,
            expiresAt: expiresAt,
            subscriptionType: file.claudeAiOauth.subscriptionType
        )
    }

    // MARK: - Networking

    /// Usage for one login. After a 429, `rateLimits` keeps `key` from
    /// asking again for a while.
    static func fetchUsage(
        accessToken: String,
        session: URLSession = HTTP.session,
        rateLimits: ClaudeRateLimitGate = .shared,
        key: String
    ) async throws -> UsageResponse {
        try await rateLimits.check(key)
        var request = URLRequest(url: usageURL)
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClaudeError.badResponse }
        if http.statusCode == 401 { throw ClaudeError.notSignedIn }
        if http.statusCode == 429 {
            let wait = ClaudeRateLimitGate.retryAfter(http.value(forHTTPHeaderField: "Retry-After"))
            throw await rateLimits.limited(key, retryAfter: wait)
        }
        guard http.statusCode == 200 else { throw ClaudeError.httpStatus(http.statusCode) }
        let usage = try JSONDecoder().decode(UsageResponse.self, from: data)
        await rateLimits.succeeded(key)
        return usage
    }

    // MARK: - Response mapping

    /// Windows are keyed dynamically; we pull the ones we display.
    struct UsageResponse: Decodable {
        struct Window: Decodable {
            let utilization: Double?
            let resetsAt: String?
            enum CodingKeys: String, CodingKey {
                case utilization
                case resetsAt = "resets_at"
            }
        }
        let fiveHour: Window?
        let sevenDay: Window?
        let sevenDayOpus: Window?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case sevenDayOpus = "seven_day_opus"
        }
    }

    static func usage(from response: UsageResponse, plan: String?, now: Date) -> ProviderUsage {
        func window(_ w: UsageResponse.Window?, _ label: String, hours: Double) -> UsageWindow? {
            guard let w, let utilization = w.utilization else { return nil }
            let resetsAt = w.resetsAt.flatMap {
                ISO8601DateFormatter.flexible.date(from: $0) ?? ISO8601DateFormatter.plain.date(from: $0)
            }
            return UsageWindow(
                label: label,
                usedPercent: max(0, min(100, utilization)),
                resetsAt: resetsAt,
                duration: hours * 3600
            )
        }

        let windows = [
            window(response.fiveHour, L("5h limit"), hours: 5),
            window(response.sevenDay, L("Weekly limit"), hours: 7 * 24),
            window(response.sevenDayOpus, L("Weekly (Opus)"), hours: 7 * 24),
        ].compactMap { $0 }

        return ProviderUsage(planName: plan?.capitalized, windows: windows, asOf: now)
    }

    // MARK: - Keychain

    /// Claude Code names the Keychain item for a non-default
    /// `CLAUDE_CONFIG_DIR` with the first eight hex characters of the SHA-256
    /// of that folder's path. Undocumented; the credentials file in the
    /// folder is still read first.
    static func keychainService(configDirectory: URL) -> String {
        let path = configDirectory.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-\(hex.prefix(8))"
    }

    static func keychainItemExists(service: String) -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}

enum ClaudeError: LocalizedError {
    case notSignedIn
    case refreshRequired
    case keychainUnavailable
    /// `retryAt`: when this login asks Anthropic again.
    case rateLimited(retryAt: Date?)
    case badResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return L("Not signed in to Claude Code")
        case .refreshRequired: return L("Run Claude Code to renew its credentials, then refresh Allowance Bar")
        case .keychainUnavailable: return L("Could not read Claude Code credentials from Keychain. Unlock your login Keychain, then refresh Allowance Bar")
        case .rateLimited(let retryAt?):
            return L("Anthropic rate-limited the usage request. Trying again at \(retryAt.formatted(date: .omitted, time: .shortened))")
        case .rateLimited: return L("Anthropic rate-limited the usage request")
        case .badResponse: return L("Unexpected response from Anthropic")
        case .httpStatus(let code): return L("Anthropic returned HTTP \(code))")
        }
    }

    /// The local login can't be used, so a CLIProxyAPI login may stand in.
    var proxyCanHelp: Bool {
        switch self {
        case .notSignedIn, .refreshRequired, .keychainUnavailable: return true
        case .rateLimited, .badResponse, .httpStatus: return false
        }
    }
}
