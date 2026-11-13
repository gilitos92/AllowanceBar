import XCTest
@testable import AgentMeter

final class MuseCodeProviderTests: XCTestCase {
    // Shapes from Muse Code's MSP schema (meta-models/muse-code-sdk,
    // schema/msp: UsageRefreshResult, SubscriptionUsage, AccountState).
    private let account = #"{"jsonrpc":"2.0","id":2,"result":{"state":"accountLogin","label":"me@example.com","credentialRequired":true}}"#
    private let refresh = #"{"jsonrpc":"2.0","id":3,"result":{"usage":{"observedAtMs":1794600000000,"tier":"power_usage","window":{"usedPercent":42,"resetsAtMs":1794610000000,"windowDurationMins":300},"weekly":{"usedPercent":17,"resetsAtMs":1795000000000}},"tierName":"Power Usage","subscriptionActive":true}}"#

    func testReadingFromRefreshAnswer() throws {
        let reading = try MuseServeClient.reading(account: object(account), refresh: object(refresh))
        XCTAssertEqual(reading.tierName, "Power Usage")
        XCTAssertEqual(reading.tierID, "power_usage")
        XCTAssertEqual(reading.window, MuseWindow(usedPercent: 42, resetsAt: Date(timeIntervalSince1970: 1_794_610_000), minutes: 300))
        XCTAssertEqual(reading.weekly, MuseWindow(usedPercent: 17, resetsAt: Date(timeIntervalSince1970: 1_795_000_000), minutes: nil))
        XCTAssertEqual(reading.observedAt, Date(timeIntervalSince1970: 1_794_600_000))
        XCTAssertEqual(reading.accountLabel, "me@example.com")
    }

    func testUsageShowsFiveHourAndWeeklyWindows() throws {
        let reading = try MuseServeClient.reading(account: object(account), refresh: object(refresh))
        let usage = MuseServeClient.usage(from: reading, now: Date())
        XCTAssertEqual(usage.planName, "Power Usage")
        XCTAssertEqual(usage.windows.map(\.label), ["5h limit", "Weekly limit"])
        XCTAssertEqual(usage.windows.map(\.usedPercent), [42, 17])
        XCTAssertEqual(usage.windows.map(\.duration), [5 * 3600, 7 * 86_400])
        XCTAssertEqual(usage.asOf, Date(timeIntervalSince1970: 1_794_600_000))
        XCTAssertEqual(usage.accountEmail, "me@example.com")
    }

    func testPlanFallsBackToTierIDAndLabelWithoutEmailIsNotAnEmail() throws {
        let refresh = #"{"id":3,"result":{"usage":{"observedAtMs":1,"tier":"everyday","window":{"usedPercent":101,"resetsAtMs":2,"windowDurationMins":300},"weekly":{"usedPercent":0,"resetsAtMs":3}}}}"#
        let account = #"{"id":2,"result":{"state":"accountLogin","label":"Gil","credentialRequired":true}}"#
        let reading = try MuseServeClient.reading(account: object(account), refresh: object(refresh))
        let usage = MuseServeClient.usage(from: reading, now: Date())
        XCTAssertEqual(usage.planName, "everyday")
        XCTAssertNil(usage.accountEmail)
        XCTAssertEqual(usage.windows.first?.usedPercent, 101)
    }

