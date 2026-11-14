import AppKit
import SwiftUI

/// The Usage Details window's three sizes.
enum UsageDetailsMode: CaseIterable {
    case full, mini, nano

    var title: String {
        switch self {
        case .full: L("Full View")
        case .mini: L("Compact View")
        case .nano: L("Nano View")
        }
    }

    var help: String {
        switch self {
        case .full: L("Show every provider's limits, reset times and plans.")
        case .mini: L("Collapse into a small panel with each provider's limits.")
        case .nano: L("Shrink into a tiny panel with only the menu bar text.")
        }
    }

    var symbol: String {
        switch self {
        case .full: "list.bullet.rectangle"
        case .mini: "rectangle.compress.vertical"
        case .nano: "capsule"
        }
    }
}

extension SettingsStore {
    var usageDetailsMode: UsageDetailsMode {
        get {
            if usageDetailsNano { return .nano }
            return usageDetailsCompact ? .mini : .full
        }
        set {
            switch newValue {
            case .full:
                usageDetailsNano = false
                usageDetailsCompact = false
            case .mini:
                usageDetailsNano = false
                usageDetailsCompact = true
            case .nano:
                usageDetailsNano = true
            }
        }
    }
}

struct UsageDetailsView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: SettingsStore
    @State private var contentHeight: CGFloat?
    @State private var titleBarInset: CGFloat = 0
    @State private var isPointerInside = false
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            switch settings.usageDetailsMode {
            case .nano:
                // Pace arrows depend on the time, not only on refreshes, so
                // redraw every 30 seconds like the meters.
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    NanoUsageView(
                        entries: store.nanoEntries,
                        accessibilityDescription: store.nanoAccessibilityDescription,
                        settings: settings,
                        isPointerInside: isPointerInside,
                        close: { dismissWindow(id: "usage-details") }
                    )
                }
                .padding(.bottom, -titleBarInset)
            case .mini:
                CompactUsageView(
                    entries: store.compactEntries,
                    accountNames: accountNames,
                    settings: settings,
                    isPointerInside: isPointerInside,
                    close: { dismissWindow(id: "usage-details") }
                )
                // Give back the title bar space reserved while compact so
                // the window hugs its rows.
                .padding(.bottom, -titleBarInset)
            case .full:
                expandedContent
            }
        }
        // Liquid Glass behind the content, following the window's corners.
        // Only the background extends under the expanded window's title bar;
        // its content stays in the normal safe area.
        .background(WindowGlassBackground(
            opacity: settings.usageDetailsBackgroundOpacity,
            shape: glassShape
        ).ignoresSafeArea())
        .background(WindowLevelSetter(alwaysOnTop: settings.usageDetailsAlwaysOnTop,
                                      onAllSpaces: settings.usageDetailsOnAllSpaces,
                                      compact: settings.usageDetailsChromeless,
                                      anchorsBottomRight: settings.usageDetailsNano,
                                      onPointerInsideChange: { isPointerInside = $0 },
                                      onTitleBarHeightChange: { titleBarInset = $0 }))
        // The compact and nano panels have no title bar controls; their own
        // hover controls replace the toolbar.
        .toolbar(settings.usageDetailsChromeless ? .hidden : .visible, for: .windowToolbar)
        .toolbar { windowOptions }
        .navigationSubtitle(updatedText)
    }

    private var glassShape: WindowGlassBackground.Shape {
        switch settings.usageDetailsMode {
        case .full: .window
        case .mini: .rounded(GlassStyle.panelRadius)
        case .nano: .capsule
        }
    }

    private var updatedText: String {
        guard let refreshed = store.lastRefreshed else { return "" }
        return L("Updated \(refreshed.formatted(date: .omitted, time: .shortened))")
    }

    /// Names of accounts that share a provider, e.g. "Main", so the compact
    /// panel can tell three Claude rows apart.
    private var accountNames: [String: String] {
        var names: [String: String] = [:]
        for group in ProviderGroup.groups(store.visibleProviders) where group.members.count > 1 {
            let emails = group.members.reduce(into: [String: String]()) { result, provider in
                if let email = store.state(for: provider.id).usage?.accountEmail
                    ?? (provider as? CodexProvider)?.accountEmail {
                    result[provider.id] = email
                }
            }
            for (id, label) in group.accountLabels(emails: emails) {
                // An email names the default account; its first part is
                // enough to tell rows apart in the small panel.
                names[id] = label.name.split(separator: "@").first.map(String.init) ?? label.name
            }
        }
        return names
    }

    /// The view switcher and the window options. On macOS 26 and later each
    /// group shares one Liquid Glass capsule, like a floating toolbar.
    @ToolbarContentBuilder
    private var windowOptions: some ToolbarContent {
        if #available(macOS 26, *) {
            floatingToolbar
        } else {
            windowOptionsGroup
        }
    }

    /// The window's transparent title bar keeps the system from drawing its
    /// own toolbar glass, so each group carries its own glass capsule.
    @available(macOS 26, *)
    @ToolbarContentBuilder
    private var floatingToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 2) {
                ForEach(UsageDetailsMode.allCases, id: \.self) { mode in
                    CompactControlButton(
                        title: mode.title,
                        symbol: mode.symbol,
                        isOn: settings.usageDetailsMode == mode,
                        help: mode.help,
                        large: true,
                        showsSelection: true
                    ) { settings.usageDetailsMode = mode }
                }
            }
            .padding(3)
            .glassEffect(.regular.interactive(), in: Capsule())
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L("View"))
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 2) {
                CompactControlButton(
                    title: L("Keep on Top"),
                    symbol: settings.usageDetailsAlwaysOnTop ? "pin.fill" : "pin",
                    isOn: settings.usageDetailsAlwaysOnTop,
                    help: L("Keep this window above other windows, even when you switch apps."),
                    large: true,
                    showsSelection: true
                ) { settings.usageDetailsAlwaysOnTop.toggle() }
                CompactControlButton(
                    title: L("Show on All Desktops"),
                    symbol: settings.usageDetailsOnAllSpaces
                        ? "rectangle.fill.on.rectangle.fill" : "rectangle.on.rectangle",
                    isOn: settings.usageDetailsOnAllSpaces,
                    help: L("Also show this window on every desktop and over full-screen apps. Requires Keep on Top."),
                    large: true,
                    showsSelection: true
                ) { settings.usageDetailsOnAllSpaces.toggle() }
                .disabled(!settings.usageDetailsAlwaysOnTop)
                BackgroundButton(
                    opacity: $settings.usageDetailsBackgroundOpacity,
                    compact: true,
                    large: true
                )
                CompactControlButton(
                    title: L("Refresh"),
                    symbol: "arrow.clockwise",
                    isOn: false,
                    large: true
                ) { store.refresh(forceRefresh: true) }
            }
            .padding(3)
            .glassEffect(.regular.interactive(), in: Capsule())
            // One toolbar item hosts several buttons; without its own label
            // the item's first label was read for every button.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L("Window Options"))
        }
        .sharedBackgroundVisibility(.hidden)
    }

    private var windowOptionsGroup: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Picker(L("View"), selection: Binding(
                get: { settings.usageDetailsMode },
                set: { settings.usageDetailsMode = $0 }
            )) {
                ForEach(UsageDetailsMode.allCases, id: \.self) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .help(L("View"))

            WindowOptionButton(
                title: L("Keep on Top"),
                help: L("Keep this window above other windows, even when you switch apps."),
                offSymbol: "pin",
                onSymbol: "pin.fill",
                isOn: $settings.usageDetailsAlwaysOnTop
            )

            WindowOptionButton(
                title: L("Show on All Desktops"),
                help: L("Also show this window on every desktop and over full-screen apps. Requires Keep on Top."),
                offSymbol: "rectangle.on.rectangle",
                onSymbol: "rectangle.fill.on.rectangle.fill",
                isOn: $settings.usageDetailsOnAllSpaces
            )
            .disabled(!settings.usageDetailsAlwaysOnTop)

            BackgroundButton(
                opacity: $settings.usageDetailsBackgroundOpacity,
                compact: false
            )

            Button {
                store.refresh(forceRefresh: true)
            } label: {
                Label(L("Refresh"), systemImage: "arrow.clockwise")
            }
            .help(L("Refresh"))
        }
    }

    private var expandedContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ProviderUsageSections(store: store, settings: settings, layout: .window)
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: UsageDetailsContentHeightKey.self, value: proxy.size.height)
                }
            }
        }
        .onPreferenceChange(UsageDetailsContentHeightKey.self) { height in
            guard height > 0, contentHeight != height else { return }
            contentHeight = height
        }
        // The window fits its content (see `windowResizability(.contentSize)`)
        // and scrolls only when the content is taller than the screen allows.
        // Wide enough for two columns of modules and the toolbar.
        .frame(minWidth: 620, idealWidth: 660, maxWidth: .infinity)
        .frame(height: min(contentHeight ?? 500, Self.maxHeight))
    }
}

