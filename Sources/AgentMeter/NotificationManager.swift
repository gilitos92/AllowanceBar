import Foundation
import UserNotifications

/// Tracks which usage windows have crossed a notification threshold.
struct ThresholdTracker {
    private var notifiedResetsAt: [String: Date]
    private var lastNotifiedPercents: [String: Double]
    private let defaults: UserDefaults

    private static let stateKey = "thresholdTrackerState"
    private static let resetsKey = "thresholdTrackerNotifiedResetsAt"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.lastNotifiedPercents = defaults.dictionary(forKey: Self.stateKey) as? [String: Double] ?? [:]
        let resets = defaults.dictionary(forKey: Self.resetsKey) as? [String: Double] ?? [:]
        self.notifiedResetsAt = resets.mapValues { Date(timeIntervalSince1970: $0) }
    }

    mutating func crossings(
        providerID: String,
        usage: ProviderUsage,
        threshold: Double,
        now: Date = Date()
    ) -> [UsageWindow] {
        var result: [UsageWindow] = []

        for window in usage.windows {
            let key = "\(providerID)|\(window.label)"
            // Reset estimates can drift while a limit remains exhausted. Only
            // a later window after the notified deadline has elapsed re-arms.
            // Keep the deadline on disk so this also works across app restarts.
            if let notifiedReset = notifiedResetsAt[key] {
                if notifiedReset <= now,
                   let newReset = window.resetsAt,
                   newReset > notifiedReset {
                    lastNotifiedPercents.removeValue(forKey: key)
                    notifiedResetsAt.removeValue(forKey: key)
                }
            } else if window.usedPercent < threshold {
                // Providers without a reset date can only re-arm from usage.
                lastNotifiedPercents.removeValue(forKey: key)
            }

            let wasBelow = lastNotifiedPercents[key].map { $0 < threshold } ?? true
            if window.usedPercent >= threshold, wasBelow {
                result.append(window)
                lastNotifiedPercents[key] = window.usedPercent
            }

            // Seed a deadline for existing saved alerts and windows whose reset
            // date was temporarily unavailable, without sending another alert.
            if lastNotifiedPercents[key] != nil, notifiedResetsAt[key] == nil,
               let resetsAt = window.resetsAt {
                notifiedResetsAt[key] = resetsAt
            }
        }

        defaults.set(lastNotifiedPercents, forKey: Self.stateKey)
        defaults.set(notifiedResetsAt.mapValues { $0.timeIntervalSince1970 }, forKey: Self.resetsKey)
        return result
    }

    mutating func balanceCrossings(
        providerID: String,
        balance: BalanceInfo,
        threshold: Double
    ) -> Bool {
        guard balance.kind == .remaining else { return false }
        let key = "balance.\(providerID)"
        let remaining = balance.remaining

        if remaining >= threshold {
            lastNotifiedPercents.removeValue(forKey: key)
        }

        let wasAbove = lastNotifiedPercents[key].map { $0 >= threshold } ?? true
        if remaining < threshold, wasAbove {
            lastNotifiedPercents[key] = remaining
            defaults.set(lastNotifiedPercents, forKey: Self.stateKey)
            return true
        }

        defaults.set(lastNotifiedPercents, forKey: Self.stateKey)
        return false
    }
}

/// Tracks which usage windows have run well ahead of pace. One alert per
/// window; it re-arms only after that window's reset has passed.
struct PaceTracker {
    /// Points ahead of even pace that trigger an alert.
    static let alertGap: Double = 15
    /// Early in a window a little use is far "ahead"; wait this long first.
    static let minimumElapsed: Double = 0.1

    private var notifiedResetsAt: [String: Date]
    private let defaults: UserDefaults

    private static let stateKey = "paceTrackerNotifiedResetsAt"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.dictionary(forKey: Self.stateKey) as? [String: Double] ?? [:]
        self.notifiedResetsAt = raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    mutating func alerts(providerID: String, usage: ProviderUsage, now: Date = Date()) -> [UsageWindow] {
        var result: [UsageWindow] = []
        for window in usage.windows {
            let key = "\(providerID)|\(window.label)"
            if let notified = notifiedResetsAt[key] {
                guard notified <= now else { continue }
                notifiedResetsAt.removeValue(forKey: key)
            }
            guard let resetsAt = window.resetsAt,
                  window.usedPercent < 100,
                  let elapsed = window.elapsedFraction(now: now),
                  elapsed >= Self.minimumElapsed,
                  window.usedPercent - elapsed * 100 >= Self.alertGap else { continue }
            notifiedResetsAt[key] = resetsAt
            result.append(window)
        }
        defaults.set(notifiedResetsAt.mapValues { $0.timeIntervalSince1970 }, forKey: Self.stateKey)
        return result
    }

    /// When the limit runs out if use keeps its average rate so far. Nil when
    /// it is not ahead of pace.
    static func projectedRunOut(for window: UsageWindow, now: Date = Date()) -> Date? {
        guard let resetsAt = window.resetsAt, let duration = window.duration,
              let elapsed = window.elapsedFraction(now: now),
              elapsed > 0, window.usedPercent > 0 else { return nil }
        let start = resetsAt.addingTimeInterval(-duration)
        let percentPerSecond = window.usedPercent / now.timeIntervalSince(start)
        let runOut = now.addingTimeInterval((100 - window.usedPercent) / percentPerSecond)
        return runOut < resetsAt ? runOut : nil
    }
}