    func testErrors() throws {
        let loggedOut = #"{"id":2,"result":{"state":"loggedOut","credentialRequired":true}}"#
        let apiKey = #"{"id":2,"result":{"state":"apiKey","label":"stored key","credentialRequired":true}}"#
        // Captured from Muse Code 1.4.18 without a Meta-account login.
        let unavailable = #"{"jsonrpc":"2.0","id":4,"error":{"code":-32081,"message":"usage/refresh needs a Meta-account login on this host","data":{"kind":"usageRefreshUnavailable","retryable":false}}}"#
        let rateLimited = #"{"id":3,"error":{"code":-32080,"message":"wait","data":{"kind":"usageRefreshRateLimited","retryAfterMs":42000,"retryable":true}}}"#
        let experimental = #"{"id":3,"error":{"code":-32601,"message":"experimental","data":{"kind":"experimentalRequired"}}}"#
        func failed(_ failureKind: String) -> String {
            #"{"id":3,"error":{"code":-32082,"message":"Meta says no","data":{"kind":"usageRefreshFailed","failureKind":"\#(failureKind)"}}}"#
        }
        let noSubscription = #"{"id":3,"result":{"subscriptionActive":false}}"#
        let noUsage = #"{"id":3,"result":{"subscriptionActive":true,"tierName":"Everyday Usage"}}"#

        XCTAssertThrowsError(try MuseServeClient.reading(account: object(loggedOut), refresh: object(unavailable))) {
            XCTAssertEqual($0 as? MuseServeError, .notSignedIn)
        }
        XCTAssertThrowsError(try MuseServeClient.reading(account: object(apiKey), refresh: object(unavailable))) {
            XCTAssertEqual($0 as? MuseServeError, .apiKeyOnly)
        }
        XCTAssertThrowsError(try MuseServeClient.reading(account: nil, refresh: object(rateLimited))) {
            XCTAssertEqual($0 as? MuseServeError, .rateLimited(retryAfter: 42))
        }
        XCTAssertThrowsError(try MuseServeClient.reading(account: nil, refresh: object(experimental))) {
            XCTAssertEqual($0 as? MuseServeError, .unsupportedVersion)
        }
        let failures: [(String, MuseServeError)] = [
            ("credential_rejected", .notSignedIn),
            ("payment_subscription_required", .noSubscription),
            ("onboarding", .accountSetupRequired),
            ("age_requirement", .accountSetupRequired),
            ("transient", .refreshFailed),
            ("terminal", .refreshFailed),
        ]
        for (kind, expected) in failures {
            XCTAssertThrowsError(try MuseServeClient.reading(account: object(account), refresh: object(failed(kind)))) {
                XCTAssertEqual($0 as? MuseServeError, expected, kind)
            }
        }
        XCTAssertThrowsError(try MuseServeClient.reading(account: object(account), refresh: object(noSubscription))) {
            XCTAssertEqual($0 as? MuseServeError, .noSubscription)
        }
        XCTAssertThrowsError(try MuseServeClient.reading(account: object(account), refresh: object(noUsage))) {
            XCTAssertEqual($0 as? MuseServeError, .noUsageData)
        }
    }

    func testExtraAccountsGetTheirOwnInstructions() {
        XCTAssertEqual(MuseServeError.notSignedIn.forExtraAccount, .notSignedInExtraAccount)
        XCTAssertEqual(MuseServeError.apiKeyOnly.forExtraAccount, .apiKeyOnlyExtraAccount)
        XCTAssertEqual(MuseServeError.accountSetupRequired.forExtraAccount, .accountSetupRequiredExtraAccount)
        XCTAssertEqual(MuseServeError.noSubscription.forExtraAccount, .noSubscription)
        for error in [MuseServeError.apiKeyOnlyExtraAccount, .accountSetupRequiredExtraAccount] {
            XCTAssertFalse(error.errorDescription?.contains("(muse login)") ?? true)
            XCTAssertTrue(error.errorDescription?.contains("Settings") ?? false)
        }
    }

    func testFailuresWaitBeforeMuseCodeStartsAgain() {
        XCTAssertEqual(MuseServeClient.retryInterval(after: .apiKeyOnly), MuseServeClient.pollInterval)
        XCTAssertEqual(MuseServeClient.retryInterval(after: .noSubscription), MuseServeClient.pollInterval)
        XCTAssertEqual(MuseServeClient.retryInterval(after: .refreshFailed), MuseServeClient.minimumInterval)
        XCTAssertEqual(MuseServeClient.retryInterval(after: .rateLimited(retryAfter: 120)), 120)
        XCTAssertEqual(MuseServeClient.retryInterval(after: .rateLimited(retryAfter: nil)), MuseServeClient.minimumInterval)
    }

