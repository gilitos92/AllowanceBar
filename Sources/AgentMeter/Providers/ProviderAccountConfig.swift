import Foundation

/// An extra account for a provider that already has a default account, e.g. a
/// second Claude Code login or a second DeepSeek key. Each one becomes its own
/// provider with id `<baseProviderID>:<uuid>`.
struct ProviderAccountConfig: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var baseProviderID: String
    var label: String
    /// Folder holding the other app's login for local-credential providers
    /// (e.g. a `CODEX_HOME` or `CLAUDE_CONFIG_DIR`). Nil for API-key providers,
    /// whose key lives in this app's Keychain under the account's provider id.
    var homePath: String?

    init(id: UUID = UUID(), baseProviderID: String, label: String, homePath: String? = nil) {
        self.id = id
        self.baseProviderID = baseProviderID
        self.label = label
        self.homePath = homePath
    }

    var providerID: String { "\(baseProviderID):\(id.uuidString)" }

    /// "codex:<uuid>" → "codex"; base ids are returned unchanged.
    nonisolated static func baseProviderID(of providerID: String) -> String {
        guard let separator = providerID.firstIndex(of: ":") else { return providerID }
        return String(providerID[..<separator])
    }

    nonisolated func displayName(base: String) -> String {
        "\(base) — \(label)"
    }

    /// Base short code plus the label's initial, e.g. "Cl" + "Work" → "ClW".
    nonisolated func shortCode(base: String) -> String {
        let initial = label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1).uppercased()
        return "\(base)\(initial)"
    }

    nonisolated func expandedHomeURL() -> URL? {
        homePath.map(ProviderAccountPath.expand)
    }

    /// Builds the provider for this account, or nil if the base provider does
    /// not support extra accounts.
    func makeProvider() -> (any UsageProvider)? {
        switch baseProviderID {
        case "codex":
            return CodexProvider(accountConfig: self)
        case "claude":
            guard let home = expandedHomeURL() else { return nil }
            var provider = configured(ClaudeProvider())
            provider.credentialsPath = home.appendingPathComponent(".credentials.json").path
            provider.keychainService = ClaudeProvider.keychainService(configDirectory: home)
            return provider
        case "gemini":
            guard let home = expandedHomeURL() else { return nil }
            var provider = configured(GeminiProvider())
            provider.credentialsPath = GeminiProvider.credentialsPath(cliHome: home)
            return provider
        case "cursor":
            guard let home = expandedHomeURL() else { return nil }
            var provider = configured(CursorProvider())
            provider.fetcher.stateDBPath = CursorUsageFetcher.stateDBPath(userDataDirectory: home)
            return provider
        case "claude-api":
            return configured(ClaudeAPIProvider(id: providerID))
        case "openrouter":
            return configured(OpenRouterProvider())
        case "deepseek":
            return configured(DeepSeekProvider())
        case "moonshot":
            return configured(MoonshotProvider())
        case "zai":
            return configured(ZaiProvider())
        case "venice":
            return configured(VeniceProvider())
        default:
            return nil
        }
    }

    /// Gives a base provider this account's identity. API-key providers need
    /// nothing else: their Keychain item is derived from `id`.
    private func configured<P: AccountConfigurableProvider>(_ base: P) -> P {
        var provider = base
        provider.id = providerID
        provider.displayName = displayName(base: base.displayName)
        provider.shortCode = shortCode(base: base.shortCode)
        return provider
    }
}

/// Providers whose identity can be replaced to represent an extra account.
protocol AccountConfigurableProvider: UsageProvider {
    var id: String { get set }
    var displayName: String { get set }
    var shortCode: String { get set }
}

/// How a provider's extra accounts are set up in Settings.
struct ProviderAccountSupport: Sendable {
    enum Credential: Sendable {
        /// Another app's login in its own folder, selected by an environment
        /// variable or flag when the user signs in.
        case folder(Folder)
        /// A key the user pastes (or connects) per account.
        case apiKey
    }

    struct Folder: Sendable {
        /// Where the default account lives, as shown to the user.
        let defaultPath: String
        /// Suggested folder for a new account: prefix + label slug.
        let suggestedPrefix: String
        /// File inside an account folder that marks a used login, relative to
        /// it. Folders in `~` named `suggestedPrefix` + anything that contain
        /// it are offered as one-click adds.
        let discoveryMarker: String
        /// Terminal command that signs in an account in a given folder.
        let loginCommand: @Sendable (String) -> String
        /// Name of the tool that owns the login, for the help text.
        let loginTool: String
    }

    let credential: Credential

