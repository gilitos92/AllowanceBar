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

    func testAccountNames() {
        let base = Stub(id: "claude", displayName: "Claude", shortCode: "Cl")
        let extra = Stub(id: "claude:A", displayName: "Claude — Work", shortCode: "ClW")
        let proxy = Stub(id: "claude:proxy-1", displayName: "Claude — a@example.com", shortCode: "ClA")
        let group = ProviderGroup.groups([base, extra, proxy])[0]

        XCTAssertEqual(group.baseName, "Claude")
        XCTAssertEqual(group.baseShortCode, "Cl")
        XCTAssertEqual(group.accountName(of: base, usage: usage(plan: "Pro", email: "me@example.com")), "me@example.com")
        XCTAssertEqual(group.accountName(of: base, usage: nil), L("Default account"))
        XCTAssertEqual(group.accountName(of: extra, usage: nil), "Work")
        XCTAssertEqual(group.accountName(of: proxy, usage: nil), "a@example.com")

        // The email is extra detail for a labeled account, not for one
        // already named by its email.
        XCTAssertEqual(group.accountDetail(of: extra, usage: usage(plan: nil, email: "w@example.com")), "w@example.com")
        XCTAssertNil(group.accountDetail(of: proxy, usage: usage(plan: nil, email: "A@example.com")))
        XCTAssertNil(group.accountDetail(of: base, usage: usage(plan: nil, email: "me@example.com")))
    }

    func testHiddenDefaultAccountStillNamesTheGroup() {
        let claudeOnlyExtras = ProviderGroup.groups([
            Stub(id: "claude:A", displayName: "Claude — Work", shortCode: "ClW"),
            Stub(id: "claude:B", displayName: "Claude — Home", shortCode: "ClH"),
        ])[0]
        XCTAssertEqual(claudeOnlyExtras.baseName, "Claude")
        XCTAssertEqual(claudeOnlyExtras.baseShortCode, "Cl")
        XCTAssertEqual(claudeOnlyExtras.accountName(of: claudeOnlyExtras.members[1], usage: nil), "Home")

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
