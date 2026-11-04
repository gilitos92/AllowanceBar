import SwiftUI

struct ProviderUsageSections: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: SettingsStore

    var body: some View {
        let visible = store.visibleProviders
        if visible.isEmpty {
            Text(L("No providers enabled. Open Settings to turn some on."))
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        } else {
            // Several accounts of one provider share one header, like one
            // account's several limits do.
            ForEach(Array(ProviderGroup.groups(visible).enumerated()), id: \.element.id) { index, group in
                if index > 0 { Divider() }
                if group.members.count == 1, let provider = group.members.first {
                    ProviderSection(
                        provider: provider,
                        state: store.state(for: provider.id),
                        settings: settings,
                        priority: priority(for: provider)
                    )
                } else {
                    ProviderGroupSection(
                        group: group,
                        states: Dictionary(uniqueKeysWithValues: group.members.map { ($0.id, store.state(for: $0.id)) }),
                        priorities: group.members.reduce(into: [:]) { result, provider in
                            result[provider.id] = priority(for: provider)
                        },
                        settings: settings
                    )
                }
            }
        }
    }

    private func priority(for provider: any UsageProvider) -> ProxyPriority? {
        settings.showsProxyPriority ? store.proxyPriority(for: provider) : nil
    }
}

struct ProviderSection: View {
    let provider: any UsageProvider
    let state: ProviderState
    @ObservedObject var settings: SettingsStore
    /// Place in CLIProxyAPI's order of use; nil when hidden or unknown.
    var priority: ProxyPriority? = nil
    @Environment(\.openURL) private var openURL

    var body: some View {
        sectionContent
            .accessibilityElement(children: .contain)
            .accessibilityLabel(provider.displayName)
            .modifier(ProviderSectionAccessibilityValue(value: sectionAccessibilityValue))
    }

    @ViewBuilder
    private var sectionContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        ProviderBadge(provider: provider, size: 18)
                        if let url = provider.dashboardURL {
                            // A plain button rather than a Link, so the title
                            // reads as text instead of an accent-colored link.
                            Button {
                                openURL(url)
                            } label: {
                                Text(provider.displayName)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(.isLink)
                        } else {
                            Text(provider.displayName).font(.headline)
                        }
                    }
                    if let codex = provider as? CodexProvider,
                       !codex.isPrimary,
                       let email = codex.accountEmail {
                        Text(email)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let priority {
                    ProxyPriorityCapsule(priority: priority)
                }
                if let usage = state.usage, let plan = usage.planName {
                    PlanCapsule(plan: plan)
                }
            }

            ProviderStateContent(provider: provider, state: state, settings: settings)
        }
    }

    private var sectionAccessibilityValue: String? {
        state.sectionAccessibilityValue
    }
}

/// Several accounts of one provider under one header, e.g. three Claude
/// logins: the badge, name, shared plan and "Data as of" line appear once,
/// and each account adds only its name and its limits.
struct ProviderGroupSection: View {
    let group: ProviderGroup
    let states: [String: ProviderState]
    let priorities: [String: ProxyPriority]
    @ObservedObject var settings: SettingsStore
    @Environment(\.openURL) private var openURL