/// Tracks which renewal dates have already triggered a reminder notification.
struct RenewalTracker {
    private var lastRenewalNotified: [String: Date] = [:]
    private let defaults: UserDefaults

    private static let stateKey = "renewalTrackerState"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.dictionary(forKey: Self.stateKey) as? [String: Double] {
            lastRenewalNotified = raw.mapValues { Date(timeIntervalSince1970: $0) }
        }
    }

    mutating func pendingNotification(
        providerID: String,
        renewal: SubscriptionRenewal,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date? {
        let nextRenewalDate = renewal.nextRenewal(after: now, calendar: calendar)
        guard let reminderDate = renewal.reminderDate(for: nextRenewalDate, calendar: calendar) else {
            return nil
        }
        guard now >= reminderDate else { return nil }

        if let notifiedFor = lastRenewalNotified[providerID],
           calendar.isDate(notifiedFor, inSameDayAs: nextRenewalDate) {
            return nil
        }

        lastRenewalNotified[providerID] = nextRenewalDate
        let raw = lastRenewalNotified.mapValues { $0.timeIntervalSince1970 }
        defaults.set(raw, forKey: Self.stateKey)
        return nextRenewalDate
    }
}

@MainActor
final class NotificationManager {
    private var tracker = ThresholdTracker()
    private var renewalTracker = RenewalTracker()
    private var paceTracker = PaceTracker()
    private var authorizationRequested = false

    func notifyIfNeeded(
        provider: any UsageProvider,
        usage: ProviderUsage,
        settings: SettingsStore
    ) {
        if settings.paceNotificationsEnabled {
            for window in paceTracker.alerts(providerID: provider.id, usage: usage) {
                postPaceNotification(provider: provider, window: window)
            }
        }

        guard settings.notificationsEnabled else { return }

        let crossings = tracker.crossings(
            providerID: provider.id,
            usage: usage,
            threshold: settings.notificationThreshold
        )
        for window in crossings {
            postNotification(provider: provider, window: window)
        }

        if let balance = usage.balance,
           tracker.balanceCrossings(
               providerID: provider.id,
               balance: balance,
               threshold: settings.balanceNotificationThreshold
           ) {
            postBalanceNotification(provider: provider, balance: balance)
        }

        if let renewal = settings.renewal(for: provider.id),
           let renewalDate = renewalTracker.pendingNotification(
               providerID: provider.id,
               renewal: renewal
           ) {
            postRenewalNotification(
                provider: provider,
                renewal: renewal,
                renewalDate: renewalDate
            )
        }
    }

    func requestAuthorizationIfNeeded() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postNotification(provider: any UsageProvider, window: UsageWindow) {
        let content = UNMutableNotificationContent()
        content.title = L("\(provider.displayName) usage alert")
        var body = L("\(window.label) at \(String(Int(window.usedPercent.rounded())))%")
        if let remaining = window.remainingDescription {
            body += " — \(remaining)"
        }
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "\(provider.id)-\(window.label)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func postPaceNotification(provider: any UsageProvider, window: UsageWindow) {
        let now = Date()
        let content = UNMutableNotificationContent()
        content.title = L("\(provider.displayName) ahead of pace")
        let used = Int(window.usedPercent.rounded())
        let elapsed = Int(((window.elapsedFraction(now: now) ?? 0) * 100).rounded())
        var body = L("\(window.label): \(String(used))% used with \(String(elapsed))% of the window gone.")
        if let runOut = PaceTracker.projectedRunOut(for: window, now: now) {
            let estimate = UsageWindow(label: window.label, usedPercent: 0, resetsAt: runOut)
            if let left = estimate.shortRemainingDescription(now: now) {
                body += " " + L("At this rate it runs out in \(left).")
            }
        }
        if let remaining = window.remainingDescription {
            body += " " + remaining.prefix(1).uppercased() + remaining.dropFirst() + "."
        }
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "\(provider.id)-\(window.label)-pace-\(now.timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func postBalanceNotification(provider: any UsageProvider, balance: BalanceInfo) {
        let content = UNMutableNotificationContent()
        content.title = L("\(provider.displayName) balance alert")
        content.body = L("\(balance.currencySymbol)\(BalanceInfo.format(balance.remaining)) remaining")
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "\(provider.id)-balance-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func postRenewalNotification(
        provider: any UsageProvider,
        renewal: SubscriptionRenewal,
        renewalDate: Date
    ) {
        let content = UNMutableNotificationContent()
        content.title = L("Subscription renews soon")
        let formattedDate = renewalDate.formatted(date: .abbreviated, time: .omitted)
        content.body = String(
            format: L("%@ renews %@ via %@."),
            provider.displayName,
            formattedDate,
            renewal.platform.displayName
        )
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "\(provider.id)-renewal-\(renewalDate.timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
