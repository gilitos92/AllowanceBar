import Foundation

/// Shared cache-free HTTP session. Responses are tiny JSON blobs fetched once
/// a minute; URLCache would only hold memory for data we never reuse.
/// Redirects are refused: every request carries a credential (Authorization
/// or Cursor's Cookie header), and none of the provider APIs redirect.
enum HTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        return URLSession(configuration: config, delegate: NoRedirectDelegate.shared, delegateQueue: nil)
    }()
}

/// A redirect must never forward a credential to another origin.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = NoRedirectDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// One rate-limit window (e.g. Codex 5h window, Cursor monthly plan usage).
struct UsageWindow: Equatable {
    let label: String
    let usedPercent: Double
    let resetsAt: Date?
    /// Full length of the window (e.g. 5 hours). Needed with `resetsAt` to
    /// know how much of the window has passed, for the pace marker.
    let duration: TimeInterval?

    init(label: String, usedPercent: Double, resetsAt: Date?, duration: TimeInterval? = nil) {
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.duration = duration
    }

    /// Share of the window that has passed, 0...1. Nil when the window's
    /// length or reset is unknown, or `now` falls outside the window (stale
    /// data after a reset, or a reset farther away than one window).
    func elapsedFraction(now: Date = Date()) -> Double? {
        guard let resetsAt, let duration, duration > 0 else { return nil }
        let left = resetsAt.timeIntervalSince(now)
        guard left > 0, left <= duration else { return nil }
        return (duration - left) / duration
    }

    /// Usage compared with even use across the window. Nil when the elapsed
    /// share is unknown.
    func pace(now: Date = Date()) -> UsagePace? {
        guard let elapsed = elapsedFraction(now: now) else { return nil }
        return UsagePace(gap: usedPercent - elapsed * 100)
    }

    var remainingDescription: String? {
        resetDescription(style: .relative)
    }

    /// Time left until reset without the "resets in" prefix, e.g. "3h 32m",
    /// for tight layouts such as the compact Usage Details panel.
    func shortRemainingDescription(now: Date = Date()) -> String? {
        guard let resetsAt else { return nil }
        let interval = resetsAt.timeIntervalSince(now)
        guard interval > 0 else { return L("soon") }
        let days = Int(interval) / 86400
        let hours = (Int(interval) % 86400) / 3600
        let minutes = (Int(interval) % 3600) / 60
        if days > 0 { return L("\(String(days))d \(String(hours))h") }
        if hours > 0 { return L("\(String(hours))h \(String(minutes))m") }
        return L("\(String(minutes))m")
    }

    func resetDescription(style: ResetTimeStyle, now: Date = Date()) -> String? {
        guard let resetsAt else { return nil }
        switch style {
        case .relative:
            let interval = resetsAt.timeIntervalSince(now)
            guard interval > 0 else { return L("resets soon") }
            let days = Int(interval) / 86400
            let hours = (Int(interval) % 86400) / 3600
            let minutes = (Int(interval) % 3600) / 60
            if days > 0 { return L("resets in \(String(days))d \(String(hours))h") }
            if hours > 0 { return L("resets in \(String(hours))h \(String(minutes))m") }
            return L("resets in \(String(minutes))m")
        case .absolute:
            let calendar = Calendar.current
            let includeYear = calendar.component(.year, from: resetsAt)
                != calendar.component(.year, from: now)
            var format = Date.FormatStyle().month(.abbreviated).day().hour().minute()
            if includeYear { format = format.year() }
            let date = resetsAt.formatted(format)
            let interval = resetsAt.timeIntervalSince(now)
            guard interval > 0 else { return L("resets soon") }
            let duration: String
            if interval < 60 {
                duration = L("less than a minute")
            } else if interval >= 86_400 {
                var days = Int(interval) / 86_400
                var hours = Int(((interval - Double(days * 86_400)) / 3_600).rounded())
                if hours == 24 { days += 1; hours = 0 }
                duration = "\(days) \(L(days == 1 ? "day" : "days")) \(hours) \(L(hours == 1 ? "hour" : "hours"))"
            } else if interval >= 3_600 {
                var hours = Int(interval) / 3_600
                var minutes = Int(((interval - Double(hours * 3_600)) / 60).rounded())
                if minutes == 60 { hours += 1; minutes = 0 }
                if hours == 24 {
                    duration = "1 \(L("day")) 0 \(L("hours"))"
                } else {
                    duration = "\(hours) \(L(hours == 1 ? "hour" : "hours")) \(minutes) \(L(minutes == 1 ? "minute" : "minutes"))"
                }
            } else {
                let minutes = Int((interval / 60).rounded())
                if minutes == 60 {
                    duration = "1 \(L("hour")) 0 \(L("minutes"))"
                } else {
                    duration = "\(max(1, minutes)) \(L(minutes == 1 ? "minute" : "minutes"))"
                }
            }
            return L("resets \(date) (\(duration))")
        }
    }
}

/// Pace: percent of the limit used minus percent of the window elapsed.
/// A gap within ±5 points counts as on pace.
enum UsagePace: Equatable {
    /// Using the limit faster than time passes; it may run out before reset.
    case ahead
    case on
    /// Room to spare for the rest of the window.
    case under

    static let tolerance: Double = 5

    init(gap: Double) {
        if gap > Self.tolerance {
            self = .ahead
        } else if gap < -Self.tolerance {
            self = .under
        } else {
            self = .on
        }
    }

