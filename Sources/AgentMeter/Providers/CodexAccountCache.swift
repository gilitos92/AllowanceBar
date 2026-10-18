import Foundation

enum CodexPath {
    nonisolated static var defaultHome: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }
}

@MainActor
final class CodexAccountCache {
    static let shared = CodexAccountCache()

    private struct Entry {
        let reading: CodexAccountReading
        let timestamp: Date
    }

    private var entries: [String: Entry] = [:]

    func cachedReading(for providerID: String, maxAge: TimeInterval) -> (reading: CodexAccountReading, timestamp: Date)? {
        guard let entry = entries[providerID],
              Date().timeIntervalSince(entry.timestamp) < maxAge else {
            return nil
        }
        return (entry.reading, entry.timestamp)
    }

    func store(_ reading: CodexAccountReading, for providerID: String, at timestamp: Date = Date()) {
        entries[providerID] = Entry(reading: reading, timestamp: timestamp)
    }

    func lastEmail(for providerID: String) -> String? {
        entries[providerID]?.reading.email
    }

    func lastPlanType(for providerID: String) -> String? {
        let reading = entries[providerID]?.reading
        return reading?.planType ?? reading?.rateLimits?.planType
    }

    func clear(providerID: String) {
        entries.removeValue(forKey: providerID)
    }
}
