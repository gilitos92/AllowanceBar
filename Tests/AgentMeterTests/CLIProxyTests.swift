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
              {"auth_index":"idx-codex","type":"codex","provider":"codex","email":"main@example.com","disabled":false}
            ]}
            """.utf8))
        case "/v0/management/api-call":
            let body = request.httpBodyStreamData() ?? request.httpBody ?? Data()
            apiCallBodies.append((try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:])
            let usage = #"{\"five_hour\":{\"utilization\":42.0}}"#
            return (200, Data(#"{"status_code":\#(upstreamStatus),"header":{},"body":"\#(usage)"}"#.utf8))
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
        config: CLIProxyConfig?
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
            proxyConfig: { config }
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
        XCTAssertEqual(CLIProxyConfig.normalizedURL(" https://proxy.example.com ")?.absoluteString, "https://proxy.example.com")
        XCTAssertNil(CLIProxyConfig.normalizedURL("ftp://proxy.example.com"))
    }

    func testConfigNeedsAManagementKey() {
        let defaults = UserDefaults(suiteName: "CLIProxyTests-\(UUID().uuidString)")!
        XCTAssertNil(CLIProxyConfig.current(defaults: defaults, managementKey: { nil }))
        defaults.set(["claude": "main@example.com"], forKey: CLIProxyConfig.claudeEmailsDefaultsKey)
        let config = CLIProxyConfig.current(defaults: defaults, managementKey: { "k" })
        XCTAssertEqual(config?.baseURL.absoluteString, CLIProxyConfig.defaultURL)
        XCTAssertEqual(config?.claudeEmails, ["claude": "main@example.com"])
    }
}