    /// Text arrow for plain-text places such as the nano panel.
    var arrow: String {
        switch self {
        case .ahead: return "↗"
        case .on: return "→"
        case .under: return "↘"
        }
    }

    var symbolName: String {
        switch self {
        case .ahead: return "arrow.up.right"
        case .on: return "arrow.right"
        case .under: return "arrow.down.right"
        }
    }

    /// Short phrase for VoiceOver and the icon tooltip.
    var phrase: String {
        switch self {
        case .ahead: return L("ahead of pace")
        case .on: return L("on pace")
        case .under: return L("under pace")
        }
    }

    var explanation: String {
        switch self {
        case .ahead: return L("Ahead of pace: using it faster than time passes.")
        case .on: return L("On pace: about even with the time passed.")
        case .under: return L("Under pace: room to spare before the reset.")
        }
    }
}

enum BalanceKind: Equatable {
    case remaining
    case spent
}

/// Monetary usage for pay-as-you-go providers. Most report a remaining
/// balance; key-scoped APIs may only report spend.
struct BalanceInfo: Equatable {
    let remaining: Double
    /// Lifetime or period spend, when the provider reports it.
    let used: Double?
    /// e.g. "$", "¥", or "VCU " — prefixed to amounts as-is.
    let currencySymbol: String
    let kind: BalanceKind

    init(
        remaining: Double,
        used: Double?,
        currencySymbol: String,
        kind: BalanceKind = .remaining
    ) {
        self.remaining = remaining
        self.used = used
        self.currencySymbol = currencySymbol
        self.kind = kind
    }

    var display: String {
        switch kind {
        case .remaining:
            L("\(currencySymbol)\(Self.format(remaining)) left")
        case .spent:
            L("\(currencySymbol)\(Self.format(remaining)) used")
        }
    }

    /// Compact form for the menu bar, e.g. "$12".
    var shortDisplay: String {
        "\(currencySymbol)\(Self.format(remaining, compact: true))"
    }

    static func format(_ value: Double, compact: Bool = false) -> String {
        if compact, value >= 10 {
            return String(format: "%.0f", value)
        }
        return value == value.rounded() && value < 1000
            ? String(format: "%.0f", value)
            : String(format: "%.2f", value)
    }
}

/// Organization API reporting for a UTC calendar-month interval. Token
/// categories are disjoint; prepaid credits are not available in this report.
struct APIUsageSummary: Equatable, Sendable {
    let costUSD: Double
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int
    let periodStart: Date
    let periodEnd: Date

    func isAwaitingCurrentDay(now: Date = Date()) -> Bool {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        return periodEnd <= utc.startOfDay(for: now)
    }
}

/// Normalized usage snapshot for one provider.
struct ProviderUsage: Equatable {
    let planName: String?
    let windows: [UsageWindow]
    /// When the underlying data was produced. For API reports without a source
    /// freshness timestamp, this is the last check; apiUsage.periodEnd is coverage.
    let asOf: Date?
    /// Balance readout for pay-as-you-go providers (may coexist with windows).
    var balance: BalanceInfo?
    var apiUsage: APIUsageSummary?

    init(planName: String?, windows: [UsageWindow], asOf: Date?, balance: BalanceInfo? = nil, apiUsage: APIUsageSummary? = nil) {
        self.planName = planName
        self.windows = windows
        self.asOf = asOf
        self.balance = balance
        self.apiUsage = apiUsage
    }

    /// The most constrained window, used for the menu bar summary.
    var worstWindow: UsageWindow? {
        windows.max(by: { $0.usedPercent < $1.usedPercent })
    }

    /// Menu bar summary: percent when windows exist, balance otherwise.
    /// With `allWindows`, every window shows in provider order: the first one
    /// plain and the rest in parentheses, e.g. "8% (35%)".
    /// `showsPace` adds each window's pace arrow after its percent, e.g. "38%↗".
    func menuSummary(
        direction: CountDirection,
        allWindows: Bool = false,
        showsPace: Bool = false,
        now: Date = Date()
    ) -> String? {
        func label(_ window: UsageWindow) -> String {
            let percent = direction.percentLabel(window.usedPercent, menuBar: true)
            guard showsPace, let pace = window.pace(now: now) else { return percent }
            return percent + pace.arrow
        }
        if allWindows, let first = windows.first, windows.count > 1 {
            let rest = windows.dropFirst().map(label).joined(separator: ", ")
            return "\(label(first)) (\(rest))"
        }
        if let worst = worstWindow {
            return label(worst)
        }
        return balance?.shortDisplay
    }
}

enum ProviderState: Equatable {
    case loading
    case ready(ProviderUsage)
    /// Last-known data shown dimmed after a fetch failure.
    case stale(ProviderUsage, error: String, since: Date)
    case error(String)

    var usage: ProviderUsage? {
        switch self {
        case .ready(let usage), .stale(let usage, _, _):
            return usage
        case .loading, .error:
            return nil
        }
    }

    /// Pure transition when a provider fetch fails.
    nonisolated static func nextState(
        after previous: ProviderState,
        failure message: String,
        at date: Date
    ) -> ProviderState {
        switch previous {
        case .ready(let usage):
            return .stale(usage, error: message, since: date)
        case .stale(let usage, _, let since):
            return .stale(usage, error: message, since: since)
        case .loading, .error:
            return .error(message)
        }
    }
}