/// The collapsed Usage Details window: a chrome-free glass panel with one
/// aligned row per limit window (e.g. 5h and weekly) for each provider.
/// Window controls appear while the pointer is over the panel, or always
/// with VoiceOver.
private struct CompactUsageView: View {
    let entries: [CompactUsageEntry]
    /// Account names for providers with several accounts, by provider ID.
    let accountNames: [String: String]
    @ObservedObject var settings: SettingsStore
    let isPointerInside: Bool
    let close: () -> Void
    @State private var isAdjustingOpacity = false
    @State private var labelWidth: CGFloat?
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    private var showsControls: Bool {
        isPointerInside || isAdjustingOpacity || voiceOverEnabled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Rows line up, so all of them get the place column when one has it.
            let showsPriority = entries.contains { $0.priority != nil }
            ForEach(entries) { entry in
                CompactProviderRow(
                    entry: entry,
                    accountName: accountNames[entry.provider.id],
                    settings: settings,
                    showsPriority: showsPriority,
                    labelWidth: labelWidth
                )
            }
        }
        // Size the label column to the widest label so bars sit close to it
        // and stay aligned across rows.
        .onPreferenceChange(CompactLabelWidthKey.self) { width in
            guard width > 0, labelWidth != width else { return }
            labelWidth = width
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .frame(minWidth: 300, alignment: .leading)
        .fixedSize()
        .overlay(alignment: .topTrailing) {
            controls
                .padding(6)
                .opacity(showsControls ? 1 : 0)
                .allowsHitTesting(showsControls)
                .animation(.easeOut(duration: 0.15), value: showsControls)
        }
        // The panel has no title bar, so it sits flush with the window edges.
        .ignoresSafeArea()
    }