    /// A remembered failure is shown again without starting Muse Code (the
    /// configured folder does not exist, so a start would fail differently).
    @MainActor
    func testRememberedFailureIsReused() async throws {
        var provider = MuseCodeProvider()
        provider.id = "muse:test-\(UUID().uuidString)"
        provider.configHome = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        defer { MuseUsageCache.shared.clear(providerID: provider.id) }

        MuseUsageCache.shared.storeFailure(.apiKeyOnly, for: provider.id, at: Date().addingTimeInterval(-120))
        do {
            _ = try await provider.fetch(forceRefresh: false)
            XCTFail("Expected the remembered failure")
        } catch {
            XCTAssertEqual(error as? MuseServeError, .apiKeyOnly)
        }

        // Rate limited with an earlier answer: the answer stays on screen.
        let reading = try MuseServeClient.reading(account: object(account), refresh: object(refresh))
        MuseUsageCache.shared.store(reading, for: provider.id, at: Date().addingTimeInterval(-600))
        MuseUsageCache.shared.storeFailure(.rateLimited(retryAfter: 300), for: provider.id, at: Date().addingTimeInterval(-10))
        let usage = try await provider.fetch(forceRefresh: true)
        XCTAssertEqual(usage.planName, "Power Usage")
    }

    func testEnvironmentDropsAPIKeyAndSetsConfigHome() {
        let base = ["PATH": "/usr/bin", "META_API_KEY": "secret"]
        XCTAssertEqual(MuseServeClient.environment(base: base, configHome: nil), ["PATH": "/usr/bin"])
        XCTAssertEqual(
            MuseServeClient.environment(base: base, configHome: URL(fileURLWithPath: "/tmp/muse-work")),
            ["PATH": "/usr/bin", "XDG_CONFIG_HOME": "/tmp/muse-work", "TBH_CREDENTIAL_BACKEND": "file"]
        )
    }

