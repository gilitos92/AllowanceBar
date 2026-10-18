import XCTest
@testable import AgentMeter

final class ProviderAccountTests: XCTestCase {
    func testSuggestedHomePathSlug() {
        XCTAssertEqual(
            ProviderAccountSupport.suggestedHomePath(prefix: "~/.codex-", label: "Work Account"),
            "~/.codex-work-account"
        )
        XCTAssertEqual(
            ProviderAccountSupport.suggestedHomePath(prefix: "~/.claude-", label: "  "),
            "~/.claude-account"
        )
    }

    func testLoginCommandsCreateFolderFirst() throws {
        let codex = try XCTUnwrap(ProviderAccountSupport.support(for: "codex")?.folder)
        XCTAssertEqual(
            codex.loginCommand("~/.codex-main"),
            "mkdir -p ~/.codex-main && CODEX_HOME=~/.codex-main codex login"
        )
        XCTAssertEqual(
            codex.loginCommand("/Volumes/My Disk/codex home"),
            "mkdir -p '/Volumes/My Disk/codex home' && CODEX_HOME='/Volumes/My Disk/codex home' codex login"
        )
        let claude = try XCTUnwrap(ProviderAccountSupport.support(for: "claude")?.folder)
        XCTAssertEqual(
            claude.loginCommand("~/.claude-work"),
            "mkdir -p ~/.claude-work && CLAUDE_CONFIG_DIR=~/.claude-work claude auth login"
        )
        let gemini = try XCTUnwrap(ProviderAccountSupport.support(for: "gemini")?.folder)
        XCTAssertEqual(
            gemini.loginCommand("~/.gemini-work"),
            "mkdir -p ~/.gemini-work && GEMINI_CLI_HOME=~/.gemini-work gemini"
        )
        let cursor = try XCTUnwrap(ProviderAccountSupport.support(for: "cursor")?.folder)
        XCTAssertEqual(
            cursor.loginCommand("~/.cursor-work"),
            "open -na Cursor --args --user-data-dir=~/.cursor-work"
        )
    }

    func testShellQuotingKeepsTildeExpandable() {
        XCTAssertEqual(ProviderAccountPath.shellQuoted("~/My Folder"), "~/'My Folder'")
        XCTAssertEqual(ProviderAccountPath.shellQuoted("/tmp/it's"), "'/tmp/it'\\''s'")
    }

    func testEveryBaseProviderSupportsAccounts() {
        for provider in UsageStore.defaultProviders {
            XCTAssertNotNil(ProviderAccountSupport.support(for: provider.id), provider.id)
        }
    }

    func testConfigCodableRoundTrip() throws {
        let original = ProviderAccountConfig(
            id: UUID(uuidString: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")!,
            baseProviderID: "claude",
            label: "Work",
            homePath: "~/.claude-work"
        )
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(ProviderAccountConfig.self, from: data), original)
    }

    func testBaseProviderID() {
        XCTAssertEqual(ProviderAccountConfig.baseProviderID(of: "claude"), "claude")
        XCTAssertEqual(ProviderAccountConfig.baseProviderID(of: "deepseek:1234"), "deepseek")
    }

    func testClaudeAccountUsesItsFolder() throws {
        let account = ProviderAccountConfig(baseProviderID: "claude", label: "Work", homePath: "/tmp/claude-work")
        let provider = try XCTUnwrap(account.makeProvider() as? ClaudeProvider)
        XCTAssertEqual(provider.id, account.providerID)
        XCTAssertEqual(provider.displayName, "Claude — Work")
        XCTAssertEqual(provider.shortCode, "ClW")
        XCTAssertEqual(provider.credentialsPath, "/tmp/claude-work/.credentials.json")
        // `printf %s /tmp/claude-work | shasum -a 256 | cut -c1-8`
        XCTAssertEqual(provider.keychainService, "Claude Code-credentials-bfc1769a")
    }

    func testFolderAccountsPointAtTheirCredentials() throws {
        let gemini = ProviderAccountConfig(baseProviderID: "gemini", label: "Alt", homePath: "/tmp/gemini-alt")
        let geminiProvider = try XCTUnwrap(gemini.makeProvider() as? GeminiProvider)
        XCTAssertEqual(geminiProvider.credentialsPath, "/tmp/gemini-alt/.gemini/oauth_creds.json")

        let cursor = ProviderAccountConfig(baseProviderID: "cursor", label: "Alt", homePath: "/tmp/cursor-alt")
        let cursorProvider = try XCTUnwrap(cursor.makeProvider() as? CursorProvider)
        XCTAssertEqual(cursorProvider.fetcher.stateDBPath, "/tmp/cursor-alt/User/globalStorage/state.vscdb")
    }

    func testAPIKeyAccountsGetTheirOwnKeychainItem() throws {
        for base in ["claude-api", "openrouter", "deepseek", "moonshot", "zai", "venice"] {
            let account = ProviderAccountConfig(baseProviderID: base, label: "Team")
            let provider = try XCTUnwrap(account.makeProvider(), base)
            XCTAssertEqual(provider.id, account.providerID)
            XCTAssertEqual(provider.keychainAccount, "apikey.\(account.providerID)")
            XCTAssertTrue(provider.displayName.hasSuffix(" — Team"), provider.displayName)
        }
    }

