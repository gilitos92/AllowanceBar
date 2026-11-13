import Foundation

/// The Claude limits CLIProxyAPI saw last for one login. Anthropic answers
/// every Claude Code message with `anthropic-ratelimit-unified-*` headers,
/// and the proxy keeps the latest ones in its login list (`quota.signals`,
/// with `quota.observed_at`). Reading them sends nothing to Anthropic, so
/// they come before the usage endpoint while they are recent. The proxy
/// keeps them in memory only: a login that has sent no message since the
/// proxy started has none.
struct ClaudeProxyQuota: Equatable, Sendable {
    struct Window: Equatable, Sendable {
        /// 0–100.
        var usedPercent: Double
        var resetsAt: Date?
    }

    var observedAt: Date
    var fiveHour: Window?
    var sevenDay: Window?

    /// Older numbers ask Anthropic instead. Use that doesn't pass through
    /// the proxy (claude.ai, the Claude apps, a login used directly) changes
    /// the limits without updating these headers.
    static let maxAge: TimeInterval = 15 * 60

    /// Nil without an observation time or without any window.
    init?(signals: [String: String], observedAt: String?) {
        guard let observedAt = observedAt.flatMap(Self.date(fromISO8601:)) else { return nil }
        var lowercased: [String: String] = [:]
        for (key, value) in signals {
            lowercased[key.lowercased()] = value.trimmingCharacters(in: .whitespaces)
        }
        func window(_ name: String) -> Window? {
            let prefix = "anthropic-ratelimit-unified-\(name)-"
            let utilization = lowercased[prefix + "utilization"].flatMap(Double.init)
            let rejected = lowercased[prefix + "status"]?.lowercased() == "rejected"
            guard utilization != nil || rejected else { return nil }
            // Anthropic sends a fraction (0.56 = 56%); "rejected" means the
            // limit is reached whatever the fraction says.
            let percent = rejected ? 100 : max(0, min(100, (utilization ?? 0) * 100))
            let reset = lowercased[prefix + "reset"].flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
            return Window(usedPercent: percent, resetsAt: reset)
        }
        let fiveHour = window("5h")
        let sevenDay = window("7d")
        guard fiveHour != nil || sevenDay != nil else { return nil }
        self.init(observedAt: observedAt, fiveHour: fiveHour, sevenDay: sevenDay)
    }

    init(observedAt: Date, fiveHour: Window?, sevenDay: Window?) {
        self.observedAt = observedAt
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }

    func isFresh(now: Date = Date()) -> Bool {
        now.timeIntervalSince(observedAt) < Self.maxAge
    }

    /// The same windows as the usage endpoint's `five_hour` and `seven_day`.
    /// A window whose reset has passed is empty: the next one starts with
    /// the next message, as the endpoint reports it.
    func usage(plan: String?, now: Date = Date()) -> ProviderUsage {
        func window(_ window: Window?, _ label: String, hours: Double) -> UsageWindow? {
            guard let window else { return nil }
            let ended = window.resetsAt.map { $0 <= now } ?? false
            return UsageWindow(
                label: label,
                usedPercent: ended ? 0 : window.usedPercent,
                resetsAt: ended ? nil : window.resetsAt,
                duration: hours * 3600
            )
        }
        let windows = [
            window(fiveHour, L("5h limit"), hours: 5),
            window(sevenDay, L("Weekly limit"), hours: 7 * 24),
        ].compactMap { $0 }
        return ProviderUsage(planName: plan?.capitalized, windows: windows, asOf: observedAt)
    }

    /// The proxy writes microseconds and a UTC offset
    /// ("2026-11-13T12:27:21.145256-06:00").
    static func date(fromISO8601 string: String) -> Date? {
        let value = string.trimmingCharacters(in: .whitespaces)
        if let date = ISO8601DateFormatter.flexible.date(from: value) ?? ISO8601DateFormatter.plain.date(from: value) {
            return date
        }
        // Drop the fraction when the formatter refuses its length.
        guard let dot = value.firstIndex(of: "."),
              let end = value[dot...].dropFirst().firstIndex(where: { !$0.isNumber }) else {
            return nil
        }
        return ISO8601DateFormatter.plain.date(from: String(value[..<dot]) + String(value[end...]))
    }
}

/// Waits for `work` at most `seconds`, then gives up with nil. `work` keeps
/// running in the background, so a shared request still finishes for the
/// others who wait for it.
enum Deadline {
    static func value<T: Sendable>(
        within seconds: TimeInterval,
        _ work: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            Task { once.resume(await work()) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                once.resume(nil)
            }
        }
    }

    /// Resumes the continuation with the first value only.
    private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?

        init(_ continuation: CheckedContinuation<T?, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: T?) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: value)
        }
    }
}
