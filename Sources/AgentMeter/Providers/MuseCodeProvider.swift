import Foundation

/// Meta's Muse Code subscription limits (5-hour and weekly windows), read
/// through the user's own Muse Code CLI. See `MuseServeClient`.
struct MuseCodeProvider: AccountConfigurableProvider {
    var id = "muse"
    var displayName = "Muse Code"
    var shortCode = "Mu"
    /// Extra accounts: the folder used as `XDG_CONFIG_HOME` when the account
    /// signed in. Nil for the default login in `~/.config/muse`.
    var configHome: URL?

    var isDetected: Bool {
        let root = configHome ?? MuseServeClient.defaultConfigRoot
        return FileManager.default.fileExists(atPath: MuseServeClient.authFile(configRoot: root).path)
    }

    var dashboardURL: URL? {
        URL(string: "https://dev.meta.ai/")
    }

    func fetch() async throws -> ProviderUsage {
        try await fetch(forceRefresh: false)
    }

    func fetch(forceRefresh: Bool) async throws -> ProviderUsage {
        let now = Date()
        let providerID = id
        let cached = await MainActor.run { MuseUsageCache.shared.entry(for: providerID) }
        if let cached {
            let age = now.timeIntervalSince(cached.timestamp)
            if age < MuseServeClient.minimumInterval
                || (!forceRefresh && age < MuseServeClient.pollInterval) {
                return MuseServeClient.usage(from: cached.reading, now: now)
            }
        }

        do {
            let reading = try await MuseServeClient.readUsage(configHome: configHome)
            DebugLog.write("muse serve \(providerID): ok (window: \(reading.window != nil), weekly: \(reading.weekly != nil))")
            await MainActor.run { MuseUsageCache.shared.store(reading, for: providerID, at: now) }
            return MuseServeClient.usage(from: reading, now: now)
        } catch MuseServeError.rateLimited(let retryAfter) {
            DebugLog.write("muse serve \(providerID): rate limited (retry after: \(retryAfter.map { String(Int($0)) } ?? "unknown") s)")
            if let cached {
                return MuseServeClient.usage(from: cached.reading, now: now)
            }
            throw MuseServeError.rateLimited(retryAfter: retryAfter)
        } catch MuseServeError.notSignedIn where configHome != nil {
            throw MuseServeError.notSignedInExtraAccount
        } catch {
            DebugLog.write("muse serve \(providerID): failed: \(error)")
            throw error
        }
    }
}

/// The last answer per Muse Code account, kept in memory only.
@MainActor
final class MuseUsageCache {
    static let shared = MuseUsageCache()

    struct Entry {
        let reading: MuseUsageReading
        let timestamp: Date
    }

    private var entries: [String: Entry] = [:]

    func entry(for providerID: String) -> Entry? {
        entries[providerID]
    }

    func store(_ reading: MuseUsageReading, for providerID: String, at timestamp: Date = Date()) {
        entries[providerID] = Entry(reading: reading, timestamp: timestamp)
    }

    func clear(providerID: String) {
        entries.removeValue(forKey: providerID)
    }
}
