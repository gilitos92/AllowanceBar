import XCTest
@testable import AgentMeter

final class ProviderGroupTests: XCTestCase {
    private struct Stub: UsageProvider {
        let id: String
        var displayName: String
        var shortCode: String = "St"
        var isDetected: Bool { true }
        var credentialHelpText: String? { nil }
        var apiKeyPlaceholder: String { "" }
        var dashboardURL: URL? { nil }
        func fetch() async throws -> ProviderUsage { throw URLError(.badURL) }
    }

    private func usage(plan: String?, email: String? = nil) -> ProviderUsage {
        var usage = ProviderUsage(planName: plan, windows: [], asOf: nil)
        usage.accountEmail = email
        return usage
    }

    func testGroupsByBaseProviderInFirstSeenOrder() {
        let providers: [any UsageProvider] = [
            Stub(id: "codex", displayName: "Codex"),
            Stub(id: "claude", displayName: "Claude"),
            Stub(id: "claude:A", displayName: "Claude — Work"),
            Stub(id: "gemini", displayName: "Gemini"),
            Stub(id: "claude:proxy-1", displayName: "Claude — a@example.com"),
            Stub(id: "claude-api", displayName: "Claude API"),
        ]
        let groups = ProviderGroup.groups(providers)
        XCTAssertEqual(groups.map(\.baseID), ["codex", "claude", "gemini", "claude-api"])
        XCTAssertEqual(groups[1].members.map(\.id), ["claude", "claude:A", "claude:proxy-1"])
        XCTAssertEqual(groups[0].members.count, 1)
    }

    func testAccountLabels() {
        let base = Stub(id: "claude", displayName: "Claude", shortCode: "Cl")
        let extra = Stub(id: "claude:A", displayName: "Claude — Work", shortCode: "ClW")
        let proxy = Stub(id: "claude:proxy-1", displayName: "Claude — a@example.com", shortCode: "ClA")
        let group = ProviderGroup.groups([base, extra, proxy])[0]

        XCTAssertEqual(group.baseName, "Claude")
        XCTAssertEqual(group.baseShortCode, "Cl")

        let labels = group.accountLabels(emails: [
            "claude": "me@example.com",
            "claude:A": "w@example.com",
            "claude:proxy-1": "A@example.com",
        ])
        XCTAssertEqual(labels["claude"], .init(name: "me@example.com", detail: nil))
        // The email is extra detail for a labeled account, not for one
        // already named by its email.
        XCTAssertEqual(labels["claude:A"], .init(name: "Work", detail: "w@example.com"))
        XCTAssertEqual(labels["claude:proxy-1"], .init(name: "a@example.com", detail: nil))

        let unknown = group.accountLabels(emails: [:])
        XCTAssertEqual(unknown["claude"], .init(name: L("Default account"), detail: nil))
        XCTAssertEqual(unknown["claude:A"], .init(name: "Work", detail: nil))
    }

    func testSameLoginOnThisMacAndProxyIsTold() {
        let base = Stub(id: "claude", displayName: "Claude", shortCode: "Cl")
        let proxy = CLIProxyAccountProvider(login: CLIProxyLoginKey(kind: .claude, email: "me@example.com"))
        let group = ProviderGroup.groups([base, proxy])[0]
        let labels = group.accountLabels(emails: ["claude": "Me@example.com", proxy.id: "me@example.com"])
        XCTAssertEqual(labels["claude"], .init(name: "Me@example.com", detail: L("This Mac")))
        XCTAssertEqual(labels[proxy.id], .init(name: "me@example.com", detail: "CLIProxyAPI"))
    }

    func testSameLabelsWithDifferentEmailsKeepTheirEmails() {
        let group = ProviderGroup.groups([
            Stub(id: "claude:A", displayName: "Claude — Work"),
            Stub(id: "claude:B", displayName: "Claude — Work"),
        ])[0]
        let labels = group.accountLabels(emails: ["claude:A": "a@example.com", "claude:B": "b@example.com"])
        XCTAssertEqual(labels["claude:A"], .init(name: "Work", detail: "a@example.com"))
        XCTAssertEqual(labels["claude:B"], .init(name: "Work", detail: "b@example.com"))
    }

    func testGeminiProxyLoginsOfOneEmailShowTheirProject() {
        let first = CLIProxyAccountProvider(login: CLIProxyLoginKey(kind: .gemini, email: "g@example.com", projectID: "alpha"))
        let second = CLIProxyAccountProvider(login: CLIProxyLoginKey(kind: .gemini, email: "g@example.com", projectID: "beta"))
        let group = ProviderGroup.groups([first, second])[0]
        let labels = group.accountLabels(emails: [:])
        XCTAssertEqual(labels[first.id], .init(name: "g@example.com", detail: "CLIProxyAPI · alpha"))
        XCTAssertEqual(labels[second.id], .init(name: "g@example.com", detail: "CLIProxyAPI · beta"))
    }

    func testHiddenDefaultAccountStillNamesTheGroup() {
        let claudeOnlyExtras = ProviderGroup.groups([
            Stub(id: "claude:A", displayName: "Claude — Work", shortCode: "ClW"),
            Stub(id: "claude:B", displayName: "Claude — Home", shortCode: "ClH"),
        ])[0]
        XCTAssertEqual(claudeOnlyExtras.baseName, "Claude")
        XCTAssertEqual(claudeOnlyExtras.baseShortCode, "Cl")
        XCTAssertEqual(claudeOnlyExtras.accountLabels(emails: [:])["claude:B"]?.name, "Home")

        let antigravity = ProviderGroup.groups([
            Stub(id: "antigravity:proxy-1", displayName: "Antigravity — a@example.com"),
            Stub(id: "antigravity:proxy-2", displayName: "Antigravity — b@example.com"),
        ])[0]
        XCTAssertEqual(antigravity.baseName, "Antigravity")
        XCTAssertEqual(antigravity.baseShortCode, "Ag")
    }

    func testSharedPlan() {
        XCTAssertEqual(ProviderGroup.sharedPlan(of: [usage(plan: "Pro"), usage(plan: "Pro"), nil]), "Pro")
        XCTAssertNil(ProviderGroup.sharedPlan(of: [usage(plan: "Pro"), usage(plan: "Max")]))
        XCTAssertNil(ProviderGroup.sharedPlan(of: [usage(plan: "Pro"), usage(plan: nil)]))
        XCTAssertNil(ProviderGroup.sharedPlan(of: [nil, nil]))
    }
}
