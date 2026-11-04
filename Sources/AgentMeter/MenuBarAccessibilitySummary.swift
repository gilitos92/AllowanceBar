import Foundation

/// Builds the spoken menu bar summary for VoiceOver (pure, testable).
enum MenuBarAccessibilitySummary {
    struct ProviderInput: Equatable {
        let displayName: String
        let state: ProviderState
        /// Spoken after the usage when set (the nano panel's proxy order).
        var priority: ProxyPriority? = nil
    }

    nonisolated static func build(
        providers: [ProviderInput],
        countDirection: CountDirection,
        balanceThreshold: Double,
        allWindows: Bool = false,
        includesPace: Bool = false,
        now: Date = Date()
    ) -> String {
        guard !providers.isEmpty else { return L("Allowance Bar") }

        let segments = providers.map { input in
            let segment = providerSegment(
                displayName: input.displayName,
                state: input.state,
                countDirection: countDirection,
                balanceThreshold: balanceThreshold,
                allWindows: allWindows,
                includesPace: includesPace,
                now: now
            )
            return input.priority.map { appendQualifier(segment, $0.phrase) } ?? segment
        }
        return ([L("Allowance Bar")] + segments).joined(separator: ". ")
    }

    nonisolated static func providerSegment(
        displayName: String,
        state: ProviderState,
        countDirection: CountDirection,
        balanceThreshold: Double,
        allWindows: Bool = false,
        includesPace: Bool = false,
        now: Date = Date()
    ) -> String {
        switch state {
        case .loading:
            return String(format: L("%@: %@"), displayName, L("loading"))
        case .error:
            return String(format: L("%@: %@"), displayName, L("error"))
        case .stale(let usage, _, _):
            if let value = usageValue(
                usage: usage,
                countDirection: countDirection,
                balanceThreshold: balanceThreshold,
                allWindows: allWindows,
                includesPace: includesPace,
                now: now
            ) {
                return appendQualifier(
                    String(format: L("%@: %@"), displayName, value),
                    L("data is stale")
                )
            }
            return String(format: L("%@: %@"), displayName, L("data is stale"))
        case .ready(let usage):
            let value = usageValue(
                usage: usage,
                countDirection: countDirection,
                balanceThreshold: balanceThreshold,
                allWindows: allWindows,
                includesPace: includesPace,
                now: now
            ) ?? L("No usage data")
            return String(format: L("%@: %@"), displayName, value)
        }
    }

    nonisolated private static func usageValue(
        usage: ProviderUsage,
        countDirection: CountDirection,
        balanceThreshold: Double,
        allWindows: Bool,
        includesPace: Bool,
        now: Date
    ) -> String? {
        func phrase(_ window: UsageWindow) -> String {
            var text = windowPhrase(window, countDirection: countDirection)
            if includesPace, let pace = window.pace(now: now) {
                text = appendQualifier(text, pace.phrase)
            }
            return text
        }
        if allWindows, usage.windows.count > 1 {
            return usage.windows
                .map { "\($0.label), \(phrase($0))" }
                .joined(separator: "; ")
        }
        if let worst = usage.worstWindow {
            return phrase(worst)
        }
        if let balance = usage.balance {
            var text = balance.accessibilityPhrase
            if balance.kind == .remaining, balance.remaining < balanceThreshold {
                text = appendQualifier(text, L("low balance"))
            }
            return text
        }
        return nil
    }

    nonisolated private static func windowPhrase(
        _ window: UsageWindow,
        countDirection: CountDirection
    ) -> String {
        var text = countDirection.accessibilityPercentPhrase(window.usedPercent)
        if let qualifier = UsageMeterSeverity.forUsedPercent(window.usedPercent).qualifier {
            text = appendQualifier(text, qualifier)
        }
        return text
    }

    nonisolated static func appendQualifier(_ text: String, _ qualifier: String) -> String {
        "\(text), \(qualifier)"
    }
}

extension CountDirection {
    nonisolated func accessibilityPercentPhrase(_ usedPercent: Double) -> String {
        let value = Int(displayPercent(usedPercent).rounded())
        switch self {
        case .used: return L("\(value)% used")
        case .remaining: return L("\(value)% remaining")
        }
    }
}

extension BalanceInfo {
    var accessibilityPhrase: String { display }
}