    var body: some View {
        let usages = group.members.map { state(for: $0).usage }
        let sharedPlan = ProviderGroup.sharedPlan(of: usages)
        let labels = group.accountLabels(emails: emails)
        VStack(alignment: .leading, spacing: 10) {
            header(plan: sharedPlan)
            ForEach(group.members, id: \.id) { provider in
                let state = state(for: provider)
                let label = labels[provider.id]
                GroupedAccountView(
                    provider: provider,
                    name: label?.name ?? provider.displayName,
                    detail: label?.detail,
                    state: state,
                    plan: sharedPlan == nil ? state.usage?.planName : nil,
                    priority: priorities[provider.id],
                    settings: settings
                )
            }
            if let asOf = sharedAsOf {
                Text(L("Data as of \(asOf.formatted(date: .omitted, time: .shortened))"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(group.baseName)
    }

    private func state(for provider: any UsageProvider) -> ProviderState {
        states[provider.id] ?? .loading
    }

    /// Each account's signed-in email. Codex remembers its last one, so an
    /// account keeps its email while it loads or fails.
    private var emails: [String: String] {
        group.members.reduce(into: [:]) { result, provider in
            if let email = state(for: provider).usage?.accountEmail ?? (provider as? CodexProvider)?.accountEmail {
                result[provider.id] = email
            }
        }
    }

    /// The oldest data among accounts that show limits or balances, shown
    /// once for the group. Stale accounts and API reports keep their own line.
    private var sharedAsOf: Date? {
        group.members.compactMap { provider -> Date? in
            guard case .ready(let usage) = state(for: provider), usage.apiUsage == nil else { return nil }
            return usage.asOf
        }.min()
    }

    private func header(plan: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(spacing: 6) {
                ProviderBadge(providerID: group.baseID, shortCode: group.baseShortCode, size: 18)
                if let url = group.members.lazy.compactMap(\.dashboardURL).first {
                    Button {
                        openURL(url)
                    } label: {
                        Text(group.baseName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(.isLink)
                } else {
                    Text(group.baseName).font(.headline)
                }
            }
            Spacer()
            if let plan {
                PlanCapsule(plan: plan)
            }
        }
    }
}

/// One account inside a `ProviderGroupSection`: its name, then its limits.
private struct GroupedAccountView: View {
    let provider: any UsageProvider
    let name: String
    let detail: String?
    let state: ProviderState
    /// Shown only when the group's accounts have different plans.
    let plan: String?
    let priority: ProxyPriority?
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail {
                    Text(detail)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if let priority {
                    ProxyPriorityCapsule(priority: priority)
                }
                if let plan {
                    PlanCapsule(plan: plan)
                }
            }
            // A thin rule ties an account's limits to its name.
            VStack(alignment: .leading, spacing: 8) {
                ProviderStateContent(provider: provider, state: state, settings: settings, inGroup: true)
            }
            .padding(.leading, 10)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(.quaternary)
                    .frame(width: 2)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(provider.displayName)
        .modifier(ProviderSectionAccessibilityValue(value: state.sectionAccessibilityValue))
    }
}

/// A provider's limits, balance or status below its name.
private struct ProviderStateContent: View {
    let provider: any UsageProvider
    let state: ProviderState
    @ObservedObject var settings: SettingsStore
    /// Inside a group, the group shows one "Data as of" line for all accounts.
    var inGroup = false

    var body: some View {
        switch state {
        case .loading:
            Text(L("Loading…")).font(.callout.weight(.medium)).foregroundStyle(.secondary)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
        case .ready(let usage):
            UsageMetersView(
                providerName: provider.displayName,
                usage: usage,
                settings: settings,
                showsAsOf: !inGroup || usage.apiUsage != nil
            )
            subscriptionRenewalRow
        case .stale(let usage, let error, let since):
            // "Stale since" is when fetching started to fail, not how old
            // the numbers are, so a stale account keeps its own data time
            // even inside a group.
            UsageMetersView(
                providerName: provider.displayName,
                usage: usage,
                settings: settings
            )
            .opacity(0.55)
            subscriptionRenewalRow
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Stale since \(since.formatted(date: .omitted, time: .shortened))"))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var subscriptionRenewalRow: some View {
        if provider.id == "codex" || provider.id.hasPrefix("codex:"),
           let renewal = settings.renewal(for: provider.id) {
            SubscriptionRenewalRow(renewal: renewal)
        }
    }
}

struct PlanCapsule: View {
    let plan: String

    var body: some View {
        Text(plan)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

private extension ProviderState {
    var sectionAccessibilityValue: String? {
        switch self {
        case .stale:
            return L("data is stale")
        case .error:
            return L("error")
        case .loading, .ready:
            return nil
        }
    }
}

/// The account's place in CLIProxyAPI's order of use, e.g. "Proxy #1".
struct ProxyPriorityCapsule: View {
    let priority: ProxyPriority

    var body: some View {
        Label(priority.label, systemImage: "arrow.triangle.branch")
            .labelStyle(.titleAndIcon)
            .font(.callout.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(.quaternary))
            .help(priority.explanation)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("CLIProxyAPI order"))
            .accessibilityValue(priority.phrase)
    }
}

struct SubscriptionRenewalRow: View {
    let renewal: SubscriptionRenewal

    var body: some View {
        let next = renewal.nextRenewal(after: Date())
        let dateText = next.formatted(date: .abbreviated, time: .omitted)
        let statusText = renewal.needsReconfirmation ? L("(expected)") : L("(confirmed)")

        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "calendar")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(String(format: L("Renews %@"), dateText))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("\(renewal.platform.displayName) \(statusText)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("Subscription renewal"))
        .accessibilityValue("\(dateText), \(renewal.platform.displayName), \(statusText)")
    }
}

private struct ProviderSectionAccessibilityValue: ViewModifier {
    let value: String?

    func body(content: Content) -> some View {
        if let value {
            content.accessibilityValue(value)
        } else {
            content
        }
    }
}

struct UsageMetersView: View {
    let providerName: String
    let usage: ProviderUsage
    @ObservedObject var settings: SettingsStore
    var showsAsOf = true

    var body: some View {
        Group {
            if usage.windows.isEmpty && usage.balance == nil && usage.apiUsage == nil {
                Text(L("No usage data")).font(.callout.weight(.medium)).foregroundStyle(.secondary)
            }
            ForEach(usage.windows, id: \.label) { window in
                WindowMeter(
                    providerName: providerName,
                    window: window,
                    settings: settings
                )
            }
            if let apiUsage = usage.apiUsage {
                APIUsageRows(summary: apiUsage)
            } else if let balance = usage.balance {
                BalanceRow(
                    providerName: providerName,
                    balance: balance,
                    settings: settings
                )
            }
            if showsAsOf, let asOf = usage.asOf {
                Text(usage.apiUsage == nil
                     ? L("Data as of \(asOf.formatted(date: .omitted, time: .shortened))")
                     : L("Last checked \(asOf.formatted(date: .omitted, time: .shortened))"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Usage reported by the Claude Console Admin API. These values are kept
/// separate from prepaid credits because the API does not report credit balance.
private struct APIUsageRows: View {
    let summary: APIUsageSummary

    private static let prepaidCreditsURL = URL(string: "https://platform.claude.com/settings/billing")!

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("Month to date (UTC)"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            valueRow(label: L("API spending"), value: summary.costUSD.formatted(.currency(code: "USD")))
            valueRow(label: L("Input tokens"), value: summary.inputTokens.formatted())
            valueRow(label: L("Output tokens"), value: summary.outputTokens.formatted())
            valueRow(label: L("Cache read tokens"), value: summary.cacheReadTokens.formatted())
            valueRow(label: L("Cache creation tokens"), value: summary.cacheCreationTokens.formatted())
            if summary.isAwaitingCurrentDay() {
                Text(L("Today's totals are not yet fully reported by Anthropic."))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
            }
            Text(L("Reports before \(summary.periodEnd.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: TimeZone(secondsFromGMT: 0)!))) UTC"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            valueRow(label: L("Prepaid credits"), value: L("Unavailable via API"))
            Link(L("View prepaid credits"), destination: Self.prepaidCreditsURL)
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Text(L("Reporting may lag the Anthropic website. Priority Tier costs excluded."))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func valueRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Text(value)
                .font(.callout.monospacedDigit().weight(.semibold))
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

private struct BalanceRow: View {
    let providerName: String
    let balance: BalanceInfo
    @ObservedObject var settings: SettingsStore

    private var isLowBalance: Bool {
        balance.kind == .remaining && balance.remaining < settings.balanceNotificationThreshold
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(balance.kind == .remaining ? L("Balance") : L("Usage")).font(.callout.weight(.medium))
                Spacer()
                SeverityValueLabel(
                    text: balance.display,
                    symbolName: isLowBalance ? "exclamationmark.triangle.fill" : nil,
                    badge: isLowBalance ? UsageMeterSeverity.warning.badgeStyle : nil,
                    plainColor: balance.kind == .spent ? .secondary : .primary
                )
            }
            if balance.kind == .remaining, let used = balance.used {
                Text(L("\(balance.currencySymbol)\(BalanceInfo.format(used)) used all-time"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(balanceAccessibilityLabel)
        .accessibilityValue(balanceAccessibilityValue)
    }

    private var balanceAccessibilityLabel: String {
        String(format: L("%@ balance"), providerName)
    }

    private var balanceAccessibilityValue: String {
        var value = balance.accessibilityPhrase
        if isLowBalance {
            value = MenuBarAccessibilitySummary.appendQualifier(value, L("low balance"))
        }
        return value
    }
}

private struct WindowMeter: View {
    let providerName: String
    let window: UsageWindow
    @ObservedObject var settings: SettingsStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            meter(at: context.date)
        }
    }

    private func meter(at now: Date) -> some View {
        let pace = settings.showsPace ? window.pace(now: now) : nil
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(window.label).font(.callout.weight(.medium))
                Spacer()
                SeverityValueLabel(
                    text: settings.countDirection.percentLabel(window.usedPercent),
                    symbolName: severity.symbolName,
                    badge: severity.badgeStyle
                )
                if let pace {
                    Image(systemName: pace.symbolName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            UsageMeterBar(
                percent: progressValue,
                severity: severity,
                paceMarkerPercent: settings.showsPace
                    ? settings.countDirection.paceMarkerPercent(for: window, now: now)
                    : nil
            )
            if let reset = window.resetDescription(style: settings.resetTimeStyle, now: now) {
                Text(reset)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(meterAccessibilityLabel)
        .accessibilityValue(meterAccessibilityValue(at: now))
        .help(pace.map { PaceDescription.tooltip(pace: $0, window: window, direction: settings.countDirection, now: now) } ?? "")
    }

    private var progressValue: Double {
        settings.countDirection.displayPercent(window.usedPercent)
    }

    private var severity: UsageMeterSeverity {
        UsageMeterSeverity.forUsedPercent(window.usedPercent)
    }

    private var meterAccessibilityLabel: String {
        String(format: L("%@, %@"), providerName, window.label)
    }

    private func meterAccessibilityValue(at now: Date) -> String {
        var value = settings.countDirection.accessibilityPercentPhrase(window.usedPercent)
        if let reset = window.resetDescription(style: settings.resetTimeStyle, now: now) {
            value = "\(value), \(reset)"
        }
        if let qualifier = severity.qualifier {
            value = MenuBarAccessibilitySummary.appendQualifier(value, qualifier)
        }
        if settings.showsPace, let pace = window.pace(now: now) {
            value = "\(value), \(pace.phrase)"
        }
        return value
    }
}

/// Text that explains a window's pace in a tooltip.
enum PaceDescription {
    static func tooltip(pace: UsagePace, window: UsageWindow, direction: CountDirection, now: Date) -> String {
        guard let marker = direction.paceMarkerPercent(for: window, now: now) else { return pace.explanation }
        let value = Int(marker.rounded())
        let even = direction == .remaining
            ? L("Even pace: \(value)% left by now.")
            : L("Even pace: \(value)% used by now.")
        return "\(even) \(pace.explanation)"
    }
}
