import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Claude Code usage from Anthropic's OAuth usage endpoint, authenticated with
/// the token that the Claude CLI stores locally (credentials file or Keychain).
///
/// The token is read fresh on each fetch and never refreshed or written back to
/// disk by this app. Claude Code owns renewal of its shared credentials.
struct ClaudeProvider: AccountConfigurableProvider {
    var id = "claude"
    var displayName = "Claude"
    var shortCode = "Cl"

    var credentialsPath = NSHomeDirectory() + "/.claude/.credentials.json"
    var keychainService = "Claude Code-credentials"
    var session: URLSession = HTTP.session
    var keychainReader: @Sendable (String) async throws -> Data? = {
        try await ClaudeKeychainReader.read(service: $0)
    }

    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let betaHeader = "oauth-2025-04-20"
    static let userAgent = "claude-code/2.1.0"

    var isDetected: Bool {
        FileManager.default.fileExists(atPath: credentialsPath)
            || Self.keychainItemExists(service: keychainService)
    }

    var dashboardURL: URL? {
        URL(string: "https://claude.ai/settings/usage")
    }

    func fetch() async throws -> ProviderUsage {
        let creds = try await loadCredentials()
        guard !creds.isExpired else { throw ClaudeError.refreshRequired }
        let response = try await Self.fetchUsage(accessToken: creds.accessToken, session: session)
        return Self.usage(from: response, plan: creds.subscriptionType, now: Date())
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

    static func fetchUsage(accessToken: String, session: URLSession = HTTP.session) async throws -> UsageResponse {
        var request = URLRequest(url: usageURL)
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClaudeError.badResponse }
        if http.statusCode == 401 { throw ClaudeError.notSignedIn }
        if http.statusCode == 429 { throw ClaudeError.rateLimited }
        guard http.statusCode == 200 else { throw ClaudeError.httpStatus(http.statusCode) }
        return try JSONDecoder().decode(UsageResponse.self, from: data)
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
        func window(_ w: UsageResponse.Window?, _ label: String) -> UsageWindow? {
            guard let w, let utilization = w.utilization else { return nil }
            let resetsAt = w.resetsAt.flatMap {
                ISO8601DateFormatter.flexible.date(from: $0) ?? ISO8601DateFormatter.plain.date(from: $0)
            }
            return UsageWindow(label: label, usedPercent: max(0, min(100, utilization)), resetsAt: resetsAt)
        }

        let windows = [
            window(response.fiveHour, L("5h limit")),
            window(response.sevenDay, L("Weekly limit")),
            window(response.sevenDayOpus, L("Weekly (Opus)")),
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
    case rateLimited
    case badResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return L("Not signed in to Claude Code")
        case .refreshRequired: return L("Run Claude Code to renew its credentials, then refresh Allowance Bar")
        case .keychainUnavailable: return L("Could not read Claude Code credentials from Keychain. Unlock your login Keychain, then refresh Allowance Bar")
        case .rateLimited: return L("Anthropic rate-limited the usage request")
        case .badResponse: return L("Unexpected response from Anthropic")
        case .httpStatus(let code): return L("Anthropic returned HTTP \(code))")
        }
    }
}
