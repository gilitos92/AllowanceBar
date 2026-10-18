import Foundation
import AppKit
import Combine
import CryptoKit

/// OpenRouter credits, authenticated by a key stored in the app's Keychain.
///
/// The key can be provisioned two ways: pasted manually, or via OpenRouter's
/// OAuth PKCE flow ("Connect" in Settings), which asks the user to approve in
/// the browser and then calls back with a code we exchange for a dedicated,
/// individually revocable API key. Either way the key only ever goes to
/// openrouter.ai.
struct OpenRouterProvider: AccountConfigurableProvider {
    var id = "openrouter"
    var displayName = "OpenRouter"
    var shortCode = "OR"

    static let creditsURL = URL(string: "https://openrouter.ai/api/v1/credits")!
    static let keyURL = URL(string: "https://openrouter.ai/api/v1/key")!

    var isDetected: Bool {
        KeychainStore.exists(keychainAccount)
    }

    var authKind: ProviderAuthKind { .oauth }

    var dashboardURL: URL? {
        URL(string: "https://openrouter.ai/settings/credits")
    }

    func fetch() async throws -> ProviderUsage {
        guard let key = KeychainStore.get(keychainAccount) else {
            throw ProviderKeyError.missingKey(displayName)
        }

        // OAuth provisions a normal user-controlled API key. Validate and read
        // that key's usage through /key first; /credits is an optional
        // account-level enrichment and may require a management key.
        let keyInfo = try await Self.fetchKeyInfo(key: key)
        if let credits = try? await Self.fetchCredits(key: key) {
            return Self.usage(from: credits, now: Date())
        }
        return Self.usage(from: keyInfo, now: Date())
    }

    private static func request(url: URL, key: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func fetchCredits(key: String) async throws -> CreditsResponse {
        let request = request(url: creditsURL, key: key)
        let (data, response) = try await HTTP.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenRouterError.badResponse }
        guard http.statusCode == 200 else { throw OpenRouterError.httpStatus(http.statusCode) }
        return try JSONDecoder().decode(CreditsResponse.self, from: data)
    }

    private static func fetchKeyInfo(key: String) async throws -> KeyResponse {
        let request = request(url: keyURL, key: key)
        let (data, response) = try await HTTP.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenRouterError.badResponse }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw OpenRouterError.invalidKey
        }
        guard http.statusCode == 200 else { throw OpenRouterError.httpStatus(http.statusCode) }
        return try JSONDecoder().decode(KeyResponse.self, from: data)
    }

    struct CreditsResponse: Decodable {
        struct Payload: Decodable {
            let totalCredits: Double
            let totalUsage: Double
            enum CodingKeys: String, CodingKey {
                case totalCredits = "total_credits"
                case totalUsage = "total_usage"
            }
        }
        let data: Payload
    }

    struct KeyResponse: Decodable {
        struct Payload: Decodable {
            let limit: Double?
            let limitRemaining: Double?
            let usage: Double?
            let usageDaily: Double?
            let usageWeekly: Double?
            let usageMonthly: Double?
            let isManagementKey: Bool?
            let isProvisioningKey: Bool?

            enum CodingKeys: String, CodingKey {
                case limit
                case limitRemaining = "limit_remaining"
                case usage
                case usageDaily = "usage_daily"
                case usageWeekly = "usage_weekly"
                case usageMonthly = "usage_monthly"
                case isManagementKey = "is_management_key"
                case isProvisioningKey = "is_provisioning_key"
            }
        }
        let data: Payload
    }

    struct OpenRouterCredentialFacts: Equatable {
        let isManagementKey: Bool
        let isProvisioningKey: Bool
        let limit: Double?
    }

    static let manageKeysURL = URL(string: "https://openrouter.ai/settings/keys")!

    func assessCredential() async -> CredentialAssessment? {
        guard let key = KeychainStore.get(keychainAccount) else { return nil }
        do {
            let response = try await Self.fetchKeyInfo(key: key)
            let facts = OpenRouterCredentialFacts(
                isManagementKey: response.data.isManagementKey ?? false,
                isProvisioningKey: response.data.isProvisioningKey ?? false,
                limit: response.data.limit
            )
            return Self.assessment(from: facts)
        } catch {
            return CredentialAssessmentSupport.probeFailed(manageURL: Self.manageKeysURL)
        }
    }

    nonisolated static func assessment(from facts: OpenRouterCredentialFacts) -> CredentialAssessment {
        if facts.isManagementKey || facts.isProvisioningKey {
            return CredentialAssessment(
                keyTypeLabel: L("Management key"),
                summary: L("Full account access — more powerful than Allowance Bar needs."),
                detail: L("A management key can control your whole OpenRouter account, including creating and deleting other API keys. Allowance Bar only reads usage and balance — it cannot spend credits or change anything. A regular API key is safer; use Connect to get a dedicated key for Allowance Bar that you can revoke anytime."),
                upgradeHint: nil,
                manageURL: manageKeysURL
            )
        }

        if let limit = facts.limit, limit > 0 {
            return CredentialAssessment(
                keyTypeLabel: L("Limited key"),
                summary: L("Spending capped — Allowance Bar can read usage within this limit."),
                detail: L("This API key lets apps use your OpenRouter credits up to a spending limit you set. Allowance Bar only reads how much has been used; it cannot spend money or change your account. If you used Connect, OpenRouter created a dedicated key just for Allowance Bar that you can revoke anytime."),
                upgradeHint: nil,
                manageURL: manageKeysURL
            )
        }

        return CredentialAssessment(
            keyTypeLabel: L("Standard key"),
            summary: L("Works for usage monitoring."),
            detail: L("This API key lets apps use your OpenRouter credits. Allowance Bar only reads usage; it cannot spend money or change your account. If you used Connect, OpenRouter created a dedicated key just for Allowance Bar that you can revoke anytime."),
            upgradeHint: nil,
            manageURL: manageKeysURL
        )
    }

    nonisolated static func usage(from response: CreditsResponse, now: Date) -> ProviderUsage {
        let remaining = max(0, response.data.totalCredits - response.data.totalUsage)
        return ProviderUsage(
            planName: L("Credits"),
            windows: [],
            asOf: now,
            balance: BalanceInfo(
                remaining: remaining,
                used: response.data.totalUsage,
                currencySymbol: "$"
            )
        )
    }

    nonisolated static func usage(from response: KeyResponse, now: Date) -> ProviderUsage {
        let data = response.data
        let used = data.usage ?? 0

        if let limit = data.limit, limit > 0 {
            let remaining = max(0, data.limitRemaining ?? (limit - used))
            let percent = min(100, max(0, used / limit * 100))
            return ProviderUsage(
                planName: L("API key"),
                windows: [UsageWindow(label: L("Key limit"), usedPercent: percent, resetsAt: nil)],
                asOf: now,
                balance: BalanceInfo(remaining: remaining, used: used, currencySymbol: "$")
            )
        }

        // Uncapped keys report spend but have no meaningful "remaining"
        // amount. Prefer the current month for a useful, bounded readout.
        let periodSpend = data.usageMonthly ?? data.usageWeekly ?? data.usageDaily ?? used
        return ProviderUsage(
            planName: L("API key"),
            windows: [],
            asOf: now,
            balance: BalanceInfo(
                remaining: periodSpend,
                used: nil,
                currencySymbol: "$",
                kind: .spent
            )
        )
    }
}