    private var controls: some View {
        PanelControls(settings: settings, isAdjustingOpacity: $isAdjustingOpacity, close: close)
    }
}

/// The smallest Usage Details panel: only the menu bar text, e.g.
/// "Cx 50% · Cl 30%", each entry after a dot in its provider's color. While
/// the pointer is over it, or always with VoiceOver, the window controls
/// appear above the text. Dragging anywhere else moves it.
private struct NanoUsageView: View {
    let entries: [MenuBarEntry]
    let accessibilityDescription: String
    @ObservedObject var settings: SettingsStore
    let isPointerInside: Bool
    let close: () -> Void
    @State private var isAdjustingOpacity = false
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    private var showsControls: Bool {
        isPointerInside || isAdjustingOpacity || voiceOverEnabled
    }

    var body: some View {
        // The window keeps its bottom and right edges in place (see
        // `WindowLevelSetter`), so the text stays put and the controls grow
        // the panel upward.
        VStack(alignment: .trailing, spacing: 6) {
            if showsControls {
                controls
            }
            title
        }
        // Room around the text to grab the panel and drag it.
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .fixedSize()
        // The panel has no title bar, so it sits flush with the window edges.
        .ignoresSafeArea()
    }

    private var controls: some View {
        PanelControls(settings: settings, isAdjustingOpacity: $isAdjustingOpacity, close: close)
            .controlSize(.small)
    }

