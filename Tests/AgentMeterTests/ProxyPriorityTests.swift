import XCTest
import AgentMeterStatusKit
@testable import AgentMeter

final class ProxyPriorityTests: XCTestCase {
    private func login(
        _ email: String,
        _ priority: Int,
        kind: CLIProxyLoginKind = .claude,
        disabled: Bool = false
    ) -> CLIProxyClient.Account {
        CLIProxyClient.Account(kind: kind, authIndex: email, email: email, disabled: disabled, priority: priority)
    }

    func testLoginListReadsPriorityAsNumberOrText() throws {
        let data = Data(#"""
        {"files":[
          {"auth_index":"a","provider":"claude","email":"a@example.com","priority":3},
          {"auth_index":"b","provider":"claude","email":"b@example.com","priority":"2"},
          {"auth_index":"c","provider":"claude","email":"c@example.com"},
          {"auth_index":"d","provider":"claude","email":"d@example.com","priority":"high"}
        ]}
        """#.utf8)

        let logins = try CLIProxyClient.parseLogins(data)

        XCTAssertEqual(logins.map(\.priority), [3, 2, 0, 0], "A missing or unreadable priority counts as 0, like the proxy")
    }

    func testHighestPriorityComesFirstAndTiesShareAPlace() {
        let accounts = [
            login("low@example.com", 1),
            login("top@example.com", 3),
            login("tie@example.com", 3),
            login("off@example.com", 9, disabled: true),
            login("low@example.com", 5, kind: .codex),
        ]
        func place(_ email: String) -> ProxyPriority? {
            ProxyPriority.of(CLIProxyLoginKey(kind: .claude, email: email), in: accounts)
        }

        XCTAssertEqual(place("TOP@example.com"), ProxyPriority(priority: 3, place: 1, loginCount: 3))
        XCTAssertEqual(place("tie@example.com")?.place, 1)
        XCTAssertEqual(place("low@example.com"), ProxyPriority(priority: 1, place: 3, loginCount: 3))
        XCTAssertNil(place("off@example.com"), "Turned-off logins get no place")
        XCTAssertNil(
            ProxyPriority.of(CLIProxyLoginKey(kind: .codex, email: "low@example.com"), in: accounts),
            "A provider's only login has no order"
        )
    }

    func testNoPlaceWhenEveryLoginSharesOnePriority() {
        let accounts = [login("a@example.com", 0), login("b@example.com", 0)]

        XCTAssertNil(ProxyPriority.of(CLIProxyLoginKey(kind: .claude, email: "a@example.com"), in: accounts))
    }

    func testLabels() {
        let priority = ProxyPriority(priority: 3, place: 1, loginCount: 3)

        XCTAssertEqual(priority.shortLabel, "#1")
        XCTAssertEqual(priority.label, "Proxy #1")
        XCTAssertTrue(priority.phrase.contains("1"))
        XCTAssertTrue(priority.explanation.contains("CLIProxyAPI"))
    }

    // MARK: - Store and views

    @MainActor
    private func makeStore(
        settings: SettingsStore,
        providers: [any UsageProvider]
    ) async throws -> UsageStore {
        let store = UsageStore(settings: settings, providers: providers)
        store.proxyAccounts = [
            login("second@example.com", 3),
            login("main@example.com", 2),
            login("third@example.com", 1),
        ]
        let deadline = Date().addingTimeInterval(3)
        while providers.contains(where: { store.state(for: $0.id).usage == nil }) {
            guard Date() < deadline else { throw XCTSkip("The accounts never loaded") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        return store
    }

    @MainActor
    private func makeSettings() -> (SettingsStore, UserDefaults, String) {
        let suite = "ProxyPriorityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (SettingsStore(defaults: defaults), defaults, suite)
    }

    @MainActor
    func testLocalAccountShowsThePlaceOfItsProxyLogin() async throws {
        let (settings, defaults, suite) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let local = ClaudeAccountStub(id: "claude", email: "Main@example.com")
        var proxy = CLIProxyAccountProvider(login: CLIProxyLoginKey(kind: .claude, email: "third@example.com"))
        proxy.proxyConfig = { nil }
        let unmatched = ClaudeAccountStub(id: "claude:\(UUID().uuidString)", email: "other@example.com")

        let store = try await makeStore(settings: settings, providers: [local, unmatched])

        XCTAssertEqual(store.proxyPriority(for: local), ProxyPriority(priority: 2, place: 2, loginCount: 3))
        XCTAssertEqual(store.proxyPriority(for: proxy)?.place, 3)
        XCTAssertNil(store.proxyPriority(for: unmatched), "No proxy login has this email")
        store.proxyAccounts = []
        XCTAssertNil(store.proxyPriority(for: local), "Without a proxy there is no order")
    }

    @MainActor
    func testNanoTextShowsThePlaceUntilTurnedOff() async throws {
        let (settings, defaults, suite) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let local = ClaudeAccountStub(id: "claude", email: "second@example.com")

        let store = try await makeStore(settings: settings, providers: [local])

        XCTAssertTrue(settings.nanoShowsProxyPriority, "On by default")
        XCTAssertEqual(store.nanoEntries.map(\.text), ["Cl 30% #1"])
        XCTAssertTrue(store.nanoAccessibilityDescription.contains(ProxyPriority(priority: 3, place: 1, loginCount: 3).phrase))
        XCTAssertEqual(store.menuBarEntries.map(\.text), ["Cl 30%"], "The menu bar title stays short")

        settings.nanoShowsProxyPriority = false
        XCTAssertEqual(store.nanoEntries.map(\.text), ["Cl 30%"])
        XCTAssertFalse(store.nanoAccessibilityDescription.contains("CLIProxyAPI"))
        XCTAssertFalse(SettingsStore(defaults: defaults).nanoShowsProxyPriority, "The choice persists")
    }

    @MainActor
    func testCompactPanelFollowsTheGeneralSetting() async throws {
        let (settings, defaults, suite) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let local = ClaudeAccountStub(id: "claude", email: "second@example.com")

        let store = try await makeStore(settings: settings, providers: [local])

        XCTAssertTrue(settings.showsProxyPriority, "On by default")
        XCTAssertEqual(store.compactEntries.first?.priority?.place, 1)
        settings.showsProxyPriority = false
        XCTAssertNil(store.compactEntries.first?.priority)
        XCTAssertFalse(SettingsStore(defaults: defaults).showsProxyPriority, "The choice persists")
    }

    // MARK: - Snapshot

    func testSnapshotCarriesThePlace() throws {
        let status = StatusSnapshotWriter.mapProvider(.init(
            id: "claude",
            displayName: "Claude",
            state: .loading,
            proxyPriority: ProxyPriority(priority: 3, place: 1, loginCount: 3)
        ))

        XCTAssertEqual(status.proxyPriority, ProxyPriorityStatus(priority: 3, place: 1, loginCount: 3))

        let snapshot = StatusSnapshot(generatedAt: Date(timeIntervalSince1970: 1_800_000_000), appVersion: "2.8.0", providers: [status])
        let json = try XCTUnwrap(String(data: StatusJSON.encode(snapshot), encoding: .utf8))
        XCTAssertTrue(json.contains(#""proxyPriority""#))
        XCTAssertEqual(try StatusJSON.decode(StatusJSON.encode(snapshot)), snapshot)
        XCTAssertTrue(StatusTable.renderStatusTable(snapshot, now: snapshot.generatedAt)
            .contains("  proxy order: 1 of 3 (priority 3)"))
        XCTAssertNil(StatusSnapshotWriter.mapProvider(.init(id: "cursor", displayName: "Cursor", state: .loading)).proxyPriority)
    }
}

/// A Claude account on this Mac with one 5-hour window at 30%.
private struct ClaudeAccountStub: UsageProvider {
    let id: String
    let email: String
    var displayName: String { "Claude" }
    var shortCode: String { "Cl" }
    var isDetected: Bool { true }

    func fetch() async throws -> ProviderUsage {
        ProviderUsage(
            planName: "Pro",
            windows: [UsageWindow(label: "5h", usedPercent: 30, resetsAt: nil)],
            asOf: Date(),
            accountEmail: email
        )
    }
}
