import CryptoKit
import Foundation

/// Connection to a CLIProxyAPI server (https://github.com/router-for-me/CLIProxyAPI)
/// that holds the user's Claude, Codex, Antigravity and Gemini logins.
///
/// Every login on the proxy shows as its own row (`CLIProxyAccountProvider`).
/// Claude Code also stops renewing its own login when it sends requests
/// through the proxy, so local Claude accounts use the proxy as a backup.
/// The management API makes each usage request with the login's token on the
/// proxy machine, so no token ever reaches Allowance Bar.
struct CLIProxyConfig: Equatable, Sendable {
    var baseURL: URL
    var managementKey: String
    /// Proxy login email chosen per Allowance Bar provider id. Providers
    /// without a choice use their Claude Code login's email.
    var claudeEmails: [String: String]

    static let urlDefaultsKey = "cliProxyURL"
    static let claudeEmailsDefaultsKey = "cliProxyClaudeEmails"
    static let keychainAccount = "cliproxy.managementKey"
    static let defaultURL = "http://127.0.0.1:8317"

    /// Nil until the user saves a management key.
    static func current(
        defaults: UserDefaults = .standard,
        managementKey: () -> String? = { KeychainStore.get(keychainAccount) }
    ) -> CLIProxyConfig? {
        guard let key = managementKey(), !key.isEmpty,
              let url = normalizedURL(defaults.string(forKey: urlDefaultsKey) ?? defaultURL) else {
            return nil
        }
        let emails = defaults.dictionary(forKey: claudeEmailsDefaultsKey) as? [String: String] ?? [:]
        return CLIProxyConfig(baseURL: url, managementKey: key, claudeEmails: emails)
    }

    /// Cheap and prompt-free: checks only that our own Keychain item exists.
    static var isConfigured: Bool {
        KeychainStore.exists(keychainAccount)
    }

    /// Accepts "host:port" or a full http(s) address. Empty means the default.
    /// Plain http is allowed only where the key can't be read on the way:
    /// this Mac, or a Tailscale MagicDNS name (Tailscale encrypts the traffic,
    /// and the name resolves only while Tailscale is connected).
    static func normalizedURL(_ string: String) -> URL? {
        var value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { value = defaultURL }
        if !value.contains("://") { value = "http://" + value }
        while value.hasSuffix("/") { value.removeLast() }
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else {
            return nil
        }
        guard scheme == "https" || allowsPlainHTTP(host: host) else { return nil }
        return url
    }

    /// Raw 100.64.0.0/10 addresses are not allowed: ISPs use the same range
    /// for carrier-grade NAT, so with Tailscale off the key could go to them.
    static func allowsPlainHTTP(host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return ["localhost", "127.0.0.1", "::1"].contains(host) || host.hasSuffix(".ts.net")
    }

