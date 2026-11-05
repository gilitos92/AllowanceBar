import Foundation

/// Anthropic answers "too many requests" (HTTP 429) when one login asks for
/// its usage too often, and asking again right away keeps the limit going.
/// So after a 429, that login sends nothing to Anthropic for a while: the
/// server's `Retry-After` when it sends one, otherwise 5 minutes, doubling
/// while 429s continue, up to 30 minutes. Forced refreshes wait too. The row
/// keeps its last numbers meanwhile and says when it tries again.
actor ClaudeRateLimitGate {
    static let shared = ClaudeRateLimitGate()
    static let firstWait: TimeInterval = 5 * 60
    static let maxWait: TimeInterval = 30 * 60
    /// Bounds for the server's own `Retry-After`.
    static let retryAfterRange: ClosedRange<TimeInterval> = 60...3600

    private struct Entry {
        var until: Date
        var strikes: Int
    }

    private var entries: [String: Entry] = [:]

    /// Throws `ClaudeError.rateLimited` while `key` is still waiting.
    func check(_ key: String, now: Date = Date()) throws {
        if let entry = entries[key], now < entry.until {
            throw ClaudeError.rateLimited(retryAt: entry.until)
        }
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
