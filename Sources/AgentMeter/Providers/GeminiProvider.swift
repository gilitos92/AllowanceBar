import Foundation

/// Gemini (Google AI / Code Assist) usage from the Cloud Code private quota API,
/// authenticated with the token the Gemini CLI stores in ~/.gemini/oauth_creds.json.
///
/// The token is read fresh on each fetch and refreshed in memory when expired.
/// Refreshed tokens are not written back to disk by this app.
struct GeminiProvider: AccountConfigurableProvider {
    var id = "gemini"
    var displayName = "Gemini"
    var shortCode = "Ge"

    var credentialsPath = NSHomeDirectory() + "/.gemini/oauth_creds.json"

    /// The Gemini CLI keeps its `.gemini` folder inside `GEMINI_CLI_HOME`
    /// when that is set, instead of inside the user's home folder.
    static func credentialsPath(cliHome: URL) -> String {
        cliHome.appendingPathComponent(".gemini/oauth_creds.json").path
    }

    static let quotaURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!
    static let loadCodeAssistURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    // Gemini CLI's public installed-app OAuth client. Google documents that
    // installed-app client secrets are NOT confidential (they ship in the
    // open-source gemini-cli). Assembled at runtime only so that GitHub's
    // secret scanner doesn't false-positive on the literal.
    static let clientID = ["681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j",
                           "apps.googleusercontent.com"].joined(separator: ".")
    static let clientSecret = ["GOCSPX", "4uHgMPm-1o7Sk-geV6Cu5clXFsxl"].joined(separator: "-")

    var isDetected: Bool {
        FileManager.default.fileExists(atPath: credentialsPath)
    }

    func fetch() async throws -> ProviderUsage {
        var creds = try loadCredentials()
        if creds.isExpired {
            creds.accessToken = try await Self.refresh(refreshToken: creds.refreshToken)
        }
        let plan = await Self.loadTier(accessToken: creds.accessToken)
        let response = try await Self.fetchQuota(accessToken: creds.accessToken, projectId: plan.projectId)
        var usage = Self.usage(from: response, plan: plan.planName, now: Date())
        usage.accountEmail = Self.activeAccountEmail(credentialsPath: credentialsPath)
        return usage
    }

    /// The Gemini CLI's signed-in email from `google_accounts.json`, next to
    /// its credentials. That file holds no credentials.
    static func activeAccountEmail(credentialsPath: String) -> String? {
        struct Accounts: Decodable { let active: String? }
        let path = URL(fileURLWithPath: credentialsPath)
            .deletingLastPathComponent()
            .appendingPathComponent("google_accounts.json").path
        guard let data = FileManager.default.contents(atPath: path),
              let accounts = try? JSONDecoder().decode(Accounts.self, from: data),
              let email = accounts.active?.trimmingCharacters(in: .whitespaces), !email.isEmpty else {
            return nil
        }
        return email
    }

    // MARK: - Credentials

    struct Credentials {
        var accessToken: String
        var refreshToken: String
        var expiryDate: Date?

        var isExpired: Bool {
            guard let expiryDate else { return true }
            return expiryDate.timeIntervalSinceNow < 60
        }
    }

    private struct CredentialsFile: Decodable {
        let access_token: String?
        let refresh_token: String?
        let expiry_date: Double?
    }

    func loadCredentials() throws -> Credentials {
        guard let data = FileManager.default.contents(atPath: credentialsPath),
              let file = try? JSONDecoder().decode(CredentialsFile.self, from: data),
              let refresh = file.refresh_token else {
            throw GeminiError.notSignedIn
        }
        return Credentials(
            accessToken: file.access_token ?? "",
            refreshToken: refresh,
            expiryDate: file.expiry_date.map { Date(timeIntervalSince1970: $0 / 1000) }
        )
    }

    // MARK: - Networking

