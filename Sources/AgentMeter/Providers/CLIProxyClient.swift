import Foundation

/// Connection to a CLIProxyAPI server (https://github.com/router-for-me/CLIProxyAPI)
/// that holds the user's Claude logins.
///
/// Claude Code stops renewing its own login when it sends requests through the
/// proxy, so its token expires. The proxy keeps renewing its copies. Its
/// management API makes the usage request with the account's token on the
/// proxy machine, so the token never reaches Allowance Bar.
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
    static func normalizedURL(_ string: String) -> URL? {
        var value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { value = defaultURL }
        if !value.contains("://") { value = "http://" + value }
        while value.hasSuffix("/") { value.removeLast() }
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil else {
            return nil
        }
        return url
    }
}

struct CLIProxyClient: Sendable {
    let config: CLIProxyConfig
    var session: URLSession = HTTP.session

    struct Account: Equatable, Sendable {
        let authIndex: String
        let email: String
        let disabled: Bool
    }

    /// The proxy's Claude logins.
    func claudeAccounts() async throws -> [Account] {
        let data = try await managementRequest(path: "auth-files", method: "GET", body: nil)
        guard let list = try? JSONDecoder().decode(AuthFilesResponse.self, from: data) else {
            throw CLIProxyError.badResponse
        }
        return list.files.compactMap { file in
            guard (file.provider ?? file.type)?.lowercased() == "claude",
                  let index = file.authIndex, let email = file.email, !email.isEmpty else {
                return nil
            }
            return Account(authIndex: index.value, email: email, disabled: file.disabled ?? false)
        }
    }

    /// Asks the proxy to call Anthropic's usage endpoint with one login's token.
    func claudeUsage(authIndex: String) async throws -> ClaudeProvider.UsageResponse {
        let call = APICallRequest(
            authIndex: authIndex,
            method: "GET",
            url: ClaudeProvider.usageURL.absoluteString,
            header: [
                // The proxy replaces $TOKEN$ with the login's access token.
                "Authorization": "Bearer $TOKEN$",
                "Accept": "application/json",
                "anthropic-beta": ClaudeProvider.betaHeader,
                "User-Agent": ClaudeProvider.userAgent,
            ]
        )
        let data = try await managementRequest(
            path: "api-call",
            method: "POST",
            body: try JSONEncoder().encode(call)
        )
        guard let result = try? JSONDecoder().decode(APICallResponse.self, from: data) else {
            throw CLIProxyError.badResponse
        }
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

        enum CodingKeys: String, CodingKey {
            case authIndex = "auth_index"
            case type, provider, email, disabled
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

    private struct APICallRequest: Encodable {
        let authIndex: String
        let method: String
        let url: String
        let header: [String: String]

        enum CodingKeys: String, CodingKey {
            case authIndex = "auth_index"
            case method, url, header
        }
    }

    private struct APICallResponse: Decodable {
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
    case remoteManagementDisabled
    case tooManyAttempts
    case loginNotFound
    case loginDisabled
    case loginSignedOut
    case badResponse
    case httpStatus(Int)

    static func from(statusCode: Int, message: String) -> CLIProxyError {
        let message = message.lowercased()
        if message.contains("remote management disabled") { return .remoteManagementDisabled }
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
        case .remoteManagementDisabled:
            return L("CLIProxyAPI only accepts management requests from its own Mac. Set allow-remote to true in its config.")
        case .tooManyAttempts:
            return L("CLIProxyAPI paused requests after failed attempts. Try again later.")
        case .loginNotFound:
            return L("CLIProxyAPI has no matching Claude login. Choose one in Settings.")
        case .loginDisabled:
            return L("The matching Claude login is turned off in CLIProxyAPI.")
        case .loginSignedOut:
            return L("CLIProxyAPI's Claude login is signed out. Sign in again in CLIProxyAPI.")
        case .badResponse:
            return L("Unexpected response from CLIProxyAPI")
        case .httpStatus(let code):
            return L("CLIProxyAPI returned HTTP \(code)")
        }
    }
}