    /// Same text as the menu bar title. Warning and critical entries take
    /// their severity color and symbol; severity is never shown by color alone.
    private var title: some View {
        HStack(spacing: 8) {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                if index > 0 {
                    Text(verbatim: "·").foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                }
                HStack(spacing: 4) {
                    if let providerID = entry.providerID {
                        Circle()
                            .fill(dotColor(for: entry, providerID: providerID))
                            .frame(width: 7, height: 7)
                    }
                    // The provider code stays plain; only the value takes
                    // the severity color, e.g. "Cl" then "18%↗".
                    let parts = Self.split(entry.text, hasProvider: entry.providerID != nil)
                    if let code = parts.code {
                        Text(verbatim: code)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(entry.severity == .stale ? .secondary : .primary)
                    }
                    SeverityValueLabel(
                        text: parts.value,
                        symbolName: entry.severity.symbolName,
                        tint: entry.severity.textColor,
                        plainColor: entry.severity == .stale ? .secondary : .primary,
                        font: .system(size: 12, weight: entry.severity.isEmphasized ? .semibold : .regular).monospacedDigit(),
                        symbolFont: .system(size: 10.5, weight: .semibold)
                    )
                }
                // Entries never truncate; the panel grows to fit them.
                .fixedSize()
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    /// "Cl 18%↗ #1" → code "Cl", value "18%↗ #1". Entries without a
    /// provider (the app name) stay whole.
    static func split(_ text: String, hasProvider: Bool) -> (code: String?, value: String) {
        guard hasProvider, let space = text.firstIndex(of: " ") else { return (nil, text) }
        return (String(text[..<space]), String(text[text.index(after: space)...]))
    }

    private func dotColor(for entry: MenuBarEntry, providerID: String) -> Color {
        switch entry.severity {
        case .warning: Color(nsColor: .systemOrange)
        case .critical: Color(nsColor: .systemRed)
        case .stale: Color.secondary
        case .normal: ProviderBadge.color(for: providerID)
        }
    }
}

/// Hover controls shared by the compact and nano panels.
private struct PanelControls: View {
    @ObservedObject var settings: SettingsStore
    @Binding var isAdjustingOpacity: Bool
    let close: () -> Void
    @Environment(\.controlSize) private var controlSize

    var body: some View {
        let buttons = HStack(spacing: 2) {
            CompactControlButton(title: L("Close"), symbol: "xmark", isOn: false, action: close)
            CompactControlButton(
                title: L("Keep on Top"),
                symbol: settings.usageDetailsAlwaysOnTop ? "pin.fill" : "pin",
                isOn: settings.usageDetailsAlwaysOnTop
            ) { settings.usageDetailsAlwaysOnTop.toggle() }
            CompactControlButton(
                title: L("Show on All Desktops"),
                symbol: settings.usageDetailsOnAllSpaces
                    ? "rectangle.fill.on.rectangle.fill" : "rectangle.on.rectangle",
                isOn: settings.usageDetailsOnAllSpaces
            ) { settings.usageDetailsOnAllSpaces.toggle() }
            .disabled(!settings.usageDetailsAlwaysOnTop)
            BackgroundButton(
                opacity: $settings.usageDetailsBackgroundOpacity,
                compact: true,
                isPresented: $isAdjustingOpacity
            )
            if !settings.usageDetailsNano {
                CompactControlButton(
                    title: L("Nano View"),
                    symbol: UsageDetailsMode.nano.symbol,
                    isOn: false
                ) { settings.usageDetailsMode = .nano }
            }
            CompactControlButton(
                title: L("Expand"),
                symbol: "rectangle.expand.vertical",
                isOn: false
            ) {
                // The nano panel expands one step, to the compact panel.
                settings.usageDetailsMode = settings.usageDetailsNano ? .mini : .full
            }
        }
        .padding(controlSize == .small ? 2 : 3)
        if #available(macOS 26, *) {
            buttons.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            buttons.background(.regularMaterial, in: Capsule())
        }
    }
}

private struct CompactControlButton: View {
    let title: String
    let symbol: String
    let isOn: Bool
    /// Tooltip; defaults to the title.
    var help: String?
    /// Larger symbols for the expanded window's floating toolbar.
    var large = false
    /// Marks the "on" state with a filled capsule behind the symbol.
    var showsSelection = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    /// `.small` in the nano panel.
    @Environment(\.controlSize) private var controlSize

    private var small: Bool { !large && controlSize == .small }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: large ? 14 : small ? 10 : 12, weight: .semibold))
                .frame(width: large ? 32 : small ? 17 : 20, height: large ? 28 : small ? 17 : 20)
                .background {
                    if showsSelection, isOn, isEnabled {
                        Capsule().fill(Color.primary.opacity(0.12))
                    }
                }
                .contentShape(Rectangle())
                .foregroundStyle(isOn && isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .help(help ?? title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct CompactProviderRow: View {
    let entry: CompactUsageEntry
    let accountName: String?
    @ObservedObject var settings: SettingsStore
    let showsPriority: Bool
    let labelWidth: CGFloat?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ProviderBadge(provider: entry.provider, size: 16)
                .padding(.top, 2)
            if showsPriority {
                priorityColumn
            }
            if entry.windows.isEmpty {
                summary
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(entry.windows.enumerated()), id: \.offset) { index, window in
                        CompactWindowMeter(
                            providerName: entry.provider.displayName,
                            accountName: index == 0 ? accountName : nil,
                            window: window,
                            settings: settings,
                            labelWidth: labelWidth
                        )
                    }
                }
            }
        }
    }

    /// The place in CLIProxyAPI's order, e.g. "#1"; blank for rows without one.
    private var priorityColumn: some View {
        ZStack(alignment: .leading) {
            Color.clear
            if let priority = entry.priority {
                Text(verbatim: priority.shortLabel)
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help(priority.explanation)
                    .accessibilityLabel(String(format: L("%@, %@"), entry.provider.displayName, L("CLIProxyAPI order")))
                    .accessibilityValue(priority.phrase)
            }
        }
        .frame(width: 24, height: 20)
    }

    /// Providers without limit windows: their name, then the balance or status.
    private var summary: some View {
        HStack(spacing: 8) {
            Text(accountName ?? entry.provider.displayName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            SeverityValueLabel(
                text: entry.summary,
                symbolName: entry.severity.symbolName,
                tint: entry.severity.textColor,
                plainColor: entry.severity == .stale ? .secondary : .primary
            )
        }
        .frame(maxWidth: .infinity, minHeight: 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.accessibilityLabel)
    }
}

