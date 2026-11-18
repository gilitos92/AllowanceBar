import Foundation

/// Anthropic answers "too many requests" (HTTP 429) when one login asks for
/// its usage too often, and asking again right away keeps the limit going.
/// So after a 429, that login sends nothing to Anthropic for a while: the
/// server's `Retry-After` when it sends one, otherwise 5 minutes, doubling
/// while 429s continue, up to 30 minutes. Forced refreshes wait too. The row
/// keeps its last numbers meanwhile and says when it tries again. The wait
/// covers the account, so its local and proxy rows wait together.
///
/// Anthropic refuses the usage request of an account without a paid plan
/// (HTTP 403, `permission_error`), and asking again soon after turns into
/// hour-long 429s. So such a refusal makes the account wait 6 hours.
actor ClaudeRateLimitGate {
    static let shared = ClaudeRateLimitGate()
    static let firstWait: TimeInterval = 5 * 60
    static let maxWait: TimeInterval = 30 * 60
    /// After Anthropic refuses an account's usage (`unavailable`).
    static let unavailableWait: TimeInterval = 6 * 3600
    /// Bounds for the server's own `Retry-After`.
    static let retryAfterRange: ClosedRange<TimeInterval> = 60...3600

    private struct Entry {
        var until: Date
        var strikes: Int
        var refused = false
    }

    private var entries: [String: Entry] = [:]

    /// One key per Claude account: its email when known, so the account's
    /// local login and its CLIProxyAPI login wait together.
    static func key(email: String?, fallback: String) -> String {
        guard let email = email?.trimmingCharacters(in: .whitespaces), !email.isEmpty else { return fallback }
        return "account|" + email.lowercased()
    }

    /// Throws `ClaudeError.rateLimited` while `key` is still waiting.
    func check(_ key: String, now: Date = Date()) throws {
        if let entry = entries[key], now < entry.until {
            throw entry.refused
                ? ClaudeError.usageUnavailable(retryAt: entry.until)
                : ClaudeError.rateLimited(retryAt: entry.until)
        }
    }

    /// Records Anthropic refusing `key`'s usage and returns the error to throw.
    func unavailable(_ key: String, now: Date = Date()) -> ClaudeError {
        let until = now.addingTimeInterval(Self.unavailableWait)
        entries[key] = Entry(until: until, strikes: 0, refused: true)
        return .usageUnavailable(retryAt: until)
    }

    /// Whether a refused request's body is Anthropic's `permission_error`,
    /// not, say, a proxy or network page that also answers 403.
    static func isRefusal(_ body: Data) -> Bool {
        struct Answer: Decodable {
            struct Detail: Decodable { let type: String? }
            let error: Detail?
        }
        return (try? JSONDecoder().decode(Answer.self, from: body))?.error?.type == "permission_error"
    }

    /// Records a 429 for `key` and returns the error to throw.
    func limited(_ key: String, retryAfter: TimeInterval?, now: Date = Date()) -> ClaudeError {
        let strikes = (entries[key]?.strikes ?? 0) + 1
        let backoff = min(Self.firstWait * pow(2, Double(strikes - 1)), Self.maxWait)
        let wait = retryAfter.map {
            min(max($0, Self.retryAfterRange.lowerBound), Self.retryAfterRange.upperBound)
        } ?? backoff
        let until = now.addingTimeInterval(wait)
        entries[key] = Entry(until: until, strikes: strikes)
        return .rateLimited(retryAt: until)
    }

    /// A good answer ends the wait and resets the backoff.
    func succeeded(_ key: String) {
        entries[key] = nil
    }

    /// Seconds from a `Retry-After` value: a number of seconds or an HTTP date.
    static func retryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) { return max(seconds, 0) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(date.timeIntervalSince(now), 0)
    }
}