enum OpenRouterError: LocalizedError {
    case badResponse
    case invalidKey
    case httpStatus(Int)
    case authFlowFailed(String)

    var errorDescription: String? {
        switch self {
        case .badResponse: return L("Unexpected response from OpenRouter")
        case .invalidKey: return L("OpenRouter key rejected — reconnect in Settings")
        case .httpStatus(let code): return L("OpenRouter returned HTTP \(code)")
        case .authFlowFailed(let message): return message
        }
    }
}

/// OpenRouter OAuth PKCE flow. Provisions a dedicated API key for Allowance Bar.
///
/// Flow: generate a code verifier, open openrouter.ai/auth in the browser with
/// its SHA-256 challenge and `allowancebar://openrouter` as the callback; on
/// approval the browser opens that URL with a `code`, which we exchange for an
/// API key and store in the Keychain. The verifier never leaves this process.
@MainActor
final class OpenRouterAuthFlow: ObservableObject {
    enum Status: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    static let shared = OpenRouterAuthFlow()
    static let callbackScheme = "allowancebar"
    static let callbackHost = "openrouter"
    /// Versions up to 2.0.3 kept the verifier in UserDefaults; removed on first use.
    private static let legacyVerifierDefaultsKey = "openRouter.pendingPKCEVerifier"

    @Published private(set) var status: Status = .idle
    /// Keychain account the pending or last flow saves its key to, so only
    /// that OpenRouter account shows progress.
    @Published private(set) var targetKeychainAccount: String?

    /// Kept in memory only, so an abandoned flow leaves nothing on disk. If the
    /// app quits mid-flow the callback fails and the user connects again.
    private var pendingVerifier: String?

    private init() {
        UserDefaults.standard.removeObject(forKey: Self.legacyVerifierDefaultsKey)
    }

    func start(keychainAccount: String = OpenRouterProvider().keychainAccount) {
        let verifier = Self.randomVerifier()
        pendingVerifier = verifier
        targetKeychainAccount = keychainAccount
        status = .connecting
        let challenge = Self.challenge(for: verifier)

        var components = URLComponents(string: "https://openrouter.ai/auth")!
        components.queryItems = [
            URLQueryItem(name: "callback_url", value: "\(Self.callbackScheme)://\(Self.callbackHost)"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        NSWorkspace.shared.open(components.url!)
    }

    /// Handles the allowancebar://openrouter?code=... callback.
    /// Returns true if the URL was consumed.
    func handleCallback(_ url: URL, onComplete: @escaping (Result<Void, Error>) -> Void) -> Bool {
        guard url.scheme == Self.callbackScheme, url.host == Self.callbackHost else { return false }
        guard let verifier = pendingVerifier,
              let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                  .queryItems?.first(where: { $0.name == "code" })?.value else {
            let error = OpenRouterError.authFlowFailed(
                L("OpenRouter connect failed: missing code")
            )
            status = .failed(error.localizedDescription)
            onComplete(.failure(error))
            return true
        }
        pendingVerifier = nil
        let keychainAccount = targetKeychainAccount ?? OpenRouterProvider().keychainAccount

        Task {
            do {
                let key = try await Self.exchange(code: code, verifier: verifier)
                guard !key.isEmpty,
                      KeychainStore.set(key, account: keychainAccount) else {
                    throw OpenRouterError.authFlowFailed(L("OpenRouter connect failed: key could not be saved"))
                }
                status = .connected
                onComplete(.success(()))
            } catch {
                status = .failed(error.localizedDescription)
                onComplete(.failure(error))
            }
        }
        return true
    }

    nonisolated static func exchange(code: String, verifier: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/auth/keys")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": code,
            "code_verifier": verifier,
            "code_challenge_method": "S256",
        ])

        let (data, response) = try await HTTP.session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OpenRouterError.authFlowFailed(L("OpenRouter connect failed: key exchange rejected"))
        }
        struct KeyResponse: Decodable { let key: String }
        return try JSONDecoder().decode(KeyResponse.self, from: data).key
    }

    nonisolated static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    nonisolated static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