extension MenuBarSeverity {
    var symbolName: String? {
        switch self {
        case .normal: nil
        case .warning: UsageMeterSeverity.warning.symbolName
        case .critical: UsageMeterSeverity.critical.symbolName
        case .stale: "clock"
        }
    }

    var textColor: Color? {
        switch self {
        case .normal, .stale: nil
        case .warning: .warningText
        case .critical: .criticalText
        }
    }

    var isEmphasized: Bool {
        self == .warning || self == .critical
    }
}

private struct CompactWindowMeter: View {
    let providerName: String
    /// Shown before the first limit of an account that shares its provider.
    let accountName: String?
    let window: UsageWindow
    @ObservedObject var settings: SettingsStore
    let labelWidth: CGFloat?

    private static let barWidth: CGFloat = 84

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            meter(at: context.date)
        }
    }

    private func meter(at now: Date) -> some View {
        let severity = UsageMeterSeverity.forUsedPercent(window.usedPercent)
        let countDirection = settings.countDirection
        let pace = settings.showsPace ? window.pace(now: now) : nil
        return HStack(spacing: 8) {
            label
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: CompactLabelWidthKey.self, value: proxy.size.width)
                    }
                }
                .frame(width: labelWidth, alignment: .leading)
            UsageMeterBar(
                percent: countDirection.displayPercent(window.usedPercent),
                severity: severity,
                paceMarkerPercent: settings.showsPace ? countDirection.paceMarkerPercent(for: window, now: now) : nil,
                height: 5
            )
            .frame(width: Self.barWidth)
            // Severity is never shown by color alone.
            SeverityValueLabel(
                text: countDirection.percentLabel(window.usedPercent, menuBar: true),
                symbolName: severity.symbolName,
                tint: severity.textColor,
                font: .meterValue(size: 12)
            )
            .frame(width: 56, alignment: .trailing)
            // Its own column, so rows without a pace stay aligned.
            if settings.showsPace {
                ZStack(alignment: .leading) {
                    Color.clear
                    if let pace {
                        Image(systemName: pace.symbolName)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 10)
            }
            Text(verbatim: window.compactReset(style: settings.resetTimeStyle, prefixed: false, now: now) ?? "")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 44, alignment: .leading)
        }
        .frame(height: 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: L("%@, %@"), providerName, window.label))
        .accessibilityValue(accessibilityValue(severity: severity, pace: pace, now: now))
        .help(tooltip(pace: pace, now: now))
    }

    /// "Main · 5h" on an account's first row, "Week" below it.
    private var label: some View {
        HStack(spacing: 0) {
            if let accountName {
                Text(accountName)
                    .font(.system(size: 12, weight: .semibold))
                    .truncationMode(.middle)
                    .frame(maxWidth: 110, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: " · ").foregroundStyle(.tertiary)
            }
            Text(window.shortLabel)
                .font(.system(size: 12, weight: accountName == nil ? .semibold : .medium))
                .foregroundStyle(accountName == nil ? .primary : .secondary)
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .fixedSize()
    }

    private func tooltip(pace: UsagePace?, now: Date) -> String {
        let parts = [
            window.resetDescription(style: .absolute, now: now),
            pace.map { PaceDescription.tooltip(pace: $0, window: window, direction: settings.countDirection, now: now) },
        ]
        return parts.compactMap { $0 }.joined(separator: "\n")
    }

    private func accessibilityValue(severity: UsageMeterSeverity, pace: UsagePace?, now: Date) -> String {
        var value = settings.countDirection.accessibilityPercentPhrase(window.usedPercent)
        if let reset = window.resetDescription(style: .relative, now: now) {
            value = "\(value), \(reset)"
        }
        if let qualifier = severity.qualifier {
            value = MenuBarAccessibilitySummary.appendQualifier(value, qualifier)
        }
        if let pace {
            value = "\(value), \(pace.phrase)"
        }
        return value
    }
}

