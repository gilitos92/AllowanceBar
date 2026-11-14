import SwiftUI

/// Where provider modules are shown. Both pack an account's limits two per
/// row; the dropdown stacks the modules, and the main window lays them out in
/// two columns.
enum ProviderModuleLayout {
    case dropdown
    case window
}

/// Every shown provider as a module: a platter with its badge, plan and
/// limits. Several accounts of one provider share one module.
struct ProviderUsageSections: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: SettingsStore
    var layout: ProviderModuleLayout = .dropdown

    var body: some View {
        let visible = store.visibleProviders
        if visible.isEmpty {
            Text(L("No providers enabled. Open Settings to turn some on."))
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .platter()
        } else {
            let groups = ProviderGroup.groups(visible)
            switch layout {
            case .dropdown:
                VStack(spacing: GlassStyle.inset) {
                    ForEach(groups) { module(for: $0) }
                }
            case .window:
                let columns = Self.columns(for: groups, states: store)
                HStack(alignment: .top, spacing: 10) {
                    ForEach(columns.indices, id: \.self) { index in
                        VStack(spacing: 10) {
                            ForEach(columns[index]) { module(for: $0) }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
            }
        }
    }

    private func module(for group: ProviderGroup) -> some View {
        ProviderModule(
            group: group,
            states: Dictionary(uniqueKeysWithValues: group.members.map { ($0.id, store.state(for: $0.id)) }),
            priorities: group.members.reduce(into: [:]) { result, provider in
                result[provider.id] = priority(for: provider)
            },
            settings: settings
        )
    }

    private func priority(for provider: any UsageProvider) -> ProxyPriority? {
        settings.showsProxyPriority ? store.proxyPriority(for: provider) : nil
    }

    /// Splits modules into two columns of similar height, keeping their order
    /// within each column. Height is estimated from the rows each one shows.
    @MainActor
    static func columns(for groups: [ProviderGroup], states store: UsageStore) -> [[ProviderGroup]] {
        var columns: [[ProviderGroup]] = [[], []]
        var heights: [Int] = [0, 0]
        for group in groups {
            let rows = group.members.reduce(1) { total, provider in
                let usage = store.state(for: provider.id).usage
                // Two limits per row.
                let lines = max(1, ((usage?.windows.count ?? 1) + 1) / 2) + (usage?.balance != nil ? 1 : 0)
                return total + lines + (group.members.count > 1 ? 1 : 0)
            }
            let target = heights[0] <= heights[1] ? 0 : 1
            columns[target].append(group)
            heights[target] += rows
        }
        return columns.filter { !$0.isEmpty }
    }
}

/// One provider's platter. A single account shows its limits under the
/// header; several accounts each add their name and limits.
struct ProviderModule: View {
    let group: ProviderGroup
    let states: [String: ProviderState]
    let priorities: [String: ProxyPriority]
    @ObservedObject var settings: SettingsStore
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if group.members.count == 1, let provider = group.members.first {
                singleAccount(provider)
            } else {
                severalAccounts
            }
        }
        .platter()
    }

    // MARK: Single account

    private func singleAccount(_ provider: any UsageProvider) -> some View {
        let state = state(for: provider)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 8) {
                ProviderBadge(provider: provider, size: 20)
                VStack(alignment: .leading, spacing: 1) {
                    title(provider.displayName, url: provider.dashboardURL)
                    if let codex = provider as? CodexProvider,
                       !codex.isPrimary,
                       let email = codex.accountEmail {
                        Text(email)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                if let priority = priorities[provider.id] {
                    ProxyPriorityCapsule(priority: priority)
                }
                if let plan = state.usage?.planName {
                    InfoChip(text: plan)
                }
            }
            ProviderStateContent(provider: provider, state: state, settings: settings)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(provider.displayName)
        .modifier(OptionalAccessibilityValue(value: state.sectionAccessibilityValue))
    }

    // MARK: Several accounts

    private var severalAccounts: some View {
        let usages = group.members.map { state(for: $0).usage }
        let sharedPlan = ProviderGroup.sharedPlan(of: usages)
        let labels = group.accountLabels(emails: emails)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                ProviderBadge(providerID: group.baseID, shortCode: group.baseShortCode, size: 20)
                title(group.baseName, url: group.members.lazy.compactMap(\.dashboardURL).first)
                Spacer(minLength: 4)
                if let sharedPlan {
                    InfoChip(text: sharedPlan)
                }
            }
            ForEach(group.members, id: \.id) { provider in
                let label = labels[provider.id]
                AccountBlock(
                    provider: provider,
                    name: label?.name ?? provider.displayName,
                    detail: label?.detail,
                    state: state(for: provider),
                    plan: sharedPlan == nil ? state(for: provider).usage?.planName : nil,
                    priority: priorities[provider.id],
                    settings: settings
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(group.baseName)
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

    // MARK: Shared

    private func state(for provider: any UsageProvider) -> ProviderState {
        states[provider.id] ?? .loading
    }

    /// The provider name. With a dashboard it is a plain button rather than a
    /// Link, so it reads as a title instead of an accent-colored link.
    @ViewBuilder
    private func title(_ name: String, url: URL?) -> some View {
        let text = Text(name)
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
        if let url {
            Button { openURL(url) } label: { text }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isLink)
                .help(url.host() ?? url.absoluteString)
        } else {
            text
        }
    }
}

/// One account inside a provider's module: its name, then its limits.
private struct AccountBlock: View {
    let provider: any UsageProvider
    let name: String
    let detail: String?
    let state: ProviderState
    /// Shown only when the group's accounts have different plans.
    let plan: String?
    let priority: ProxyPriority?
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                if let plan {
                    InfoChip(text: plan)
                }
                if let detail {
                    Text(detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if let priority {
                    ProxyPriorityCapsule(priority: priority)
                }
            }
            ProviderStateContent(provider: provider, state: state, settings: settings)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(provider.displayName)
        .modifier(OptionalAccessibilityValue(value: state.sectionAccessibilityValue))
    }
}

/// A provider's limits, balance or status below its name.
private struct ProviderStateContent: View {
    let provider: any UsageProvider
    let state: ProviderState
    @ObservedObject var settings: SettingsStore

    var body: some View {
        switch state {
        case .loading:
            Text(L("Loading…"))
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(Color.warningText)
                .fixedSize(horizontal: false, vertical: true)
        case .ready(let usage):
            VStack(alignment: .leading, spacing: 8) {
                UsageMetersView(providerName: provider.displayName, usage: usage, settings: settings)
                subscriptionRenewalRow
            }
        case .stale(let usage, let error, let since):
            VStack(alignment: .leading, spacing: 8) {
                UsageMetersView(providerName: provider.displayName, usage: usage, settings: settings)
                    .opacity(0.55)
                subscriptionRenewalRow
                VStack(alignment: .leading, spacing: 2) {
                    // "Stale since" is when fetching started to fail, not how
                    // old the numbers are.
                    Label(L("Stale since \(since.formatted(date: .omitted, time: .shortened))"), systemImage: "clock")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Color.warningText)
                    Text(error)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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

/// The account's place in CLIProxyAPI's order of use, e.g. "Proxy #1".
struct ProxyPriorityCapsule: View {
    let priority: ProxyPriority

    var body: some View {
        Label(priority.label, systemImage: "arrow.triangle.branch")
            .labelStyle(.titleAndIcon)
            .font(.system(size: 11, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(Color.platterEdge, lineWidth: 1))
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

        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "calendar")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(String(format: L("Renews %@"), dateText))
                .font(.system(size: 12, weight: .medium))
            Text("\(renewal.platform.displayName) \(statusText)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("Subscription renewal"))
        .accessibilityValue("\(dateText), \(renewal.platform.displayName), \(statusText)")
    }
}

struct OptionalAccessibilityValue: ViewModifier {
    let value: String?

    func body(content: Content) -> some View {
        if let value {
            content.accessibilityValue(value)
        } else {
            content
        }
    }
}

extension ProviderState {
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

struct UsageMetersView: View {
    let providerName: String
    let usage: ProviderUsage
    @ObservedObject var settings: SettingsStore

    /// Data older than this gets its own "Data as of" line, e.g. limits
    /// CLIProxyAPI saw several minutes ago. Fresher data, including Codex's
    /// five-minute cache, is covered by the surface's single "Updated" time.
    static let asOfThreshold: TimeInterval = 6 * 60

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if usage.windows.isEmpty && usage.balance == nil && usage.apiUsage == nil {
                Text(L("No usage data"))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            if !usage.windows.isEmpty {
                limits
            }
            if let apiUsage = usage.apiUsage {
                APIUsageRows(summary: apiUsage)
            } else if let balance = usage.balance {
                BalanceRow(providerName: providerName, balance: balance, settings: settings)
            }
            if let asOf = usage.asOf, Date().timeIntervalSince(asOf) > Self.asOfThreshold {
                Text(usage.apiUsage == nil
                     ? L("Data as of \(asOf.formatted(date: .omitted, time: .shortened))")
                     : L("Last checked \(asOf.formatted(date: .omitted, time: .shortened))"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var limits: some View {
        let meters = ForEach(usage.windows, id: \.label) { window in
            WindowMeter(providerName: providerName, window: window, settings: settings)
        }
        if usage.windows.count > 1 {
            // Two limits per row when they fit; one per row otherwise, e.g.
            // for long model names.
            ViewThatFits(in: .horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 9) {
                    ForEach(Array(stride(from: 0, to: usage.windows.count, by: 2)), id: \.self) { start in
                        GridRow(alignment: .top) {
                            WindowMeter(providerName: providerName, window: usage.windows[start], settings: settings)
                            if start + 1 < usage.windows.count {
                                WindowMeter(providerName: providerName, window: usage.windows[start + 1], settings: settings)
                            } else {
                                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 9) { meters }
            }
        } else {
            // A single limit keeps half the width, like its neighbors.
            HStack(spacing: 14) {
                meters
                Color.clear.frame(height: 1)
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
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            valueRow(label: L("API spending"), value: summary.costUSD.formatted(.currency(code: "USD")), prominent: true)
            valueRow(label: L("Input tokens"), value: summary.inputTokens.formatted())
            valueRow(label: L("Output tokens"), value: summary.outputTokens.formatted())
            valueRow(label: L("Cache read tokens"), value: summary.cacheReadTokens.formatted())
            valueRow(label: L("Cache creation tokens"), value: summary.cacheCreationTokens.formatted())
            if summary.isAwaitingCurrentDay() {
                Text(L("Today's totals are not yet fully reported by Anthropic."))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
            }
            Text(L("Reports before \(summary.periodEnd.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: TimeZone(secondsFromGMT: 0)!))) UTC"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            valueRow(label: L("Prepaid credits"), value: L("Unavailable via API"))
            Link(L("View prepaid credits"), destination: Self.prepaidCreditsURL)
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Text(L("Reporting may lag the Anthropic website. Priority Tier costs excluded."))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func valueRow(label: String, value: String, prominent: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: prominent ? .semibold : .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Text(value)
                .font(.meterValue(size: prominent ? 15 : 12.5))
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
            HStack(alignment: .firstTextBaseline) {
                Text(balance.kind == .remaining ? L("Balance") : L("Usage"))
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                SeverityValueLabel(
                    text: balance.display,
                    symbolName: isLowBalance ? UsageMeterSeverity.warning.symbolName : nil,
                    tint: isLowBalance ? Color.warningText : nil,
                    plainColor: balance.kind == .spent ? .secondary : .primary,
                    font: .meterValue(size: 15)
                )
            }
            if balance.kind == .remaining, let used = balance.used {
                Text(L("\(balance.currencySymbol)\(BalanceInfo.format(used)) used all-time"))
                    .font(.system(size: 11, weight: .medium))
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

/// One limit: its name, reset and value on one line, the bar below.
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
        let reset = window.compactReset(style: settings.resetTimeStyle, prefixed: false, now: now)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(window.shortLabel)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
                if reset != nil || pace != nil {
                    HStack(spacing: 3) {
                        if let reset {
                            Text(reset)
                                .font(.system(size: 11, weight: .medium))
                                .monospacedDigit()
                        }
                        if let pace {
                            Image(systemName: pace.symbolName)
                                .font(.system(size: 8.5, weight: .bold))
                        }
                    }
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                }
                Spacer(minLength: 4)
                SeverityValueLabel(
                    // "% left" or "% used" comes from the Display setting and
                    // is spoken; the bare percent keeps two limits per row.
                    text: settings.countDirection.percentLabel(window.usedPercent, menuBar: true),
                    symbolName: severity.symbolName,
                    tint: severity.textColor
                )
            }
            UsageMeterBar(
                percent: progressValue,
                severity: severity,
                paceMarkerPercent: settings.showsPace
                    ? settings.countDirection.paceMarkerPercent(for: window, now: now)
                    : nil
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(meterAccessibilityLabel)
        .accessibilityValue(meterAccessibilityValue(at: now))
        .help(tooltip(pace: pace, now: now))
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

    /// The full reset sentence and, with pace on, how the limit is pacing.
    private func tooltip(pace: UsagePace?, now: Date) -> String {
        let parts = [
            window.resetDescription(style: .absolute, now: now),
            pace.map { PaceDescription.tooltip(pace: $0, window: window, direction: settings.countDirection, now: now) },
        ]
        return parts.compactMap { $0 }.joined(separator: "\n")
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
