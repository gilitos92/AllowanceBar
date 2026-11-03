import Foundation

/// Codex/ChatGPT usage via the Codex CLI app-server protocol, with session-log
/// fallback for the primary account.
struct CodexProvider: UsageProvider {
    let accountConfig: ProviderAccountConfig?
    let id: String
    let displayName: String
    let shortCode: String
    let codexHome: URL

    init(accountConfig: ProviderAccountConfig? = nil) {
        self.accountConfig = accountConfig
        if let config = accountConfig {
            self.id = config.providerID
            self.displayName = config.displayName(base: "Codex")
            self.shortCode = config.shortCode(base: "Cx")
            self.codexHome = config.expandedHomeURL() ?? CodexPath.defaultHome
        } else {
            self.id = "codex"
            self.displayName = "Codex"
            self.shortCode = "Cx"
            self.codexHome = CodexPath.defaultHome
        }
    }

    var isPrimary: Bool { accountConfig == nil }

    @MainActor var accountEmail: String? {
        CodexAccountCache.shared.lastEmail(for: id)
    }

    var isDetected: Bool {
        let fm = FileManager.default
        if isPrimary {
            let sessionsRoot = codexHome.appendingPathComponent("sessions")
            let authFile = codexHome.appendingPathComponent("auth.json")
            return fm.fileExists(atPath: sessionsRoot.path)
                || fm.fileExists(atPath: authFile.path)
        }
        let authFile = codexHome.appendingPathComponent("auth.json")
        return fm.fileExists(atPath: authFile.path)
    }

    var dashboardURL: URL? {
        URL(string: "https://chatgpt.com/codex/settings/usage")
    }

    func fetch() async throws -> ProviderUsage {
        let now = Date()
        let providerID = id
        let primary = isPrimary
        let home = codexHome
        let sessionsRoot = home.appendingPathComponent("sessions")
        let logReader = CodexUsageReader(sessionsRoot: sessionsRoot)

        let cached = await MainActor.run {
            CodexAccountCache.shared.cachedReading(
                for: providerID,
                maxAge: CodexAppServerClient.pollInterval
            )
        }
        if let cached {
            let email = cached.reading.email
            if primary, var logUsage = try? logReader.readUsage(),
               let logAsOf = logUsage.asOf,
               logAsOf > cached.timestamp {
                logUsage.accountEmail = email
                return logUsage
            }
            var usage = CodexAppServerClient.usage(from: cached.reading, now: now)
            usage.accountEmail = email
            return usage
        }

        do {
            let reading = try await CodexAppServerClient.readAccount(codexHome: home)
            DebugLog.write("codex app-server \(providerID): ok (email present: \(reading.email != nil), limits: \(reading.rateLimits != nil))")
            await MainActor.run {
                CodexAccountCache.shared.store(reading, for: providerID, at: now)
            }
            var usage = CodexAppServerClient.usage(from: reading, now: now)
            usage.accountEmail = reading.email

            if primary, var logUsage = try? logReader.readUsage(),
               let logAsOf = logUsage.asOf,
               logAsOf > now {
                logUsage.accountEmail = reading.email
                return logUsage
            }
            return usage
        } catch {
            DebugLog.write("codex app-server \(providerID): failed: \(error)")
            if primary {
                var usage = try logReader.readUsage()
                usage.accountEmail = await MainActor.run { CodexAccountCache.shared.lastEmail(for: providerID) }
                return usage
            }
            if case CodexAppServerError.notSignedIn = error {
                throw CodexAppServerError.notSignedIn
            }
            throw error
        }
    }
}