private struct CompactLabelWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A plain toolbar button that toggles a window option. Toolbar `Toggle`s draw
/// as filled accent-colored buttons when on; this keeps the standard toolbar
/// look and shows the state through a filled symbol in the primary color instead.
private struct WindowOptionButton: View {
    let title: String
    let help: String
    let offSymbol: String
    let onSymbol: String
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Label(title, systemImage: isOn ? onSymbol : offSymbol)
                .foregroundStyle(isOn && isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
        .help(help)
        .accessibilityValue(isOn ? L("On") : L("Off"))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

extension UsageDetailsView {
    /// Leaves room for the title bar and some margin on the current screen.
    static var maxHeight: CGFloat {
        max(200, (NSScreen.main?.visibleFrame.height ?? 820) - 120)
    }
}

private struct UsageDetailsContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Adjusts the window background opacity. The toolbar and the compact panel's
/// hover controls each show one; content stays opaque as the glass fades.
private struct BackgroundButton: View {
    @Binding var opacity: Double
    let compact: Bool
    var large = false
    var isPresented: Binding<Bool>?
    @State private var localIsPresented = false

    private var presented: Binding<Bool> {
        isPresented ?? $localIsPresented
    }

    private var title: String {
        L("Opacity")
    }

    private var helpText: String {
        L("Adjust how see-through the window background is.")
    }

    var body: some View {
        Group {
            if compact {
                CompactControlButton(
                    title: title,
                    symbol: "circle.lefthalf.filled",
                    isOn: false,
                    help: large ? helpText : nil,
                    large: large
                ) {
                    presented.wrappedValue.toggle()
                }
            } else {
                Button {
                    presented.wrappedValue.toggle()
                } label: {
                    Label(title, systemImage: "circle.lefthalf.filled")
                        .foregroundStyle(.secondary)
                }
                .help(helpText)
            }
        }
        .popover(isPresented: presented, arrowEdge: .bottom) {
            OpacitySlider(opacity: $opacity)
        }
    }
}

private struct OpacitySlider: View {
    @Binding var opacity: Double

    private var percent: String {
        "\(Int((opacity * 100).rounded()))%"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("Background opacity")).font(.callout.weight(.medium))
                Spacer()
                Text(percent).font(.meterValue(size: 12)).foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
            Slider(value: $opacity, in: 0...1, step: 0.05)
                .accessibilityLabel(L("Background opacity"))
                .accessibilityValue(percent)
        }
        .padding(12)
        .frame(width: 220)
    }
}

/// Floats the hosting window above other apps' windows when enabled and, if
/// also requested, shows it on every Space and over full-screen apps.
/// SwiftUI's `windowLevel(_:)` requires macOS 15, so this configures the owning
/// NSWindow through a zero-size probe view.
struct WindowLevelSetter: NSViewRepresentable {
    let alwaysOnTop: Bool
    let onAllSpaces: Bool
    var compact = false
    /// Keeps the window's bottom and right edges in place when its size
    /// changes, so the nano panel grows upward and to the left.
    var anchorsBottomRight = false
    /// Reports whether the pointer is anywhere over the window. SwiftUI's
    /// `onHover` lost the pointer over the compact panel's top strip, which
    /// hid its controls as soon as the pointer reached them.
    var onPointerInsideChange: (Bool) -> Void = { _ in }
    /// Reports the height of the title bar and toolbar the content extends
    /// under. Read from the window, not from SwiftUI's safe area: the safe area
    /// depends on the very padding this height feeds, and while the compact
    /// panel grew right after launch that loop could settle on a wrong value,
    /// leaving a blank strip over clipped content.
    var onTitleBarHeightChange: (CGFloat) -> Void = { _ in }

    func makeNSView(context: Context) -> ProbeView {
        ProbeView()
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onPointerInsideChange = onPointerInsideChange
        nsView.onTitleBarHeightChange = onTitleBarHeightChange
        nsView.alwaysOnTop = alwaysOnTop
        nsView.onAllSpaces = onAllSpaces
        nsView.compact = compact
        nsView.anchorsBottomRight = anchorsBottomRight
    }

    final class ProbeView: NSView {
        static let allSpacesBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        var alwaysOnTop = false {
            didSet { applyLevel() }
        }

        var onAllSpaces = false {
            didSet { applyLevel() }
        }

        var compact = false {
            didSet { applyLevel() }
        }
        var anchorsBottomRight = false
        private var lastFrame: NSRect?
        private var fullSizeContentBeforeCompact: Bool?
        private var dragMonitor: Any?
        private var mouseDownLocation: NSPoint?
        private var isDragging = false
        private var dragEndTimer: Timer?
        private var pointerTrackingArea: NSTrackingArea?
        private weak var pointerTrackingView: NSView?
        var onPointerInsideChange: (Bool) -> Void = { _ in }
        var onTitleBarHeightChange: (CGFloat) -> Void = { _ in }
        private var reportedTitleBarHeight: CGFloat?

        private var chromeObservers: [NSObjectProtocol] = []