    /// Identifies the server and key without keeping the key in clear text.
    var identity: String {
        let digest = SHA256.hash(data: Data(managementKey.utf8))
        return baseURL.absoluteString + "#" + digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Shares one login list per refresh across all accounts, and stops
/// calling the proxy after it rejects the key. CLIProxyAPI bans an address
/// for 30 minutes after 5 failed key checks, which would also lock out its
/// own management page on that Mac.
actor CLIProxyAccountCache {
    static let shared = CLIProxyAccountCache()
    /// Long enough for one refresh of every account to share the list.
    static let freshness: TimeInterval = 20
    static let banWait: TimeInterval = 30 * 60

    private struct Entry {
        let identity: String
        let started: Date
        let task: Task<[CLIProxyClient.Account], Error>
    }

    private struct Block {
        let identity: String
        let error: CLIProxyError
        /// Nil: until the address or key changes.
        let until: Date?
    }

    private var entry: Entry?
    private var block: Block?

    /// `force` skips the shared list and a remembered failure, for an
    /// explicit check in Settings.
    func accounts(
        for config: CLIProxyConfig,
        force: Bool = false,
        now: Date = Date(),
        load: @escaping @Sendable () async throws -> [CLIProxyClient.Account]
    ) async throws -> [CLIProxyClient.Account] {
        let identity = config.identity
        if !force, let block, block.identity == identity, block.until.map({ now < $0 }) ?? true {
            throw block.error
        }
        if !force, let entry, entry.identity == identity, now.timeIntervalSince(entry.started) < Self.freshness {
            return try await entry.task.value
        }
        let task = Task { try await load() }
        entry = Entry(identity: identity, started: now, task: task)
        do {
            let accounts = try await task.value
            if block?.identity == identity { block = nil }
            return accounts
        } catch {
            // Failures are never shared with later refreshes.
            if entry?.task == task { entry = nil }
            switch error as? CLIProxyError {
            case .invalidKey?:
                block = Block(identity: identity, error: .invalidKey, until: nil)
            case .tooManyAttempts?:
                block = Block(identity: identity, error: .tooManyAttempts, until: now.addingTimeInterval(Self.banWait))
            default:
                break
            }
            throw error
        }
    }
}

struct CLIProxyClient: Sendable {
    let config: CLIProxyConfig
    var session: URLSession = HTTP.session

    /// One login on the proxy. Holds identifiers only, never a token.
    struct Account: Equatable, Sendable {
        let kind: CLIProxyLoginKind
        let authIndex: String
        let email: String
        let disabled: Bool
        /// Codex: sent as `Chatgpt-Account-Id` so a login in several
        /// workspaces reports the right one.
        let chatgptAccountID: String?
        /// Antigravity and Gemini: the Google Cloud project the quota belongs to.
        let projectID: String?
        /// Codex: the plan from the login's ID token claims.
        let planType: String?
        /// The proxy sends new requests to the highest priority first.
        /// Logins without one count as 0, as in CLIProxyAPI.
        let priority: Int

        init(
            kind: CLIProxyLoginKind = .claude,
            authIndex: String,
            email: String,
            disabled: Bool,
            chatgptAccountID: String? = nil,
            projectID: String? = nil,
            planType: String? = nil,
            priority: Int = 0
        ) {
            self.kind = kind
            self.authIndex = authIndex
            self.email = email
            self.disabled = disabled
            self.chatgptAccountID = chatgptAccountID
            self.projectID = projectID
            self.planType = planType
            self.priority = priority
        }
    }

    /// Every supported login on the proxy, shared through `CLIProxyAccountCache`.
    func logins(force: Bool = false, cache: CLIProxyAccountCache = .shared) async throws -> [Account] {
        try await cache.accounts(for: config, force: force) { try await fetchLogins() }
    }

    /// The proxy's Claude logins.
    func claudeAccounts(force: Bool = false, cache: CLIProxyAccountCache = .shared) async throws -> [Account] {
        try await logins(force: force, cache: cache).filter { $0.kind == .claude }
    }

    private func fetchLogins() async throws -> [Account] {
        let data = try await managementRequest(path: "auth-files", method: "GET", body: nil)
        return try Self.parseLogins(data)
    }

    /// Keeps logins of supported kinds that have an index and an email.
    static func parseLogins(_ data: Data) throws -> [Account] {
        guard let list = try? JSONDecoder().decode(AuthFilesResponse.self, from: data) else {
            throw CLIProxyError.badResponse
        }
        return list.files.compactMap { file in
            guard let kind = CLIProxyLoginKind(authType: file.provider ?? file.type),
                  let index = file.authIndex,
                  let email = file.email?.trimmingCharacters(in: .whitespaces), !email.isEmpty else {
                return nil
            }
            return Account(
                kind: kind,
                authIndex: index.value,
                email: email,
                disabled: file.disabled ?? false,
                chatgptAccountID: (file.idToken?.chatgptAccountID).nonEmpty,
                projectID: file.projectID.nonEmpty,
                planType: (file.idToken?.planType).nonEmpty,
                priority: file.priority?.value ?? 0
            )
        }
    }

    /// Asks the proxy to call Anthropic's usage endpoint with one login's token.
    func claudeUsage(authIndex: String) async throws -> ClaudeProvider.UsageResponse {
        let result = try await apiCall(
            authIndex: authIndex,
            method: "GET",
            url: ClaudeProvider.usageURL.absoluteString,
            header: [
                "Accept": "application/json",
                "anthropic-beta": ClaudeProvider.betaHeader,
                "User-Agent": ClaudeProvider.userAgent,
            ]
        )
        switch result.statusCode {
        case 200:
            guard let usage = try? JSONDecoder().decode(
                ClaudeProvider.UsageResponse.self,
                from: Data(result.body.utf8)
            ) else { throw ClaudeError.badResponse }
            return usage
        case 401: throw CLIProxyError.loginSignedOut
        case 429: throw ClaudeError.rateLimited
        default: throw ClaudeError.httpStatus(result.statusCode)
        }
    }

    /// Codex limits from ChatGPT's usage endpoint, the one the Codex CLI and
    /// CLIProxyAPI's own dashboard read.
    static let codexUsageURL = "https://chatgpt.com/backend-api/wham/usage"
    /// The User-Agent CLIProxyAPI's dashboard sends for this request.
    static let codexUserAgent = "codex-tui/0.149.1 (Mac OS 26.5.2; arm64) iTerm.app/3.6.11 (codex-tui; 0.149.1)"

    func codexUsage(_ account: Account) async throws -> Data {
        var header = [
            "Content-Type": "application/json",
            "User-Agent": Self.codexUserAgent,
        ]
        if let accountID = account.chatgptAccountID {
            header["Chatgpt-Account-Id"] = accountID
        }
        let result = try await apiCall(authIndex: account.authIndex, method: "GET", url: Self.codexUsageURL, header: header)
        return try Self.upstreamBody(result)
    }

    /// Antigravity quota groups. Google serves them from several hosts; like
    /// CLIProxyAPI's dashboard, try each until one answers.
    static let antigravityQuotaURLs = [
        "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
        "https://daily-cloudcode-pa.sandbox.googleapis.com/v1internal:retrieveUserQuotaSummary",
        "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
    ]
    static let antigravityUserAgent = "antigravity/hub/2.23.0 darwin/arm64"

    func antigravityUsage(_ account: Account) async throws -> Data {
        guard let project = account.projectID else { throw CLIProxyError.missingProject }
        let body = try JSONSerialization.data(withJSONObject: ["project": project])
        var lastError: Error = CLIProxyError.badResponse
        for url in Self.antigravityQuotaURLs {
            let result = try await apiCall(
                authIndex: account.authIndex,
                method: "POST",
                url: url,
                header: ["Content-Type": "application/json", "User-Agent": Self.antigravityUserAgent],
                body: String(decoding: body, as: UTF8.self)
            )
            do {
                return try Self.upstreamBody(result)
            } catch CLIProxyError.loginSignedOut {
                throw CLIProxyError.loginSignedOut
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Gemini CLI quota, the same request `GeminiProvider` makes locally.
    func geminiUsage(_ account: Account) async throws -> Data {
        let fields: [String: String] = account.projectID.map { ["project": $0] } ?? [:]
        let body = try JSONSerialization.data(withJSONObject: fields)
        let result = try await apiCall(
            authIndex: account.authIndex,
            method: "POST",
            url: GeminiProvider.quotaURL.absoluteString,
            header: ["Content-Type": "application/json"],
            body: String(decoding: body, as: UTF8.self)
        )
        return try Self.upstreamBody(result)
    }

    /// A Claude or Gemini login's plan, best effort: nil when the lookup
    /// fails or the login has no plan to show. Codex plans come with the
    /// login list and Antigravity reports none. Each login is asked at most
    /// every few hours (`CLIProxyPlanCache`).
    func plan(for account: Account, cache: CLIProxyPlanCache = .shared) async -> String? {
        guard account.kind == .claude || account.kind == .gemini else { return nil }
        let key = [config.identity, account.kind.rawValue, account.email.lowercased(), account.projectID ?? ""]
            .joined(separator: "|")
        return await cache.plan(for: key) { await lookUpPlan(account) }
    }

    private func lookUpPlan(_ account: Account) async -> String? {
        do {
            switch account.kind {
            case .claude:
                let result = try await apiCall(
                    authIndex: account.authIndex,
                    method: "GET",
                    url: ClaudeProvider.profileURL.absoluteString,
                    header: [
                        "Accept": "application/json",
                        "anthropic-beta": ClaudeProvider.betaHeader,
                        "User-Agent": ClaudeProvider.userAgent,
                    ]
                )
                return ClaudeProvider.plan(fromProfile: try Self.upstreamBody(result))
            case .gemini:
                let result = try await apiCall(
                    authIndex: account.authIndex,
                    method: "POST",
                    url: GeminiProvider.loadCodeAssistURL.absoluteString,
                    header: ["Content-Type": "application/json"],
                    body: GeminiProvider.loadCodeAssistBody
                )
                return GeminiProvider.tierInfo(from: try Self.upstreamBody(result)).planName
            case .codex, .antigravity:
                return nil
            }
        } catch {
            return nil
        }
    }

    /// The provider's answer body for a 200, or the matching error.
    static func upstreamBody(_ result: APICallResponse) throws -> Data {
        switch result.statusCode {
        case 200: return Data(result.body.utf8)
        case 401: throw CLIProxyError.loginSignedOut
        case 429: throw CLIProxyError.upstreamRateLimited
        default: throw CLIProxyError.upstreamStatus(result.statusCode)
        }
    }

    /// Asks the proxy to make one request with a login's token. The proxy
    /// replaces `$TOKEN$` with that login's access token, so the token stays
    /// on the proxy.
    func apiCall(
        authIndex: String,
        method: String,
        url: String,
        header: [String: String],
        body: String? = nil
    ) async throws -> APICallResponse {
        var header = header
        header["Authorization"] = "Bearer $TOKEN$"
        let call = APICallRequest(authIndex: authIndex, method: method, url: url, header: header, data: body)
        let data = try await managementRequest(
            path: "api-call",
            method: "POST",
            body: try JSONEncoder().encode(call)
        )
        guard let result = try? JSONDecoder().decode(APICallResponse.self, from: data) else {
            throw CLIProxyError.badResponse
        }
        return result
    }

    private func managementRequest(path: String, method: String, body: Data?) async throws -> Data {
        var request = URLRequest(url: config.baseURL.appendingPathComponent("v0/management/\(path)"))
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("Bearer \(config.managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw CLIProxyError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw CLIProxyError.badResponse }
        guard http.statusCode == 200 else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error ?? ""
            throw CLIProxyError.from(statusCode: http.statusCode, message: message)
        }
        return data
    }

    // MARK: - Wire types

    private struct AuthFilesResponse: Decodable {
        let files: [AuthFile]
    }

    private struct AuthFile: Decodable {
        let authIndex: FlexibleString?
        let type: String?
        let provider: String?
        let email: String?
        let disabled: Bool?
        let projectID: String?
        /// Codex only: claims the proxy decoded from the ID token. Holds no
        /// token. Ignored when it isn't an object.
        let idToken: IDTokenClaims?
        let priority: FlexibleInt?

        enum CodingKeys: String, CodingKey {
            case authIndex = "auth_index"
            case projectID = "project_id"
            case idToken = "id_token"
            case type, provider, email, disabled, priority
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            authIndex = try? container.decodeIfPresent(FlexibleString.self, forKey: .authIndex)
            type = try? container.decodeIfPresent(String.self, forKey: .type)
            provider = try? container.decodeIfPresent(String.self, forKey: .provider)
            email = try? container.decodeIfPresent(String.self, forKey: .email)
            disabled = try? container.decodeIfPresent(Bool.self, forKey: .disabled)
            projectID = try? container.decodeIfPresent(String.self, forKey: .projectID)
            idToken = try? container.decodeIfPresent(IDTokenClaims.self, forKey: .idToken)
            priority = try? container.decodeIfPresent(FlexibleInt.self, forKey: .priority)
        }
    }

    private struct IDTokenClaims: Decodable {
        let chatgptAccountID: String?
        let planType: String?

        enum CodingKeys: String, CodingKey {
            case chatgptAccountID = "chatgpt_account_id"
            case planType = "plan_type"
        }
    }

    /// `auth_index` is a string in current proxies; accept a number too.
    private struct FlexibleString: Decodable {
        let value: String
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                value = string
            } else {
                value = String(try container.decode(Int.self))
            }
        }
    }

    /// `priority` is a number in the login list; CLIProxyAPI also accepts a
    /// numeric string in auth files.
    private struct FlexibleInt: Decodable {
        let value: Int
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Int.self) {
                value = number
            } else if let number = try? container.decode(Double.self) {
                // Int(_:) would crash on a value out of Int's range.
                guard let exact = Int(exactly: number) else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "not an integer")
                }
                value = exact
            } else {
                let string = try container.decode(String.self).trimmingCharacters(in: .whitespaces)
                guard let number = Int(string) else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "not an integer")
                }
                value = number
            }
        }
    }

    private struct APICallRequest: Encodable {
        let authIndex: String
        let method: String
        let url: String
        let header: [String: String]
        /// Request body as text; left out when nil.
        let data: String?

        enum CodingKeys: String, CodingKey {
            case authIndex = "auth_index"
            case method, url, header, data
        }
    }

    struct APICallResponse: Decodable {
        let statusCode: Int
        let body: String

        enum CodingKeys: String, CodingKey {
            case statusCode = "status_code"
            case body
        }
    }

    private struct ErrorResponse: Decodable {
        let error: String
    }
}

