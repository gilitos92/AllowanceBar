import XCTest
@testable import AgentMeter

/// Answers like a CLIProxyAPI management API with two Claude logins.
private final class MockCLIProxyServer {
    private let lock = NSLock()
    private var log: [String] = []
    private var apiCallBodies: [[String: Any]] = []
    var authFilesStatus = 200
    var authFilesBody = #"{"error":"remote management disabled"}"#
    var upstreamStatus = 200

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        log = []
        apiCallBodies = []
        authFilesStatus = 200
        upstreamStatus = 200
    }

    func requestLog() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    func lastAPICall() -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return apiCallBodies.last
    }

    func apiCalls() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return apiCallBodies
    }

    func respond(to request: URLRequest) -> (Int, Data) {
        lock.lock()
        defer { lock.unlock() }
        let path = request.url?.path ?? ""
        log.append("\(request.httpMethod ?? "GET") \(request.url?.host ?? "")\(path)")
        if path.hasPrefix("/v0/management/") {
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer mgmt-key" else {
                return (401, Data(#"{"error":"invalid management key"}"#.utf8))
            }
        }
        switch path {
        case "/v0/management/auth-files":
            guard authFilesStatus == 200 else { return (authFilesStatus, Data(authFilesBody.utf8)) }
            return (200, Data("""
            {"files":[
              {"auth_index":"idx-main","type":"claude","provider":"claude","email":"Main@Example.com","disabled":false},
              {"auth_index":"idx-off","type":"claude","provider":"claude","email":"off@example.com","disabled":true},
              {"auth_index":"idx-codex","type":"codex","provider":"codex","email":"main@example.com","disabled":false,
               "id_token":{"chatgpt_account_id":"acct-123","plan_type":"plus"}},
              {"auth_index":7,"type":"antigravity","provider":"antigravity","email":"ag@example.com","project_id":"proj-ag"},
              {"auth_index":"idx-gem","type":"gemini-cli","provider":"gemini-cli","email":"gem@example.com","project_id":"proj-gem"},
              {"auth_index":"idx-kimi","type":"kimi","provider":"kimi","email":"k@example.com","id_token":"not-an-object"}
            ]}
            """.utf8))
        case "/v0/management/api-call":
            let body = request.httpBodyStreamData() ?? request.httpBody ?? Data()
            let call = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            apiCallBodies.append(call)
            let url = call["url"] as? String ?? ""
            var status = upstreamStatus
            let upstream: String
            if url.contains("api.anthropic.com") {
                upstream = #"{"five_hour":{"utilization":42.0}}"#
            } else if url.contains("wham/usage") {
                upstream = """
                {"plan_type":"plus","rate_limit":{"allowed":true,"limit_reached":false,
                 "primary_window":{"used_percent":12,"limit_window_seconds":18000,"reset_at":1785902974},
                 "secondary_window":{"used_percent":40,"limit_window_seconds":604800,"reset_after_seconds":3600}},
                 "credits":{"has_credits":false}}
                """
            } else if url.contains("retrieveUserQuotaSummary") {
                // The first host fails, like a project that only one host serves.
                if url.contains("daily-cloudcode-pa.googleapis.com") { status = 404 }
                upstream = """
                {"groups":[
                  {"displayName":"Gemini Models","buckets":[
                    {"window":"weekly","displayName":"Weekly Limit Remaining","remainingFraction":0.5,"resetTime":"2026-11-10T00:00:00Z"},
                    {"window":"5h","displayName":"Five Hour Limit Remaining","remainingFraction":0.9,"resetTime":"2026-11-03T05:00:00Z"}]},
                  {"displayName":"Claude and GPT models","buckets":[
                    {"window":"5h","remainingFraction":"25%"}]}
                ]}
                """
            } else if url.contains("retrieveUserQuota") {
                upstream = #"{"buckets":[{"modelId":"gemini-2.5-pro","remainingFraction":0.75,"resetTime":"2026-11-04T00:00:00Z"}]}"#
            } else {
                upstream = "{}"
            }
            let wrapped: [String: Any] = ["status_code": status, "header": [:], "body": upstream]
            return (200, try! JSONSerialization.data(withJSONObject: wrapped))
        case "/api/oauth/usage":
            return (200, Data(#"{"five_hour":{"utilization":7.0}}"#.utf8))
        default:
            return (404, Data(#"{"error":"not_found"}"#.utf8))
        }
    }
}

private extension URLRequest {
    /// URLSession moves bodies into a stream before URLProtocol sees them.
    func httpBodyStreamData() -> Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class MockCLIProxyURLProtocol: URLProtocol {
    static let server = MockCLIProxyServer()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (statusCode, data) = Self.server.respond(to: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class CLIProxyTests: XCTestCase {
    private var directory: URL!
    private var session: URLSession!
    private let config = CLIProxyConfig(
        baseURL: URL(string: "http://proxy.test:8317")!,
        managementKey: "mgmt-key",
        claudeEmails: [:]
    )

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIProxyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockCLIProxyURLProtocol.self]
        session = URLSession(configuration: configuration)
        MockCLIProxyURLProtocol.server.reset()
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: directory)
    }

    private func writeFile(_ name: String, _ json: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        try Data(json.utf8).write(to: url)
        return url.path
    }

    private func makeProvider(
        id: String = "claude",
        expiresAt: Double,
        email: String? = "main@example.com",
        config: CLIProxyConfig?,
        cache: CLIProxyAccountCache = CLIProxyAccountCache()
    ) throws -> ClaudeProvider {
        let credentials = try writeFile(".credentials.json", """
        {"claudeAiOauth":{"accessToken":"local","refreshToken":"R0","expiresAt":\(expiresAt),"subscriptionType":"max"}}
        """)
        let accountInfo = try writeFile(".claude.json", email.map {
            #"{"oauthAccount":{"emailAddress":"\#($0)"}}"#
        } ?? "{}")
        return ClaudeProvider(
            id: id,
            credentialsPath: credentials,
            accountInfoPath: accountInfo,
            session: session,
            keychainReader: { _ in nil },
            proxyConfig: { config },
            proxyAccountCache: cache
        )
    }

    func testExpiredLocalLoginUsesProxyLoginWithSameEmail() async throws {
        let provider = try makeProvider(expiresAt: 1, config: config)

        let usage = try await provider.fetch()

        XCTAssertEqual(usage.windows.map(\.usedPercent), [42])
        XCTAssertEqual(usage.planName, "Max", "The plan still comes from Claude Code's login")
        XCTAssertEqual(MockCLIProxyURLProtocol.server.requestLog(), [
            "GET proxy.test/v0/management/auth-files",
            "POST proxy.test/v0/management/api-call",
        ])
        let call = try XCTUnwrap(MockCLIProxyURLProtocol.server.lastAPICall())
        XCTAssertEqual(call["auth_index"] as? String, "idx-main")
        XCTAssertEqual(call["url"] as? String, "https://api.anthropic.com/api/oauth/usage")
        let header = try XCTUnwrap(call["header"] as? [String: String])
        XCTAssertEqual(header["Authorization"], "Bearer $TOKEN$", "The token must stay on the proxy")
        XCTAssertEqual(header["anthropic-beta"], ClaudeProvider.betaHeader)
    }

    func testValidLocalLoginDoesNotAskTheProxy() async throws {
        let expiresAt = Date().addingTimeInterval(3_600).timeIntervalSince1970 * 1_000
        let provider = try makeProvider(expiresAt: expiresAt, config: config)

        let usage = try await provider.fetch()

        XCTAssertEqual(usage.windows.map(\.usedPercent), [7])
        XCTAssertEqual(MockCLIProxyURLProtocol.server.requestLog(), ["GET api.anthropic.com/api/oauth/usage"])
    }

    func testChosenProxyLoginOverridesEmailMatch() async throws {
        var chosen = config
        chosen.claudeEmails = ["claude": "off@example.com"]
        let provider = try makeProvider(expiresAt: 1, config: chosen)

        do {
            _ = try await provider.fetch()
            XCTFail("A turned-off proxy login must not be used")
        } catch let error as CLIProxyError {
            XCTAssertEqual(error, .loginDisabled)
        }
    }

    func testExtraAccountWithoutEmailDoesNotGuessALogin() async throws {
        let provider = try makeProvider(id: "claude:\(UUID().uuidString)", expiresAt: 1, email: nil, config: config)

        do {
            _ = try await provider.fetch()
            XCTFail("Without an email the extra account has no proxy login")
        } catch let error as CLIProxyError {
            XCTAssertEqual(error, .loginNotFound)
        }
    }

    func testRemoteManagementDisabledIsExplained() async throws {
        MockCLIProxyURLProtocol.server.authFilesStatus = 403
        let provider = try makeProvider(expiresAt: 1, config: config)

        do {
            _ = try await provider.fetch()
            XCTFail("A refused management request should fail")
        } catch let error as CLIProxyError {
            XCTAssertEqual(error, .remoteManagementDisabled)
        }
    }

    func testSignedOutProxyLoginIsReported() async throws {
        MockCLIProxyURLProtocol.server.upstreamStatus = 401
        let provider = try makeProvider(expiresAt: 1, config: config)

        do {
            _ = try await provider.fetch()
            XCTFail("Anthropic rejecting the proxy's token should fail")
        } catch let error as CLIProxyError {
            XCTAssertEqual(error, .loginSignedOut)
        }
    }

    func testWithoutProxyTheExpiredLoginStillAsksForClaudeCode() async throws {
        let provider = try makeProvider(expiresAt: 1, config: nil)

        do {
            _ = try await provider.fetch()
            XCTFail("Expected refreshRequired")
        } catch let error as ClaudeError {
            guard case .refreshRequired = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(MockCLIProxyURLProtocol.server.requestLog(), [])
    }

    func testProxyAccountMatching() {
        let accounts = [
            CLIProxyClient.Account(authIndex: "a", email: "one@example.com", disabled: true),
            CLIProxyClient.Account(authIndex: "b", email: "ONE@example.com", disabled: false),
        ]
        XCTAssertEqual(ClaudeProvider.proxyAccount(in: accounts, email: "one@EXAMPLE.com", isDefaultAccount: false)?.authIndex, "b")
        XCTAssertNil(ClaudeProvider.proxyAccount(in: accounts, email: "two@example.com", isDefaultAccount: true))
        XCTAssertNil(ClaudeProvider.proxyAccount(in: accounts, email: nil, isDefaultAccount: true))
        let single = [accounts[1]]
        XCTAssertEqual(ClaudeProvider.proxyAccount(in: single, email: nil, isDefaultAccount: true)?.authIndex, "b")
        XCTAssertNil(ClaudeProvider.proxyAccount(in: single, email: nil, isDefaultAccount: false))
    }

    func testServerAddressNormalization() {
        XCTAssertEqual(CLIProxyConfig.normalizedURL("")?.absoluteString, "http://127.0.0.1:8317")
        XCTAssertEqual(CLIProxyConfig.normalizedURL("mini.tailnet.ts.net:8317/")?.absoluteString, "http://mini.tailnet.ts.net:8317")
        XCTAssertEqual(CLIProxyConfig.normalizedURL("http://[::1]:8317")?.absoluteString, "http://[::1]:8317")
        XCTAssertEqual(CLIProxyConfig.normalizedURL(" https://proxy.example.com ")?.absoluteString, "https://proxy.example.com")
        XCTAssertNil(CLIProxyConfig.normalizedURL("ftp://proxy.example.com"))
    }

    func testPlainHTTPToOtherHostsIsRefusedSoTheKeyIsNeverSentInClearText() {
        XCTAssertNil(CLIProxyConfig.normalizedURL("proxy.example.com:8317"))
        XCTAssertNil(CLIProxyConfig.normalizedURL("http://192.168.1.20:8317"))
        XCTAssertNil(CLIProxyConfig.normalizedURL("http://100.101.2.3:8317"), "ISPs share 100.64.0.0/10 too")
        XCTAssertNil(CLIProxyConfig.normalizedURL("http://100.64.0.1.nip.io:8317"))
        XCTAssertNil(CLIProxyConfig.normalizedURL("http://mini.ts.net.example.com"))
    }

    func testProxyWithoutAKeyIsExplained() {
        XCTAssertEqual(CLIProxyError.from(statusCode: 403, message: "remote management key not set"), .keyNotSet)
        XCTAssertEqual(
            CLIProxyError.from(statusCode: 403, message: "IP banned due to too many failed attempts. Try again in 29m"),
            .tooManyAttempts
        )
    }

    func testRejectedKeyStopsFurtherProxyCallsUntilItChanges() async throws {
        let cache = CLIProxyAccountCache()
        var wrongKey = config
        wrongKey.managementKey = "wrong"
        let provider = try makeProvider(expiresAt: 1, config: wrongKey, cache: cache)

        for _ in 0..<3 {
            do {
                _ = try await provider.fetch()
                XCTFail("A wrong key should fail")
            } catch let error as CLIProxyError {
                XCTAssertEqual(error, .invalidKey)
            }
        }
        XCTAssertEqual(MockCLIProxyURLProtocol.server.requestLog().count, 1, "Only one failed key check reaches the proxy")

        let fixed = try makeProvider(expiresAt: 1, config: config, cache: cache)
        _ = try await fixed.fetch()
        XCTAssertEqual(MockCLIProxyURLProtocol.server.requestLog().count, 3)
    }

    func testBanIsWaitedOutBeforeTryingAgain() async throws {
        let cache = CLIProxyAccountCache()
        let start = Date()
        let account = CLIProxyClient.Account(authIndex: "a", email: "a@example.com", disabled: false)
        _ = try? await cache.accounts(for: config, now: start) { throw CLIProxyError.tooManyAttempts }

        for offset in [60, CLIProxyAccountCache.banWait - 1] {
            do {
                _ = try await cache.accounts(for: config, now: start.addingTimeInterval(offset)) { [account] }
                XCTFail("The proxy must not be asked during its ban")
            } catch let error as CLIProxyError {
                XCTAssertEqual(error, .tooManyAttempts)
            }
        }
        let accounts = try await cache.accounts(for: config, now: start.addingTimeInterval(CLIProxyAccountCache.banWait + 1)) {
            [account]
        }
        XCTAssertEqual(accounts, [account])
    }

    func testAccountsShareOneLoginList() async throws {
        let cache = CLIProxyAccountCache()
        let main = try makeProvider(expiresAt: 1, config: config, cache: cache)
        var chosen = config
        chosen.claudeEmails = ["claude:extra": "main@example.com"]
        let extra = try makeProvider(id: "claude:extra", expiresAt: 1, config: chosen, cache: cache)

        _ = try await main.fetch()
        _ = try await extra.fetch()

        let lists = MockCLIProxyURLProtocol.server.requestLog().filter { $0.hasSuffix("/auth-files") }
        XCTAssertEqual(lists.count, 1)
    }

    func testPlanIsDroppedWhenTheProxyLoginIsAnotherAccount() async throws {
        var chosen = config
        chosen.claudeEmails = ["claude": "main@example.com"]
        let provider = try makeProvider(expiresAt: 1, email: "other@example.com", config: chosen)

        let usage = try await provider.fetch()

        XCTAssertNil(usage.planName)
    }

    func testConfigNeedsAManagementKey() {
        let defaults = UserDefaults(suiteName: "CLIProxyTests-\(UUID().uuidString)")!
        XCTAssertNil(CLIProxyConfig.current(defaults: defaults, managementKey: { nil }))
        defaults.set(["claude": "main@example.com"], forKey: CLIProxyConfig.claudeEmailsDefaultsKey)
        let config = CLIProxyConfig.current(defaults: defaults, managementKey: { "k" })
        XCTAssertEqual(config?.baseURL.absoluteString, CLIProxyConfig.defaultURL)
        XCTAssertEqual(config?.claudeEmails, ["claude": "main@example.com"])
    }
    // MARK: - Every proxy login as its own row

    private func proxyRow(_ login: CLIProxyLoginKey, cache: CLIProxyAccountCache = CLIProxyAccountCache()) -> CLIProxyAccountProvider {
        var provider = CLIProxyAccountProvider(login: login)
        provider.session = session
        let config = config
        provider.proxyConfig = { config }
        provider.accountCache = cache
        provider.usageCache = CLIProxyUsageCache()
        return provider
    }

    func testLoginListKeepsEverySupportedKind() async throws {
        let logins = try await CLIProxyClient(config: config, session: session).logins(cache: CLIProxyAccountCache())

        XCTAssertEqual(logins.map(\.kind), [.claude, .claude, .codex, .antigravity, .gemini], "Kimi is not supported yet")
        let codex = try XCTUnwrap(logins.first { $0.kind == .codex })
        XCTAssertEqual(codex.chatgptAccountID, "acct-123")
        XCTAssertEqual(codex.planType, "plus")
        let antigravity = try XCTUnwrap(logins.first { $0.kind == .antigravity })
        XCTAssertEqual(antigravity.authIndex, "7")
        XCTAssertEqual(antigravity.projectID, "proj-ag")
    }

    func testRowsSkipTurnedOffLoginsAndKeepStableIDs() throws {
        let accounts = [
            CLIProxyClient.Account(kind: .gemini, authIndex: "g", email: "g@example.com", disabled: false, projectID: "p"),
            CLIProxyClient.Account(kind: .codex, authIndex: "c", email: "B@example.com", disabled: false),
            CLIProxyClient.Account(kind: .codex, authIndex: "c2", email: "a@example.com", disabled: false),
            CLIProxyClient.Account(kind: .claude, authIndex: "o", email: "off@example.com", disabled: true),
            CLIProxyClient.Account(kind: .codex, authIndex: "dup", email: "b@EXAMPLE.com", disabled: false),
        ]

        let keys = CLIProxyLoginKey.keys(from: accounts)

        XCTAssertEqual(keys.map(\.email), ["a@example.com", "B@example.com", "g@example.com"])
        let id = keys[1].providerID
        XCTAssertTrue(id.hasPrefix("codex:proxy-"))
        XCTAssertEqual(ProviderAccountConfig.baseProviderID(of: id), "codex")
        XCTAssertEqual(id, CLIProxyLoginKey(kind: .codex, email: "b@example.com").providerID, "Email case must not change the id")
        XCTAssertNotEqual(
            CLIProxyLoginKey(kind: .gemini, email: "g@example.com", projectID: "p").providerID,
            CLIProxyLoginKey(kind: .gemini, email: "g@example.com", projectID: "q").providerID,
            "Each Gemini project has its own quota"
        )
        XCTAssertEqual(
            CLIProxyLoginKey(kind: .codex, email: "x@example.com", projectID: "p"),
            CLIProxyLoginKey(kind: .codex, email: "x@example.com"),
            "Only Gemini keys use the project"
        )
    }

    func testCodexLoginReadsChatGPTUsageThroughTheProxy() async throws {
        let provider = proxyRow(CLIProxyLoginKey(kind: .codex, email: "MAIN@example.com"))

        let usage = try await provider.fetch()

        XCTAssertEqual(usage.windows.map(\.usedPercent), [12, 40])
        XCTAssertEqual(usage.windows.map(\.duration), [5 * 3600, 7 * 24 * 3600])
        XCTAssertEqual(usage.windows.first?.resetsAt, Date(timeIntervalSince1970: 1785902974))
        XCTAssertNotNil(usage.windows.last?.resetsAt)
        XCTAssertEqual(usage.planName, CodexPlan.displayName("plus"))
        XCTAssertEqual(usage.accountEmail, "main@example.com")
        XCTAssertEqual(provider.displayName, "Codex — MAIN@example.com")
        XCTAssertEqual(provider.shortCode, "CxM")
        let call = try XCTUnwrap(MockCLIProxyURLProtocol.server.lastAPICall())
        XCTAssertEqual(call["auth_index"] as? String, "idx-codex")
        XCTAssertEqual(call["url"] as? String, CLIProxyClient.codexUsageURL)
        let header = try XCTUnwrap(call["header"] as? [String: String])
        XCTAssertEqual(header["Authorization"], "Bearer $TOKEN$", "The token must stay on the proxy")
        XCTAssertEqual(header["Chatgpt-Account-Id"], "acct-123")
        XCTAssertNil(call["data"], "A GET sends no body")
    }

    func testCodexBlockedWindowWithoutPercentCountsAsFull() throws {
        let data = Data(#"{"rate_limit":{"limit_reached":true,"primary_window":{"limit_window_seconds":18000}}}"#.utf8)

        let usage = try CLIProxyAccountProvider.codexUsage(from: data, fallbackPlan: "pro", now: Date())

        XCTAssertEqual(usage.windows.map(\.usedPercent), [100])
        XCTAssertEqual(usage.planName, CodexPlan.displayName("pro"))
    }

    func testAntigravityLoginTriesTheNextHostAndNamesEachGroup() async throws {
        let provider = proxyRow(CLIProxyLoginKey(kind: .antigravity, email: "ag@example.com"))

        let usage = try await provider.fetch()

        XCTAssertEqual(usage.windows.map(\.label), [
            "Gemini · \(L("5h limit"))",
            "Gemini · \(L("Weekly limit"))",
            "Claude and GPT · \(L("5h limit"))",
        ])
        XCTAssertEqual(usage.windows.map(\.usedPercent).map { $0.rounded() }, [10, 50, 75])
        XCTAssertEqual(usage.windows.first?.duration, 5 * 3600)
        let calls = MockCLIProxyURLProtocol.server.apiCalls()
        XCTAssertEqual(calls.count, 2, "The second host answers")
        XCTAssertEqual(calls.last?["auth_index"] as? String, "7")
        let data = try XCTUnwrap(calls.last?["data"] as? String)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: String], ["project": "proj-ag"])
    }

    func testGeminiLoginAsksForItsProjectsQuota() async throws {
        let provider = proxyRow(CLIProxyLoginKey(kind: .gemini, email: "gem@example.com", projectID: "proj-gem"))

        let usage = try await provider.fetch()

        XCTAssertEqual(usage.windows.map(\.usedPercent), [25])
        let call = try XCTUnwrap(MockCLIProxyURLProtocol.server.lastAPICall())
        XCTAssertEqual(call["url"] as? String, GeminiProvider.quotaURL.absoluteString)
        XCTAssertEqual(call["data"] as? String, #"{"project":"proj-gem"}"#)
    }

    func testRemovedOrTurnedOffLoginIsReported() async throws {
        for login in [
            CLIProxyLoginKey(kind: .codex, email: "gone@example.com"),
            CLIProxyLoginKey(kind: .claude, email: "off@example.com"),
        ] {
            do {
                _ = try await proxyRow(login).fetch()
                XCTFail("\(login.email) is not an enabled login")
            } catch let error as CLIProxyError {
                XCTAssertEqual(error, .loginRemoved)
            }
        }
    }

    func testRowReusesItsUsageUntilAnExplicitRefresh() async throws {
        let provider = proxyRow(CLIProxyLoginKey(kind: .claude, email: "main@example.com"))

        _ = try await provider.fetch()
        _ = try await provider.fetch()
        XCTAssertEqual(MockCLIProxyURLProtocol.server.apiCalls().count, 1)

        _ = try await provider.fetch(forceRefresh: true)
        XCTAssertEqual(MockCLIProxyURLProtocol.server.apiCalls().count, 2)
    }

    func testSignedOutCodexLoginIsReported() async throws {
        MockCLIProxyURLProtocol.server.upstreamStatus = 401

        do {
            _ = try await proxyRow(CLIProxyLoginKey(kind: .codex, email: "main@example.com")).fetch()
            XCTFail("ChatGPT rejecting the proxy's token should fail")
        } catch let error as CLIProxyError {
            XCTAssertEqual(error, .loginSignedOut)
        }
    }

    func testRowsFollowTheirProviderAndAntigravityFollowsGemini() {
        let logins = [
            CLIProxyLoginKey(kind: .claude, email: "c@example.com"),
            CLIProxyLoginKey(kind: .codex, email: "x@example.com"),
            CLIProxyLoginKey(kind: .antigravity, email: "a@example.com"),
            CLIProxyLoginKey(kind: .gemini, email: "g@example.com"),
        ]

        let ids = UsageStore.defaultProviders(extraAccounts: [], proxyLogins: logins).map(\.id)

        func index(_ id: String) -> Int { ids.firstIndex(of: id) ?? -1 }
        XCTAssertEqual(index(logins[1].providerID), index("codex") + 1)
        XCTAssertEqual(index(logins[0].providerID), index("claude") + 1)
        XCTAssertEqual(index(logins[3].providerID), index("gemini") + 1)
        XCTAssertEqual(index(logins[2].providerID), index("gemini") + 2)
        XCTAssertEqual(index("openrouter"), index("gemini") + 3)
    }

    func testDuplicateNeedsTheSameProviderAndEmail() {
        let local = [
            (providerID: "codex", name: "Codex", email: "Me@example.com"),
            (providerID: "claude:\(UUID().uuidString)", name: "Claude — Work", email: "work@example.com"),
        ]

        XCTAssertEqual(UsageStore.localDuplicate(of: CLIProxyLoginKey(kind: .codex, email: "me@EXAMPLE.com"), in: local), "Codex")
        XCTAssertEqual(UsageStore.localDuplicate(of: CLIProxyLoginKey(kind: .claude, email: "work@example.com"), in: local), "Claude — Work")
        XCTAssertNil(UsageStore.localDuplicate(of: CLIProxyLoginKey(kind: .claude, email: "me@example.com"), in: local))
        XCTAssertNil(UsageStore.localDuplicate(of: CLIProxyLoginKey(kind: .antigravity, email: "me@example.com"), in: local))
    }

    @MainActor
    func testProxyRowHidesBehindTheSameLocalAccountUnlessTurnedOn() async throws {
        let suite = "CLIProxyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        var proxy = CLIProxyAccountProvider(login: CLIProxyLoginKey(kind: .codex, email: "me@example.com"))
        proxy.proxyConfig = { nil }
        let local = LocalAccountStub(id: "codex", email: "ME@example.com")
        let store = UsageStore(settings: settings, providers: [local, proxy])

        let deadline = Date().addingTimeInterval(3)
        while store.state(for: "codex").usage == nil {
            guard Date() < deadline else { return XCTFail("The local account never loaded") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertEqual(store.visibleProviders.map(\.id), ["codex"])
        XCTAssertEqual(store.localDuplicateName(of: proxy), "Codex")
        XCTAssertEqual(settings.localAccountEmails["codex"], "ME@example.com")
        settings.setMode(.on, for: proxy.id)
        XCTAssertEqual(store.visibleProviders.map(\.id), ["codex", proxy.id])
    }

    @MainActor
    func testRememberedEmailHidesTheProxyRowWhileTheLocalAccountLoads() {
        let suite = "CLIProxyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.localAccountEmails = ["codex": "me@example.com"]
        var proxy = CLIProxyAccountProvider(login: CLIProxyLoginKey(kind: .codex, email: "me@example.com"))
        proxy.proxyConfig = { nil }
        let store = UsageStore(settings: settings, providers: [LocalAccountStub(id: "codex", email: nil, delay: 10), proxy])

        XCTAssertEqual(store.visibleProviders.map(\.id), ["codex"])
    }

    @MainActor
    func testLoginsPersistAcrossLaunches() {
        let suite = "CLIProxyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let logins = [CLIProxyLoginKey(kind: .gemini, email: "g@example.com", projectID: "p")]

        SettingsStore(defaults: defaults).cliProxyLogins = logins

        XCTAssertEqual(SettingsStore(defaults: defaults).cliProxyLogins, logins)
    }
}

/// A local account that reports an email after an optional delay.
private struct LocalAccountStub: UsageProvider {
    let id: String
    let email: String?
    var delay: TimeInterval = 0
    var displayName: String { "Codex" }
    var shortCode: String { "Cx" }
    var isDetected: Bool { true }

    func fetch() async throws -> ProviderUsage {
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        return ProviderUsage(planName: nil, windows: [], asOf: Date(), accountEmail: email)
    }
}
