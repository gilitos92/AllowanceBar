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
        let (cached, failure) = await MainActor.run {
            (MuseUsageCache.shared.entry(for: providerID), MuseUsageCache.shared.failure(for: providerID))
        }
        if let failure {
            let age = now.timeIntervalSince(failure.timestamp)
            if age < MuseServeClient.minimumInterval
                || (!forceRefresh && age < MuseServeClient.retryInterval(after: failure.error)) {
                if case .rateLimited = failure.error, let cached {
                    return MuseServeClient.usage(from: cached.reading, now: now)
                }
                throw failure.error
            }
        }
        if let cached, failure == nil {
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
        } catch var error as MuseServeError {
            DebugLog.write("muse serve \(providerID): failed: \(error)")
            if error == .notSignedIn, configHome != nil {
                error = .notSignedInExtraAccount
            }
            await MainActor.run { MuseUsageCache.shared.storeFailure(error, for: providerID, at: now) }
            if case .rateLimited = error, let cached {
                return MuseServeClient.usage(from: cached.reading, now: now)
            }
            throw error
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

    struct Failure: Equatable {
        let error: MuseServeError
        let timestamp: Date
    }

    private var entries: [String: Entry] = [:]
    private var failures: [String: Failure] = [:]

    func entry(for providerID: String) -> Entry? {
        entries[providerID]
    }

    /// The last attempt's error, when it failed after the last success.
    func failure(for providerID: String) -> Failure? {
        failures[providerID]
    }

    func store(_ reading: MuseUsageReading, for providerID: String, at timestamp: Date = Date()) {
        entries[providerID] = Entry(reading: reading, timestamp: timestamp)
        failures.removeValue(forKey: providerID)
    }

    func storeFailure(_ error: MuseServeError, for providerID: String, at timestamp: Date = Date()) {
        failures[providerID] = Failure(error: error, timestamp: timestamp)
    }

    func clear(providerID: String) {
        entries.removeValue(forKey: providerID)
        failures.removeValue(forKey: providerID)
    }
}