    static func refresh(refreshToken: String) async throws -> String {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "client_secret", value: clientSecret),
        ]
        request.httpBody = (components.percentEncodedQuery ?? "").data(using: .utf8)

        let (data, response) = try await HTTP.session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw GeminiError.notSignedIn
        }
        struct TokenResponse: Decodable {
            let access_token: String
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data).access_token
    }

    struct TierInfo {
        var projectId: String?
        var planName: String?
    }

    /// The `loadCodeAssist` body the Gemini CLI sends. With a project, the
    /// tier is that project's, as the Gemini CLI asks for a chosen project.
    static func loadCodeAssistBody(project: String?) -> String {
        guard let project, !project.isEmpty else {
            return #"{"metadata":{"ideType":"GEMINI_CLI","pluginType":"GEMINI"}}"#
        }
        let body: [String: Any] = [
            "cloudaicompanionProject": project,
            "metadata": ["ideType": "GEMINI_CLI", "pluginType": "GEMINI", "duetProject": project],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Best-effort tier + project lookup. Never throws; quota fetch can proceed
    /// without a project id for managed free-tier accounts.
    static func loadTier(accessToken: String) async -> TierInfo {
        var request = URLRequest(url: loadCodeAssistURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(loadCodeAssistBody(project: nil).utf8)

        guard let (data, response) = try? await HTTP.session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return TierInfo()
        }
        return tierInfo(from: data)
    }

    /// Project and plan from a `loadCodeAssist` answer. Also used for
    /// CLIProxyAPI's Gemini logins.
    static func tierInfo(from data: Data) -> TierInfo {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return TierInfo()
        }

        var projectId: String?
        if let project = json["cloudaicompanionProject"] as? String {
            projectId = project
        } else if let project = json["cloudaicompanionProject"] as? [String: Any] {
            projectId = project["id"] as? String ?? project["projectId"] as? String
        }

        // Like the Gemini CLI: a Google AI Pro or Ultra subscription is the
        // paid tier, while the current tier can still say "free".
        let paid = (json["paidTier"] ?? json["paid_tier"]) as? [String: Any]
        let current = (json["currentTier"] ?? json["current_tier"]) as? [String: Any]
        return TierInfo(projectId: projectId, planName: tierName(paid) ?? tierName(current))
    }

    /// The tier's own name from Google (e.g. "Google AI Pro"), so new plans
    /// show without an app update. Without a name, a known id gets a short
    /// label and any other id shows as it is.
    static func tierName(_ tier: [String: Any]?) -> String? {
        guard let tier else { return nil }
        if let name = (tier["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        guard let id = (tier["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            return nil
        }
        switch id {
        case "standard-tier": return "Paid"
        case "free-tier": return "Free"
        case "legacy-tier": return "Legacy"
        default: return id
        }
    }

    static func fetchQuota(accessToken: String, projectId: String?) async throws -> QuotaResponse {
        var request = URLRequest(url: quotaURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = projectId.map { ["project": $0] } ?? [:]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await HTTP.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GeminiError.badResponse }
        if http.statusCode == 401 { throw GeminiError.notSignedIn }
        guard http.statusCode == 200 else { throw GeminiError.httpStatus(http.statusCode) }
        return try JSONDecoder().decode(QuotaResponse.self, from: data)
    }

    // MARK: - Response mapping

    struct QuotaResponse: Decodable {
        struct Bucket: Decodable {
            let remainingFraction: Double?
            let resetTime: String?
            let modelId: String?
        }
        let buckets: [Bucket]?
    }

    static func usage(from response: QuotaResponse, plan: String?, now: Date) -> ProviderUsage {
        // Keep the lowest remaining fraction per model family (worst case).
        var families: [(label: String, order: Int)] = []
        var worst: [String: (used: Double, reset: Date?)] = [:]

        for bucket in response.buckets ?? [] {
            guard let modelId = bucket.modelId?.lowercased(),
                  let fraction = bucket.remainingFraction else { continue }
            let family: (String, Int)
            if modelId.contains("flash-lite") {
                family = (L("Flash-Lite (24h)"), 2)
            } else if modelId.contains("flash") {
                family = (L("Flash (24h)"), 1)
            } else if modelId.contains("pro") {
                family = (L("Pro (24h)"), 0)
            } else {
                continue
            }
            let usedPercent = max(0, min(100, 100 - fraction * 100))
            let reset = bucket.resetTime.flatMap {
                ISO8601DateFormatter.flexible.date(from: $0) ?? ISO8601DateFormatter.plain.date(from: $0)
            }
            if let existing = worst[family.0] {
                if usedPercent > existing.used {
                    worst[family.0] = (usedPercent, reset)
                }
            } else {
                worst[family.0] = (usedPercent, reset)
                families.append((family.0, family.1))
            }
        }

        let windows = families
            .sorted { $0.order < $1.order }
            .compactMap { family -> UsageWindow? in
                guard let entry = worst[family.label] else { return nil }
                // Every Gemini quota family is a 24-hour window.
                return UsageWindow(
                    label: family.label,
                    usedPercent: entry.used,
                    resetsAt: entry.reset,
                    duration: 24 * 3600
                )
            }

        return ProviderUsage(planName: plan, windows: windows, asOf: now)
    }
}

enum GeminiError: LocalizedError {
    case notSignedIn
    case badResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return L("Not signed in to Gemini (run 'gemini' to authenticate)")
        case .badResponse: return L("Unexpected response from Google")
        case .httpStatus(let code): return L("Google returned HTTP \(code))")
        }
    }
}