enum CLIProxyError: LocalizedError, Equatable {
    case unreachable
    case invalidKey
    case keyNotSet
    case remoteManagementDisabled
    case tooManyAttempts
    case loginNotFound
    case loginDisabled
    case loginSignedOut
    /// The login no longer exists on the proxy, or is turned off there.
    case loginRemoved
    case missingProject
    case notConfigured
    case upstreamRateLimited
    case upstreamStatus(Int)
    case badResponse
    case httpStatus(Int)

    static func from(statusCode: Int, message: String) -> CLIProxyError {
        let message = message.lowercased()
        if message.contains("remote management disabled") { return .remoteManagementDisabled }
        if message.contains("key not set") { return .keyNotSet }
        if message.contains("banned") || message.contains("too many") { return .tooManyAttempts }
        switch statusCode {
        case 401, 403: return .invalidKey
        case 429: return .tooManyAttempts
        default: return .httpStatus(statusCode)
        }
    }

    var errorDescription: String? {
        switch self {
        case .unreachable:
            return L("Could not reach CLIProxyAPI. Check the server address in Settings.")
        case .invalidKey:
            return L("CLIProxyAPI rejected the management key. Check it in Settings.")
        case .keyNotSet:
            return L("CLIProxyAPI has no management key. Set management.secret-key in its config.")
        case .remoteManagementDisabled:
            return L("CLIProxyAPI only accepts management requests from its own Mac. Set allow-remote to true in its config.")
        case .tooManyAttempts:
            return L("CLIProxyAPI paused requests after failed attempts. Try again later.")
        case .loginNotFound:
            return L("CLIProxyAPI has no matching Claude login. Choose one in Settings.")
        case .loginDisabled:
            return L("The matching Claude login is turned off in CLIProxyAPI.")
        case .loginSignedOut:
            return L("This CLIProxyAPI login is signed out. Sign in again in CLIProxyAPI.")
        case .loginRemoved:
            return L("CLIProxyAPI no longer has this login, or it is turned off there.")
        case .missingProject:
            return L("CLIProxyAPI has no Google Cloud project for this login. Sign in again in CLIProxyAPI.")
        case .notConfigured:
            return L("Add the CLIProxyAPI management key in Settings.")
        case .upstreamRateLimited:
            return L("The provider rate-limited the usage request")
        case .upstreamStatus(let code):
            return L("The provider returned HTTP \(code) through CLIProxyAPI")
        case .badResponse:
            return L("Unexpected response from CLIProxyAPI")
        case .httpStatus(let code):
            return L("CLIProxyAPI returned HTTP \(code)")
        }
    }
}

/// The proxy's login kinds that Allowance Bar can read limits for.
enum CLIProxyLoginKind: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case antigravity
    case gemini

    /// CLIProxyAPI's auth `type`/`provider`. Gemini CLI logins are
    /// "gemini-cli"; older auth files say "gemini".
    init?(authType: String?) {
        switch authType?.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "_", with: "-") {
        case "claude": self = .claude
        case "codex": self = .codex
        case "antigravity": self = .antigravity
        case "gemini-cli", "gemini": self = .gemini
        default: return nil
        }
    }

    /// The Allowance Bar provider these logins belong with.
    var baseProviderID: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        case .gemini: return "Gemini"
        }
    }

    var shortCode: String {
        switch self {
        case .claude: return "Cl"
        case .codex: return "Cx"
        case .antigravity: return "Ag"
        case .gemini: return "Ge"
        }
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