    nonisolated static func support(for baseProviderID: String) -> ProviderAccountSupport? {
        switch baseProviderID {
        case "codex":
            return ProviderAccountSupport(credential: .folder(Folder(
                defaultPath: "~/.codex",
                suggestedPrefix: "~/.codex-",
                discoveryMarker: "auth.json",
                loginCommand: { path in
                    // Codex refuses a CODEX_HOME that does not exist yet.
                    let quoted = ProviderAccountPath.shellQuoted(path)
                    return "mkdir -p \(quoted) && CODEX_HOME=\(quoted) codex login"
                },
                loginTool: "Codex CLI"
            )))
        case "claude":
            return ProviderAccountSupport(credential: .folder(Folder(
                defaultPath: "~/.claude",
                suggestedPrefix: "~/.claude-",
                discoveryMarker: ".claude.json",
                loginCommand: { path in
                    let quoted = ProviderAccountPath.shellQuoted(path)
                    return "mkdir -p \(quoted) && CLAUDE_CONFIG_DIR=\(quoted) claude auth login"
                },
                loginTool: "Claude Code"
            )))
        case "gemini":
            return ProviderAccountSupport(credential: .folder(Folder(
                defaultPath: "~/.gemini",
                suggestedPrefix: "~/.gemini-",
                discoveryMarker: ".gemini/oauth_creds.json",
                loginCommand: { path in
                    let quoted = ProviderAccountPath.shellQuoted(path)
                    return "mkdir -p \(quoted) && GEMINI_CLI_HOME=\(quoted) gemini"
                },
                loginTool: "Gemini CLI"
            )))
        case "cursor":
            return ProviderAccountSupport(credential: .folder(Folder(
                defaultPath: "~/Library/Application Support/Cursor",
                suggestedPrefix: "~/.cursor-",
                discoveryMarker: "User/globalStorage/state.vscdb",
                loginCommand: { path in
                    "open -na Cursor --args --user-data-dir=\(ProviderAccountPath.shellQuoted(path))"
                },
                loginTool: "Cursor"
            )))
        case "claude-api", "openrouter", "deepseek", "moonshot", "zai", "venice":
            return ProviderAccountSupport(credential: .apiKey)
        default:
            return nil
        }
    }

    var folder: Folder? {
        if case .folder(let folder) = credential { return folder }
        return nil
    }

    /// Suggests e.g. `~/.claude-work-account` from a human label.
    nonisolated static func suggestedHomePath(prefix: String, label: String) -> String {
        let slug = label
            .lowercased()
            .map { character -> Character in
                if character.isLetter || character.isNumber { return character }
                return "-"
            }
            .reduce(into: "") { result, character in
                if character == "-", result.last == "-" { return }
                result.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return prefix + (slug.isEmpty ? "account" : slug)
    }
}

/// Finds account folders in `~` that already contain a login but are not
/// configured in Allowance Bar yet, so Settings can offer one-click adds.
enum ProviderAccountDiscovery {
    struct Candidate: Equatable, Identifiable {
        var id: String { homePath }
        let homePath: String      // tilde-abbreviated, e.g. "~/.codex-me-com"
        let suggestedLabel: String
    }

    nonisolated static func discover(
        folder: ProviderAccountSupport.Folder,
        configured: [ProviderAccountConfig],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [Candidate] {
        guard folder.suggestedPrefix.hasPrefix("~/"),
              let entries = try? fileManager.contentsOfDirectory(
                  at: homeDirectory,
                  includingPropertiesForKeys: nil,
                  options: [.skipsSubdirectoryDescendants]
              ) else { return [] }
        let configuredPaths = Set(configured.compactMap { $0.expandedHomeURL()?.standardizedFileURL.path })
        return candidates(
            from: entries.map(\.lastPathComponent),
            namePrefix: String(folder.suggestedPrefix.dropFirst(2)),
            homeDirectory: homeDirectory,
            configuredPaths: configuredPaths,
            hasLogin: { fileManager.fileExists(atPath: $0.appendingPathComponent(folder.discoveryMarker).path) }
        )
    }

    nonisolated static func candidates(
        from names: [String],
        namePrefix: String,
        homeDirectory: URL,
        configuredPaths: Set<String>,
        hasLogin: (URL) -> Bool
    ) -> [Candidate] {
        names
            .filter { $0.hasPrefix(namePrefix) && $0.count > namePrefix.count }
            .sorted()
            .compactMap { name in
                let url = homeDirectory.appendingPathComponent(name, isDirectory: true)
                guard !configuredPaths.contains(url.standardizedFileURL.path), hasLogin(url) else {
                    return nil
                }
                return Candidate(
                    homePath: "~/\(name)",
                    suggestedLabel: String(name.dropFirst(namePrefix.count))
                )
            }
    }
}

enum ProviderAccountPath {
    nonisolated static func expand(_ path: String) -> URL {
        let expanded: String
        if path.hasPrefix("~/") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            expanded = home + path.dropFirst()
        } else if path == "~" {
            expanded = FileManager.default.homeDirectoryForCurrentUser.path
        } else {
            expanded = path
        }
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    /// Quotes a path for zsh. A leading `~/` stays outside the quotes so the
    /// shell still expands it.
    nonisolated static func shellQuoted(_ path: String) -> String {
        func needsQuotes(_ value: String) -> Bool {
            value.contains { character in
                !(character.isLetter || character.isNumber || "/._-~+@%".contains(character))
            }
        }
        func quote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        if path.hasPrefix("~/") {
            let rest = String(path.dropFirst(2))
            return needsQuotes(rest) ? "~/" + quote(rest) : path
        }
        return needsQuotes(path) ? quote(path) : path
    }
}