    /// A stand-in `muse` that, like the real host, refuses to answer anything
    /// before `initialize` has been answered.
    func testHandshakeWithFakeHost() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-fake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("muse")
        try """
        #!/bin/bash
        [ "$1 $2" = "serve --no-session-log" ] || exit 2
        read -r line
        case "$line" in *'"method":"initialize"'*'"experimentalApi":true'*) ;; *) exit 3 ;; esac
        echo '{"jsonrpc":"2.0","id":1,"result":{"experimentalApi":true}}'
        read -r a; read -r b; read -r c
        case "$a$b$c" in *'"initialized"'*'"account/read"'*'"usage/refresh"'*) ;; *) exit 4 ;; esac
        echo '{"jsonrpc":"2.0","method":"session/listChanged","params":{}}'
        echo '{"jsonrpc":"2.0","id":2,"result":{"state":"accountLogin","label":"'"$XDG_CONFIG_HOME"'","credentialRequired":true}}'
        echo '\(refresh)'
        sleep 30
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let started = Date()
        let reading = try await MuseServeClient.readUsage(
            configHome: URL(fileURLWithPath: "/tmp/muse-work@example.com"),
            executable: script,
            timeout: 10
        )
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(reading.accountLabel, "/tmp/muse-work@example.com")
        XCTAssertEqual(reading.tierName, "Power Usage")
        XCTAssertEqual(reading.window?.usedPercent, 42)
    }

    func testSilentHostTimesOut() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-silent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("muse")
        try "#!/bin/bash\nexec sleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let started = Date()
        do {
            _ = try await MuseServeClient.readUsage(configHome: nil, executable: script, timeout: 1)
            XCTFail("A silent host returned usage")
        } catch {
            XCTAssertEqual(error as? MuseServeError, .timeout)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    /// Runs the installed Muse Code against an empty config folder, so it is
    /// signed out, then with a fake API key. Opt-in: MUSE_LIVE_TEST=1.
    func testLiveSignedOutHost() async throws {
        guard ProcessInfo.processInfo.environment["MUSE_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set MUSE_LIVE_TEST=1 to run the live Muse Code test")
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            _ = try await MuseServeClient.readUsage(configHome: folder)
            XCTFail("A signed-out host returned usage")
        } catch {
            XCTAssertEqual(error as? MuseServeError, .notSignedIn)
        }
        // The provider, as the app runs it for an extra account.
        var provider = MuseCodeProvider()
        provider.id = "muse:live-\(UUID().uuidString)"
        provider.configHome = folder
        XCTAssertFalse(provider.isDetected)
        do {
            _ = try await provider.fetch(forceRefresh: true)
            XCTFail("A signed-out account returned usage")
        } catch {
            XCTAssertEqual(error as? MuseServeError, .notSignedInExtraAccount)
        }

        // A fake API key kept in the folder (not the shared Keychain item).
        let muse = try XCTUnwrap(CommandLocator.resolve("muse"))
        let store = Process()
        store.executableURL = muse
        store.arguments = ["auth", "set", "--api-key-stdin"]
        store.environment = MuseServeClient.environment(
            base: ProcessInfo.processInfo.environment,
            configHome: folder
        )
        let input = Pipe()
        store.standardInput = input
        store.standardOutput = FileHandle.nullDevice
        try store.run()
        try input.fileHandleForWriting.write(contentsOf: Data("fake-test-key\n".utf8))
        try input.fileHandleForWriting.close()
        store.waitUntilExit()
        XCTAssertEqual(store.terminationStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: MuseServeClient.authFile(configRoot: folder).path))

        XCTAssertTrue(provider.isDetected)
        // A new id: the signed-out failure above is remembered for a minute.
        provider.id = "muse:live-\(UUID().uuidString)"
        do {
            _ = try await provider.fetch(forceRefresh: true)
            XCTFail("An API-key host returned usage")
        } catch {
            XCTAssertEqual(error as? MuseServeError, .apiKeyOnlyExtraAccount)
        }
        // Reading must leave the login in the folder, not move it to the
        // shared Keychain item.
        let record = try String(contentsOf: MuseServeClient.authFile(configRoot: folder), encoding: .utf8)
        XCTAssertTrue(record.contains("api_key"))
        XCTAssertFalse(record.contains("keychain"))
    }

    func testAccountsUseTheirOwnConfigFolder() throws {
        let folder = try XCTUnwrap(ProviderAccountSupport.support(for: "muse")?.folder)
        XCTAssertEqual(
            folder.loginCommand("~/.muse-work"),
            "mkdir -p ~/.muse-work && XDG_CONFIG_HOME=~/.muse-work TBH_CREDENTIAL_BACKEND=file muse login"
        )
        XCTAssertEqual(folder.discoveryMarker, "muse/auth.json")

        let config = ProviderAccountConfig(baseProviderID: "muse", label: "Work", homePath: "/tmp/muse-work")
        let provider = try XCTUnwrap(config.makeProvider() as? MuseCodeProvider)
        XCTAssertEqual(provider.id, "muse:\(config.id.uuidString)")
        XCTAssertEqual(provider.displayName, "Muse Code — Work")
        XCTAssertEqual(provider.shortCode, "MuW")
        XCTAssertEqual(provider.configHome?.path, "/tmp/muse-work")
    }

    func testDetectionLooksForTheLoginRecord() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-detect-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var provider = MuseCodeProvider()
        provider.configHome = folder
        XCTAssertFalse(provider.isDetected)
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("muse"),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: folder.appendingPathComponent("muse/auth.json"))
        XCTAssertTrue(provider.isDetected)
    }

    private func object(_ json: String) throws -> [String: Any] {
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
