import Foundation

/// One usage request per Claude account at a time. An account can show as
/// two rows, this Mac's login and its CLIProxyAPI login, and both refresh
/// together: without this, both ask Anthropic at the same moment, which can
/// trip its rate limit. Keyed like `ClaudeRateLimitGate` (the account's
/// email), so the rows share the request in flight and its answer.
actor ClaudeUsageRequests {
    static let shared = ClaudeUsageRequests()
    /// How long a proxied answer serves the account's rows, so a short
    /// refresh interval doesn't ask Anthropic twice a minute.
    static let proxyMaxAge: TimeInterval = 120

    private var answers: [String: (response: ClaudeProvider.UsageResponse, at: Date)] = [:]
    private var running: [String: Task<ClaudeProvider.UsageResponse, Error>] = [:]

    /// The account's answer: the request in flight, else one younger than
    /// `maxAge`, else a new request. Errors aren't kept; the rate-limit
    /// gate decides when to ask again.
    func response(
        for key: String,
        maxAge: TimeInterval,
        now: Date = Date(),
        fetch: @escaping @Sendable () async throws -> ClaudeProvider.UsageResponse
    ) async throws -> ClaudeProvider.UsageResponse {
        if let task = running[key] { return try await task.value }
        if let answer = answers[key], now.timeIntervalSince(answer.at) < maxAge { return answer.response }
        // Not tied to the caller, like `CLIProxyPlanCache`: rows waiting on
        // it still get the answer when the first caller is cancelled.
        let task = Task { try await fetch() }
        running[key] = task
        defer { running[key] = nil }
        let response = try await task.value
        answers[key] = (response, Date())
        return response
    }
}
