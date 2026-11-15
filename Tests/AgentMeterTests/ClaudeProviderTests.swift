import XCTest
@testable import AgentMeter

private final class RotatingMockOAuthServer {
    private let lock = NSLock()
    private var currentRefreshToken = "R0"
    private var currentAccessToken = "A0"
    private var refreshCount = 0
    private var requests: [String] = []

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        currentRefreshToken = "R0"
        currentAccessToken = "A0"
        refreshCount = 0
        requests = []
    }

    func requestLog() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func successfulRefreshCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return refreshCount
    }

    func simulateClaudeCodeRenewal() {
        lock.lock()
        defer { lock.unlock() }
        currentAccessToken = "A1"
        currentRefreshToken = "R1"
    }

    func respond(to request: URLRequest) -> (Int, Data) {
        lock.lock()
        defer { lock.unlock() }

        let path = request.url?.path ?? ""
        requests.append("\(request.httpMethod ?? "GET") \(path)")
        if path == "/v1/oauth/token" {
            let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let refreshToken = URLComponents(string: "?\(body)")?.queryItems?
                .first(where: { $0.name == "refresh_token" })?.value
            guard refreshToken == currentRefreshToken else {
                return (400, Data(#"{"error":"invalid_grant"}"#.utf8))
            }
            refreshCount += 1
            currentRefreshToken = "R\(refreshCount)"
            currentAccessToken = "A\(refreshCount)"
            return (200, Data(#"{"access_token":"A1","refresh_token":"R1","expires_in":86400}"#.utf8))
        }

        if path == "/api/oauth/usage" {
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(currentAccessToken)" else {
                return (401, Data(#"{"error":"unauthorized"}"#.utf8))
            }
            return (200, Data(#"{"five_hour":{"utilization":12.5}}"#.utf8))
        }

        return (404, Data(#"{"error":"not_found"}"#.utf8))
    }
}

private final class RotatingMockOAuthURLProtocol: URLProtocol {
    static let server = RotatingMockOAuthServer()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (statusCode, data) = Self.server.respond(to: request)
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor MockClaudeKeychainReader {
    var data: Data?
    private var services: [String] = []

    init(data: Data?) { self.data = data }

    func read(service: String) -> Data? {
        services.append(service)
        return data
    }

    func replace(with data: Data) { self.data = data }
    func requestedServices() -> [String] { services }
}

final class ClaudeProviderTests: XCTestCase {
    private func makeCredentialsFile(expiresAt: Double) throws -> (directory: URL, file: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeProviderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(".credentials.json")
        let json = """
        {"claudeAiOauth":{"accessToken":"A0","refreshToken":"R0","expiresAt":\(expiresAt),"subscriptionType":"max"}}
        """
        try Data(json.utf8).write(to: file)
        return (directory, file)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RotatingMockOAuthURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    func testExpiredCredentialsAreLeftForClaudeCodeToRenew() async throws {
        let credentials = try makeCredentialsFile(expiresAt: 1)
        defer { try? FileManager.default.removeItem(at: credentials.directory) }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        RotatingMockOAuthURLProtocol.server.reset()
        let provider = ClaudeProvider(credentialsPath: credentials.file.path, session: session, proxyConfig: { nil })

        for _ in 0..<2 {
            do {
                _ = try await provider.fetch()
                XCTFail("Expired shared credentials should request renewal")
            } catch let error as ClaudeError {
                guard case .refreshRequired = error else {
                    return XCTFail("Unexpected Claude error: \(error)")
                }
            }
        }

        XCTAssertEqual(RotatingMockOAuthURLProtocol.server.successfulRefreshCount(), 0)
        XCTAssertEqual(RotatingMockOAuthURLProtocol.server.requestLog(), [])
        let stored = try XCTUnwrap(ClaudeProvider.decodeCredentials(Data(contentsOf: credentials.file)))
        XCTAssertEqual(stored.refreshToken, "R0")
    }

    func testUnexpiredCredentialsFetchUsageWithoutRefreshing() async throws {
        let expiresAt = Date().addingTimeInterval(3_600).timeIntervalSince1970 * 1_000
        let credentials = try makeCredentialsFile(expiresAt: expiresAt)
        defer { try? FileManager.default.removeItem(at: credentials.directory) }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        RotatingMockOAuthURLProtocol.server.reset()
        let reader = MockClaudeKeychainReader(data: nil)
        let provider = ClaudeProvider(
            credentialsPath: credentials.file.path,
            session: session,
            keychainReader: { await reader.read(service: $0) },
            proxyConfig: { nil }
        )

        let usage = try await provider.fetch()

        XCTAssertEqual(usage.windows.map(\.usedPercent), [12.5])
        XCTAssertEqual(RotatingMockOAuthURLProtocol.server.successfulRefreshCount(), 0)
        XCTAssertEqual(RotatingMockOAuthURLProtocol.server.requestLog(), ["GET /api/oauth/usage"])
        let requestedServices = await reader.requestedServices()
        XCTAssertEqual(requestedServices, [], "A credentials file should not trigger a Keychain read")
    }

    private func keychainCredentials(accessToken: String = "A0", expiresAt: Double? = nil) -> Data {
        let expiry = expiresAt ?? Date().addingTimeInterval(3_600).timeIntervalSince1970 * 1_000
        return Data("""
        {"claudeAiOauth":{"accessToken":"\(accessToken)","refreshToken":"R0","expiresAt":\(expiry),"subscriptionType":"max"}}
        """.utf8)
    }

    func testKeychainCredentialsAreReadFreshAfterClaudeCodeRenewal() async throws {
        let reader = MockClaudeKeychainReader(data: keychainCredentials())
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        RotatingMockOAuthURLProtocol.server.reset()
        let provider = ClaudeProvider(
            credentialsPath: "/missing-claude-credentials-\(UUID().uuidString)",
            keychainService: "test-service",
            session: session,
            keychainReader: { await reader.read(service: $0) },
            proxyConfig: { nil }
        )

        let initialUsage = try await provider.fetch()
        RotatingMockOAuthURLProtocol.server.simulateClaudeCodeRenewal()
        await reader.replace(with: keychainCredentials(accessToken: "A1"))
        let renewedUsage = try await provider.fetch()

        XCTAssertEqual(initialUsage.windows.map(\.usedPercent), [12.5])
        XCTAssertEqual(renewedUsage.windows.map(\.usedPercent), [12.5])
        let requestedServices = await reader.requestedServices()
        XCTAssertEqual(requestedServices, ["test-service", "test-service"])
        XCTAssertEqual(RotatingMockOAuthURLProtocol.server.successfulRefreshCount(), 0)
        XCTAssertEqual(RotatingMockOAuthURLProtocol.server.requestLog(), ["GET /api/oauth/usage", "GET /api/oauth/usage"])
    }

    func testExpiredKeychainCredentialsDoNotRefreshOrFetchUsage() async throws {
        let data = keychainCredentials(expiresAt: 1)
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        RotatingMockOAuthURLProtocol.server.reset()
        let provider = ClaudeProvider(
            credentialsPath: "/missing-claude-credentials-\(UUID().uuidString)",
            session: session,
            keychainReader: { _ in data },
            proxyConfig: { nil }
        )

        do {
            _ = try await provider.fetch()
            XCTFail("Expired Keychain credentials should require Claude Code renewal")
        } catch let error as ClaudeError {
            guard case .refreshRequired = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(RotatingMockOAuthURLProtocol.server.requestLog(), [])
    }

    func testMissingOrInvalidKeychainCredentialsReportNotSignedIn() async throws {
        for data in [nil, Data("invalid credential document".utf8)] as [Data?] {
            let provider = ClaudeProvider(
                credentialsPath: "/missing-claude-credentials-\(UUID().uuidString)",
                keychainReader: { _ in data },
                proxyConfig: { nil }
            )
            do {
                _ = try await provider.loadCredentials()
                XCTFail("Missing or invalid credentials should report not signed in")
            } catch let error as ClaudeError {
                guard case .notSignedIn = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
    }

    func testKeychainReaderFailureIsNotReportedAsSignedOut() async throws {
        let provider = ClaudeProvider(
            credentialsPath: "/missing-claude-credentials-\(UUID().uuidString)",
            keychainReader: { _ in throw URLError(.timedOut) },
            proxyConfig: { nil }
        )
        do {
            _ = try await provider.loadCredentials()
            XCTFail("Keychain reader failures should explain access failure")
        } catch let error as ClaudeError {
            guard case .keychainUnavailable = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testCancelledKeychainReadPropagatesCancellation() async throws {
        let provider = ClaudeProvider(
            credentialsPath: "/missing-claude-credentials-\(UUID().uuidString)",
            keychainReader: { _ in throw CancellationError() },
            proxyConfig: { nil }
        )
        do {
            _ = try await provider.loadCredentials()
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {
            // Cancellation is distinct from a missing or unreadable credential.
        }
    }

    func testDecodeCredentialsMillisecondExpiry() throws {
        let json = """
        {"claudeAiOauth":{"accessToken":"at","refreshToken":"rt","expiresAt":1770073758676,"subscriptionType":"max"}}
        """
        let creds = try XCTUnwrap(ClaudeProvider.decodeCredentials(Data(json.utf8)))
        XCTAssertEqual(creds.accessToken, "at")
        XCTAssertEqual(creds.refreshToken, "rt")
        XCTAssertEqual(creds.subscriptionType, "max")
        // 1770073758676 ms == 2026-02-02, well in the past -> expired.
        XCTAssertTrue(creds.isExpired)
    }

    func testUsageMappingFromResponse() throws {
        let json = """
        {
          "five_hour": {"utilization": 12.5, "resets_at": "2026-07-01T20:24:41Z"},
          "seven_day": {"utilization": 5.0, "resets_at": "2026-07-08T00:00:00Z"},
          "seven_day_opus": {"utilization": 40.0, "resets_at": "2026-07-08T00:00:00Z"}
        }
        """
        let response = try JSONDecoder().decode(ClaudeProvider.UsageResponse.self, from: Data(json.utf8))
        let usage = ClaudeProvider.usage(from: response, plan: "max", now: Date())
        XCTAssertEqual(usage.planName, "Max")
        XCTAssertEqual(usage.windows.map(\.label), ["5h limit", "Weekly limit", "Weekly (Opus)"])
        XCTAssertEqual(usage.worstWindow?.label, "Weekly (Opus)")
        XCTAssertEqual(usage.worstWindow?.usedPercent, 40.0)
        XCTAssertNotNil(usage.windows[0].resetsAt)
    }

    func testUsageMappingAddsModelWeeklyLimits() throws {
        // The `limits` list of Anthropic's usage endpoint, as T3 Code and
        // Claude Code read it: Fable's own weekly limit is a `weekly_scoped`
        // entry. Resets come as dates or as seconds since 1970.
        let json = """
        {
          "five_hour": {"utilization": 62, "resets_at": "2026-11-14T20:00:00Z"},
          "seven_day": {"utilization": 31, "resets_at": "2026-11-20T03:41:00Z"},
          "seven_day_opus": null,
          "limits": [
            {"kind": "session", "group": "session", "percent": 62, "resets_at": "2026-11-14T20:00:00Z", "scope": null},
            {"kind": "weekly_all", "group": "weekly", "percent": 31, "resets_at": "2026-11-20T03:41:00Z", "scope": null},
            {"kind": "weekly_scoped", "percent": 73.4, "resets_at": "2026-11-20T03:41:00.123456+00:00",
             "scope": {"model": {"display_name": "Fable"}}},
            {"kind": "weekly_scoped", "percent": 12, "resets_at": 1795000000,
             "scope": {"model": {"display_name": "Nova"}}},
            {"kind": "weekly_scoped", "percent": "high", "scope": {"model": {"display_name": "Odd"}}},
            {"kind": "weekly_scoped", "percent": 5, "scope": {"model": null}},
            null
          ]
        }
        """
        let response = try JSONDecoder().decode(ClaudeProvider.UsageResponse.self, from: Data(json.utf8))
        let usage = ClaudeProvider.usage(from: response, plan: "max", now: Date())

        XCTAssertEqual(usage.windows.map(\.label), ["5h limit", "Weekly limit", "Weekly (Fable)", "Weekly (Nova)"])
        XCTAssertEqual(usage.windows.map(\.shortLabel), ["5h", "Week", "Fable", "Nova"])
        XCTAssertEqual(usage.windows[2].usedPercent, 73.4)
        XCTAssertNotNil(usage.windows[2].resetsAt)
        XCTAssertEqual(usage.windows[2].duration, 7 * 24 * 3600)
        XCTAssertEqual(usage.windows[3].resetsAt, Date(timeIntervalSince1970: 1_795_000_000))
        XCTAssertEqual(usage.worstWindow?.label, "Weekly (Fable)", "Fable counts toward the menu bar's highest limit")
    }

    func testUsageMappingKeepsOneOpusWindow() throws {
        let json = """
        {
          "seven_day_opus": {"utilization": 40.0, "resets_at": "2026-07-08T00:00:00Z"},
          "limits": [{"kind": "weekly_scoped", "percent": 41, "scope": {"model": {"display_name": "Opus"}}}]
        }
        """
        let response = try JSONDecoder().decode(ClaudeProvider.UsageResponse.self, from: Data(json.utf8))
        let usage = ClaudeProvider.usage(from: response, plan: nil, now: Date())
        XCTAssertEqual(usage.windows.map(\.label), ["Weekly (Opus)"])
        XCTAssertEqual(usage.windows.map(\.shortLabel), ["Opus"])
        XCTAssertEqual(usage.windows.first?.usedPercent, 40)
    }

    func testUsageMappingSkipsMissingWindows() throws {
        let json = #"{"five_hour": {"utilization": 3.0, "resets_at": "2026-07-01T20:24:41Z"}}"#
        let response = try JSONDecoder().decode(ClaudeProvider.UsageResponse.self, from: Data(json.utf8))
        let usage = ClaudeProvider.usage(from: response, plan: nil, now: Date())
        XCTAssertEqual(usage.windows.count, 1)
    }
}