    func testDefaultProvidersPlaceExtrasAfterTheirBase() throws {
        let codex = ProviderAccountConfig(baseProviderID: "codex", label: "Alt", homePath: "~/.codex-alt")
        let claude = ProviderAccountConfig(baseProviderID: "claude", label: "Work", homePath: "~/.claude-work")
        let deepseek = ProviderAccountConfig(baseProviderID: "deepseek", label: "Team")
        let unknown = ProviderAccountConfig(baseProviderID: "nope", label: "X")
        let ids = UsageStore.defaultProviders(extraAccounts: [deepseek, claude, codex, unknown]).map(\.id)
        XCTAssertEqual(ids.count, 13)
        XCTAssertEqual(Array(ids.prefix(5)), ["codex", codex.providerID, "cursor", "claude", claude.providerID])
        let deepseekIndex = try XCTUnwrap(ids.firstIndex(of: "deepseek"))
        XCTAssertEqual(ids[deepseekIndex + 1], deepseek.providerID)
    }

    // MARK: - Settings

    @MainActor
    func testSettingsPersistAccounts() {
        let suite = "ProviderAccountTests-persist-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let account = ProviderAccountConfig(baseProviderID: "gemini", label: "Alt", homePath: "~/.gemini-alt")
        settings.addAccount(account)

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.extraAccounts, [account])
        XCTAssertEqual(reloaded.accounts(for: "gemini"), [account])
        XCTAssertEqual(reloaded.accounts(for: "codex"), [])
    }

    @MainActor
    func testRenameKeepsIDAndIgnoresBlankLabels() {
        let suite = "ProviderAccountTests-rename-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let account = ProviderAccountConfig(baseProviderID: "claude", label: "secondary", homePath: "~/.claude-secondary")
        settings.addAccount(account)

        settings.renameAccount(id: account.id, to: "  Work  ")
        XCTAssertEqual(settings.extraAccounts.first?.label, "Work")
        XCTAssertEqual(settings.extraAccounts.first?.providerID, account.providerID)
        XCTAssertEqual(settings.extraAccounts.first?.makeProvider()?.displayName, "Claude — Work")

        settings.renameAccount(id: account.id, to: "   ")
        XCTAssertEqual(SettingsStore(defaults: defaults).extraAccounts.first?.label, "Work")
    }

    @MainActor
    func testMigratesLegacyCodexAccounts() throws {
        let suite = "ProviderAccountTests-migrate-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        let legacy = #"[{"id":"\#(id.uuidString)","label":"Alt","codexHomePath":"~/.codex-alt"}]"#
        defaults.set(Data(legacy.utf8), forKey: "codexExtraAccounts")

        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.extraAccounts, [
            ProviderAccountConfig(id: id, baseProviderID: "codex", label: "Alt", homePath: "~/.codex-alt"),
        ])
        XCTAssertEqual(settings.extraAccounts.first?.providerID, "codex:\(id.uuidString)")
    }

    @MainActor
    func testKeepsLegacyCodexListForDowngrades() throws {
        let suite = "ProviderAccountTests-legacy-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.addAccount(ProviderAccountConfig(baseProviderID: "codex", label: "Alt", homePath: "~/.codex-alt"))
        settings.addAccount(ProviderAccountConfig(baseProviderID: "deepseek", label: "Team"))

        let data = try XCTUnwrap(defaults.data(forKey: "codexExtraAccounts"))
        let legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(legacy.count, 1)
        XCTAssertEqual(legacy.first?["codexHomePath"] as? String, "~/.codex-alt")
    }

    @MainActor
    func testStoreRebuildsProvidersWhenAccountsChange() {
        let suite = "ProviderAccountTests-rebuild-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let store = UsageStore(settings: settings, providers: UsageStore.defaultProviders)
        let account = ProviderAccountConfig(baseProviderID: "zai", label: "Team")

        settings.addAccount(account)
        XCTAssertTrue(store.providers.contains { $0.id == account.providerID })

        settings.removeAccount(id: account.id)
        XCTAssertFalse(store.providers.contains { $0.id == account.providerID })
    }

    // MARK: - Discovery

    func testDiscoversUnconfiguredFoldersWithLogins() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let configured: Set<String> = [home.appendingPathComponent(".codex-default", isDirectory: true).standardizedFileURL.path]
        let withLogin: Set<String> = [".codex-default", ".codex-me-com"]
        let found = ProviderAccountDiscovery.candidates(
            from: [".codex", ".codex-old-gmail", ".codex-me-com", ".codex-default", ".codex-", "Documents"],
            namePrefix: ".codex-",
            homeDirectory: home,
            configuredPaths: configured,
            hasLogin: { withLogin.contains($0.lastPathComponent) }
        )
        XCTAssertEqual(found.map(\.homePath), ["~/.codex-me-com"])
        XCTAssertEqual(found.first?.suggestedLabel, "me-com")
    }

    func testDiscoversClaudeConfigFolders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderAccountTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let secondary = root.appendingPathComponent(".claude-secondary", isDirectory: true)
        try FileManager.default.createDirectory(at: secondary, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: secondary.appendingPathComponent(".claude.json"))
        // A backup file next to the folders must not be offered.
        try Data("{}".utf8).write(to: root.appendingPathComponent(".claude.json.backup"))

        let folder = try XCTUnwrap(ProviderAccountSupport.support(for: "claude")?.folder)
        let found = ProviderAccountDiscovery.discover(folder: folder, configured: [], homeDirectory: root)
        XCTAssertEqual(found, [.init(homePath: "~/.claude-secondary", suggestedLabel: "secondary")])
    }
}