        deinit {
            chromeObservers.forEach(NotificationCenter.default.removeObserver)
            if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
            dragEndTimer?.invalidate()
            if let pointerTrackingArea { pointerTrackingView?.removeTrackingArea(pointerTrackingArea) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyLevel()
            observeChromeResets()
            reportTitleBarHeight()
            installPointerTracking()
        }

        /// When the window opens right after launch, SwiftUI can finish
        /// configuring it later and bring the title bar back, leaving the
        /// compact panel with a title bar over clipped content. Restore the
        /// compact chrome whenever it drifts, and keep the reported title bar
        /// height current.
        private func observeChromeResets() {
            chromeObservers.forEach(NotificationCenter.default.removeObserver)
            chromeObservers = []
            guard let window else { return }
            lastFrame = window.frame
            for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
                chromeObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.keepAnchorEdgesIfNeeded()
                        self?.syncPointerInside()
                    }
                })
            }
            for name in [NSWindow.didUpdateNotification, NSWindow.didResizeNotification] {
                chromeObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.restoreCompactChromeIfNeeded()
                        self?.reportTitleBarHeight()
                    }
                })
            }
        }

        /// Content-sized windows resize from their top-left corner; move the
        /// window so its bottom-right corner stays put instead. Growing must not
        /// push the left or top edge off the screen, but a panel the user dragged
        /// past a screen edge stays there instead of bouncing back when the
        /// hover controls show or hide.
        private func keepAnchorEdgesIfNeeded() {
            guard let window else { return }
            let frame = window.frame
            defer { lastFrame = window.frame }
            guard anchorsBottomRight, compact, let old = lastFrame, frame.size != old.size else { return }
            var origin = NSPoint(x: old.maxX - frame.width, y: old.minY)
            if let screen = window.screen?.visibleFrame {
                if old.minX >= screen.minX { origin.x = max(origin.x, screen.minX) }
                if old.maxY <= screen.maxY { origin.y = min(origin.y, screen.maxY - frame.height) }
            }
            guard origin != frame.origin else { return }
            window.setFrameOrigin(origin)
        }

        private func restoreCompactChromeIfNeeded() {
            guard compact, let window else { return }
            let drifted = window.titleVisibility != .hidden
                || !window.titlebarAppearsTransparent
                || !window.styleMask.contains(.fullSizeContentView)
                || window.standardWindowButton(.closeButton)?.isHidden == false
                || titlebarIsAboveContent(in: window)
            if drifted { applyLevel() }
        }

        private func reportTitleBarHeight() {
            guard let window else { return }
            let height = max(0, window.frame.height - window.contentLayoutRect.height)
            guard height != reportedTitleBarHeight else { return }
            reportedTitleBarHeight = height
            // Reported outside the current view update.
            DispatchQueue.main.async { [weak self] in self?.onTitleBarHeightChange(height) }
        }

        private func titlebarIsAboveContent(in window: NSWindow) -> Bool {
            guard let container = window.standardWindowButton(.closeButton)?.superview?.superview,
                  let contentView = window.contentView,
                  let frameView = container.superview,
                  let containerIndex = frameView.subviews.firstIndex(of: container),
                  let contentIndex = frameView.subviews.firstIndex(of: contentView) else { return false }
            return containerIndex > contentIndex
        }

        /// Tracks the whole window frame, title bar included, independent of
        /// which view is under the pointer.
        private func installPointerTracking() {
            if let pointerTrackingArea {
                pointerTrackingView?.removeTrackingArea(pointerTrackingArea)
                self.pointerTrackingArea = nil
            }
            guard let window, let frameView = window.contentView?.superview else { return }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            frameView.addTrackingArea(area)
            pointerTrackingArea = area
            pointerTrackingView = frameView
            let inside = window.frame.contains(NSEvent.mouseLocation)
            DispatchQueue.main.async { [weak self] in self?.onPointerInsideChange(inside) }
        }

        /// Tracking areas only report crossings. When the window shrinks or
        /// moves away from a resting pointer, e.g. after a click on the
        /// expanded window's Nano View button, no exit arrives and the panel
        /// kept sizing itself for hover controls it never drew.
        private func syncPointerInside() {
            guard let window, !isDragging else { return }
            let inside = window.frame.contains(NSEvent.mouseLocation)
            DispatchQueue.main.async { [weak self] in self?.onPointerInsideChange(inside) }
        }

        override func mouseEntered(with event: NSEvent) {
            onPointerInsideChange(true)
        }

        override func mouseExited(with event: NSEvent) {
            // A fast drag can outrun the window for a moment; hiding the
            // controls then would resize the panel mid-drag.
            guard !isDragging else { return }
            onPointerInsideChange(false)
        }

        private func applyLevel() {
            guard let window else { return }
            window.level = alwaysOnTop ? .floating : .normal
            // Let the window's material show through the title bar, and let a
            // faded material show what is behind the window.
            window.titlebarAppearsTransparent = true
            window.isOpaque = false
            window.backgroundColor = .clear
            applyCompactChrome(to: window)
            orderTitlebar(of: window)
            // Over full-screen apps the window must also float, so all-Spaces
            // behavior only applies together with always-on-top.
            if alwaysOnTop && onAllSpaces {
                // canJoinAllSpaces and moveToActiveSpace are mutually exclusive.
                window.collectionBehavior.remove(.moveToActiveSpace)
                window.collectionBehavior.formUnion(Self.allSpacesBehavior)
            } else {
                window.collectionBehavior.subtract(Self.allSpacesBehavior)
            }
        }

        /// SwiftUI content swallows clicks, so isMovableByWindowBackground only
        /// works over the reserved title bar strip, and an inactive window's
        /// first click never reaches SwiftUI gestures. While compact, any drag
        /// inside the window moves it, even when another app is active.
        /// Each drag starts one window server drag, like a title bar drag, so
        /// the window follows the pointer past screen edges. Moving the window
        /// from code instead gets it pushed back on screen mid-drag. Starting a
        /// new drag on every event lagged behind fast drags, and the controls
        /// stay shown until the button is released so the panel never resizes
        /// under the pointer.
        private func updateDragMonitor() {
            if compact, dragMonitor == nil {
                dragMonitor = NSEvent.addLocalMonitorForEvents(
                    matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
                ) { [weak self] event in
                    guard let self, let window, event.window === window else { return event }
                    switch event.type {
                    case .leftMouseDown:
                        mouseDownLocation = event.locationInWindow
                        return event
                    case .leftMouseDragged:
                        guard !isDragging else { return nil }
                        // Small pointer jitter during a click must not start
                        // a drag, or the click never reaches the panel's buttons.
                        if let start = mouseDownLocation {
                            let distance = hypot(event.locationInWindow.x - start.x,
                                                 event.locationInWindow.y - start.y)
                            guard distance >= 3 else { return event }
                        }
                        beginDrag(of: window, with: event)
                        return nil
                    default:
                        // A drag's mouse-up must not click the button it began on.
                        guard isDragging else { return event }
                        endDrag()
                        return nil
                    }
                }
            } else if !compact, let monitor = dragMonitor {
                NSEvent.removeMonitor(monitor)
                dragMonitor = nil
            }
        }

        private func beginDrag(of window: NSWindow, with event: NSEvent) {
            isDragging = true
            window.performDrag(with: event)
            // The window server keeps the drag's mouse-up, so watch the button.
            dragEndTimer?.invalidate()
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
                MainActor.assumeIsolated { self?.endDrag() }
            }
            RunLoop.main.add(timer, forMode: .common)
            dragEndTimer = timer
        }

        private func endDrag() {
            guard isDragging else { return }
            isDragging = false
            dragEndTimer?.invalidate()
            dragEndTimer = nil
            mouseDownLocation = nil
            onPointerInsideChange(window?.frame.contains(NSEvent.mouseLocation) ?? false)
        }

        /// The full-size SwiftUI content can end up ordered above the title
        /// bar, where its material hides the title, window buttons and toolbar.
        /// Keep the title bar in front of the content in the expanded window,
        /// and behind it in the compact panel, which draws its own controls.
        private func orderTitlebar(of window: NSWindow) {
            let compact = compact
            DispatchQueue.main.async {
                guard let container = window.standardWindowButton(.closeButton)?.superview?.superview,
                      let contentView = window.contentView,
                      let frameView = container.superview,
                      contentView.superview === frameView,
                      let containerIndex = frameView.subviews.firstIndex(of: container),
                      let contentIndex = frameView.subviews.firstIndex(of: contentView) else { return }
                if compact, containerIndex > contentIndex {
                    frameView.addSubview(container, positioned: .below, relativeTo: contentView)
                } else if !compact, containerIndex < contentIndex {
                    frameView.addSubview(container, positioned: .above, relativeTo: contentView)
                }
            }
        }

        /// The compact panel has no visible title bar: content fills the whole
        /// window, the window buttons are hidden, and it drags by its background.
        private func applyCompactChrome(to window: NSWindow) {
            window.titleVisibility = compact ? .hidden : .visible
            window.isMovableByWindowBackground = compact
            updateDragMonitor()
            for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(kind)?.isHidden = compact
            }
            if compact {
                if fullSizeContentBeforeCompact == nil {
                    fullSizeContentBeforeCompact = window.styleMask.contains(.fullSizeContentView)
                }
                window.styleMask.insert(.fullSizeContentView)
            } else if let wasFullSize = fullSizeContentBeforeCompact {
                if !wasFullSize { window.styleMask.remove(.fullSizeContentView) }
                fullSizeContentBeforeCompact = nil
            }
        }
    }
}
