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
    /// Fable's own weekly limit: the `7d_oi` ("overage included") headers,
    /// which Claude Code calls the "Fable limit".
    var sevenDayFable: Window?

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
        self.init(observedAt: observedAt, fiveHour: fiveHour, sevenDay: sevenDay, sevenDayFable: window("7d_oi"))
    }

    init(observedAt: Date, fiveHour: Window?, sevenDay: Window?, sevenDayFable: Window? = nil) {
        self.observedAt = observedAt
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayFable = sevenDayFable
    }

    func isFresh(now: Date = Date()) -> Bool {
        now.timeIntervalSince(observedAt) < Self.maxAge
    }

    /// The same windows as the usage endpoint's `five_hour`, `seven_day`
    /// and Fable's `weekly_scoped` entry (named `fableName`, as the endpoint
    /// named it), then `remembered` per-model limits the headers lack, read
    /// at `rememberedAt`. A window whose reset has passed is empty: the next
    /// one starts with the next message, as the endpoint reports it.
    func usage(
        plan: String?,
        now: Date = Date(),
        fableName: String = "Fable",
        remembered: [UsageWindow] = [],
        rememberedAt: Date? = nil
    ) -> ProviderUsage {
        func ended(_ window: Window) -> Bool {
            window.resetsAt.map { $0 <= now } ?? false
        }
        func window(_ window: Window?, _ label: String, hours: Double) -> UsageWindow? {
            guard let window else { return nil }
            return UsageWindow(
                label: label,
                usedPercent: ended(window) ? 0 : window.usedPercent,
                resetsAt: ended(window) ? nil : window.resetsAt,
                duration: hours * 3600
            )
        }
        let fable = sevenDayFable.map {
            ClaudeProvider.modelWeeklyWindow(
                model: fableName,
                usedPercent: ended($0) ? 0 : $0.usedPercent,
                resetsAt: ended($0) ? nil : $0.resetsAt
            )
        }
        var windows = [
            window(fiveHour, L("5h limit"), hours: 5),
            window(sevenDay, L("Weekly limit"), hours: 7 * 24),
            fable,
        ].compactMap { $0 }
        var asOf = observedAt
        for window in remembered where !windows.contains(where: { $0.label == window.label }) {
            let ended = window.resetsAt.map { $0 <= now } ?? false
            windows.append(ended
                ? UsageWindow(label: window.label, usedPercent: 0, resetsAt: nil, duration: window.duration, shortName: window.shortName)
                : window)
            if let rememberedAt { asOf = min(asOf, rememberedAt) }
        }
        return ProviderUsage(planName: plan?.capitalized, windows: windows, asOf: asOf)
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

/// Each Claude account's per-model weekly limits (Fable, Opus) from its last
/// usage answer. The proxy keeps only the headers of an account's latest
/// reply, and replies to other models can lack Fable's limit, so numbers
/// read from headers add the remembered ones.
actor ClaudeModelLimitMemory {
    static let shared = ClaudeModelLimitMemory()
    /// Older answers make headers without Fable's limit ask the usage
    /// endpoint again: one request per account every 15 minutes at most.
    static let maxAge: TimeInterval = ClaudeProxyQuota.maxAge

    private struct Entry {
        var windows: [UsageWindow] = []
        /// When the usage endpoint answered with `windows`.
        var answeredAt: Date?
        /// The last usage request, answered or failed.
        var triedAt: Date
    }

    private var entries: [String: Entry] = [:]

    /// Remembers the per-model limits of a usage answer, also when it has
    /// none, so an account without them needs no further request.
    func remember(_ usage: ProviderUsage, email: String?, now: Date = Date()) {
        guard let key = Self.key(email) else { return }
        entries[key] = Entry(windows: usage.windows.filter { $0.shortName != nil }, answeredAt: now, triedAt: now)
    }

    /// A usage request that failed waits as long as an answer, so header
    /// numbers don't send one on every refresh. The windows keep their age.
    func attempted(email: String?, now: Date = Date()) {
        guard let key = Self.key(email) else { return }
        var entry = entries[key] ?? Entry(triedAt: now)
        entry.triedAt = now
        entries[key] = entry
    }

    /// Numbers read from headers, with the per-model limits they lack.
    /// `isComplete` is false when the account's last usage request is
    /// missing or older than `maxAge`: the caller then asks the usage
    /// endpoint, and keeps these numbers if that request fails. Remembered
    /// limits older than `maxAge` (the requests keep failing) date the
    /// numbers back to their answer, so the row says how old they are.
    func complete(
        _ quota: ClaudeProxyQuota,
        plan: String?,
        email: String?,
        now: Date = Date()
    ) -> (usage: ProviderUsage, isComplete: Bool) {
        let entry = Self.key(email).flatMap { entries[$0] }
        // Claude Code names the `7d_oi` window after the endpoint's Fable
        // model ("Fable", "Fable 5"…), so both sources fill one row.
        let fableName = entry?.windows.lazy.compactMap(\.shortName)
            .first { $0.lowercased().hasPrefix("fable") } ?? "Fable"
        let oldAnswer = entry?.answeredAt.flatMap { now.timeIntervalSince($0) >= Self.maxAge ? $0 : nil }
        let usage = quota.usage(
            plan: plan,
            now: now,
            fableName: fableName,
            remembered: entry?.windows ?? [],
            rememberedAt: oldAnswer
        )
        guard let entry else { return (usage, false) }
        return (usage, now.timeIntervalSince(entry.triedAt) < Self.maxAge)
    }

    private static func key(_ email: String?) -> String? {
        guard let email = email?.trimmingCharacters(in: .whitespaces).lowercased(), !email.isEmpty else { return nil }
        return email
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
