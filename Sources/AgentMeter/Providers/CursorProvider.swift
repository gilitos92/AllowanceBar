import Foundation

/// Cursor plan usage via cursor.com, authenticated with the locally stored session token.
struct CursorProvider: AccountConfigurableProvider {
    var id = "cursor"
    var displayName = "Cursor"
    var shortCode = "Cu"

    var fetcher = CursorUsageFetcher()

    var isDetected: Bool {
        FileManager.default.fileExists(atPath: fetcher.stateDBPath)
    }

    var dashboardURL: URL? {
        URL(string: "https://cursor.com/dashboard")
    }

    func fetch() async throws -> ProviderUsage {
        try await fetcher.fetchUsage()
    }
}
