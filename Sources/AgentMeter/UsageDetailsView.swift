import AppKit
import SwiftUI

struct UsageDetailsView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: SettingsStore
    @State private var contentHeight: CGFloat?
    @State private var titleBarInset: CGFloat = 0
    @State private var isPointerInside = false
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if settings.usageDetailsNano {
                NanoUsageView(
                    entries: store.nanoEntries,
                    accessibilityDescription: store.nanoAccessibilityDescription,
                    settings: settings,
                    isPointerInside: isPointerInside,
                    close: { dismissWindow(id: "usage-details") }
                )
                .padding(.bottom, -titleBarInset)
            } else if settings.usageDetailsCompact {
                CompactUsageView(
                    entries: store.compactEntries,
                    settings: settings,
                    isPointerInside: isPointerInside,
                    close: { dismissWindow(id: "usage-details") }
                )
                // Give back the title bar space reserved while compact so
                // the window hugs its rows.
                .padding(.bottom, -titleBarInset)
            } else {
                expandedContent
            }
        }
        // Standard material provides a stable window capture appearance.
        // Only the background extends under the expanded window's title bar;
        // its content stays in the normal safe area.
        .background(MenuMaterialBackground(opacity: settings.usageDetailsBackgroundOpacity).ignoresSafeArea())
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
    }

    /// The window option buttons. On macOS 26 and later they share one Liquid
    /// Glass background, like a floating toolbar.
    @ToolbarContentBuilder
    private var windowOptions: some ToolbarContent {
        if #available(macOS 26, *) {
            floatingToolbar
        } else {
            windowOptionsGroup
        }
    }

    /// The window's transparent title bar keeps the system from drawing its
    /// own toolbar glass, so the buttons carry their own glass capsule.
    @available(macOS 26, *)
    private var floatingToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 2) {
                CompactControlButton(
                    title: L("Keep on Top"),
                    symbol: settings.usageDetailsAlwaysOnTop ? "pin.fill" : "pin",
                    isOn: settings.usageDetailsAlwaysOnTop,
                    help: L("Keep this window above other windows, even when you switch apps."),
                    large: true
                ) { settings.usageDetailsAlwaysOnTop.toggle() }
                CompactControlButton(
                    title: L("Show on All Desktops"),
                    symbol: settings.usageDetailsOnAllSpaces
                        ? "rectangle.fill.on.rectangle.fill" : "rectangle.on.rectangle",
                    isOn: settings.usageDetailsOnAllSpaces,
                    help: L("Also show this window on every desktop and over full-screen apps. Requires Keep on Top."),
                    large: true
                ) { settings.usageDetailsOnAllSpaces.toggle() }
                .disabled(!settings.usageDetailsAlwaysOnTop)
                BackgroundButton(
                    opacity: $settings.usageDetailsBackgroundOpacity,
                    compact: true,
                    large: true
                )
                CompactControlButton(
                    title: L("Compact View"),
                    symbol: "rectangle.compress.vertical",
                    isOn: false,
                    help: L("Collapse into a small panel with each provider's limits."),
                    large: true
                ) { settings.usageDetailsCompact = true }
                CompactControlButton(
                    title: L("Nano View"),
                    symbol: "arrow.down.right.and.arrow.up.left",
                    isOn: false,
                    help: L("Shrink into a tiny panel with only the menu bar text."),
                    large: true
                ) { settings.usageDetailsNano = true }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .glassEffect(.regular.interactive(), in: Capsule())
            // One toolbar item hosts all five buttons; without its own label
            // the item's first label ("Keep on Top") was read for every button.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L("Window Options"))
        }
        .sharedBackgroundVisibility(.hidden)
    }

    private var windowOptionsGroup: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
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

            WindowOptionButton(
                title: L("Compact View"),
                help: L("Collapse into a small panel with each provider's limits."),
                offSymbol: "rectangle.compress.vertical",
                onSymbol: "rectangle.compress.vertical",
                isOn: $settings.usageDetailsCompact
            )

            WindowOptionButton(
                title: L("Nano View"),
                help: L("Shrink into a tiny panel with only the menu bar text."),
                offSymbol: "arrow.down.right.and.arrow.up.left",
                onSymbol: "arrow.down.right.and.arrow.up.left",
                isOn: $settings.usageDetailsNano
            )
        }
    }

    private var expandedContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ProviderUsageSections(store: store, settings: settings)
            }
            .padding(14)
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
        // Wide enough for the title and all toolbar buttons without overflow.
        .frame(minWidth: 480, idealWidth: 480, maxWidth: .infinity)
        .frame(height: min(contentHeight ?? 500, Self.maxHeight))
    }
}

/// The collapsed Usage Details window: a chrome-free panel with one row per
/// limit window (e.g. 5h and weekly) for each provider. Window controls appear
/// while the pointer is over the panel, or always with VoiceOver.
private struct CompactUsageView: View {
    let entries: [CompactUsageEntry]
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
        VStack(alignment: .leading, spacing: 8) {
            ForEach(entries) { entry in
                CompactProviderRow(entry: entry, countDirection: settings.countDirection, labelWidth: labelWidth)
            }
        }
        // Size the label column to the widest label so bars sit close to it
        // and stay aligned across rows.
        .onPreferenceChange(CompactLabelWidthKey.self) { width in
            guard width > 0, labelWidth != width else { return }
            labelWidth = width
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
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
/// "Cx 50% · Cl 30%". While the pointer is over it, or always with VoiceOver,
/// the window controls appear above the text. Dragging anywhere else moves it.
private struct NanoUsageView: View {
    let entries: [(text: String, severity: MenuBarSeverity)]
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
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .fixedSize()
        // The panel has no title bar, so it sits flush with the window edges.
        .ignoresSafeArea()
    }

    private var controls: some View {
        PanelControls(settings: settings, isAdjustingOpacity: $isAdjustingOpacity, close: close)
            .controlSize(.small)
    }

    /// Same text and colors as the menu bar title. Severity is never shown by
    /// color alone, so warning, critical and stale entries also get a symbol.
    private var title: some View {
        entries.enumerated().reduce(Text(verbatim: "")) { text, item in
            let (index, entry) = item
            let color = Color(nsColor: MenuBarTitleRenderer.nsColor(for: entry.severity))
            var result = text
            if index > 0 {
                result = result + Text(verbatim: " · ").foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            }
            result = result + Text(verbatim: entry.text).foregroundStyle(color)
            if let symbol = entry.severity.symbolName {
                result = result + Text(verbatim: " ") + Text(Image(systemName: symbol)).foregroundStyle(color)
            }
            return result
        }
        .font(.system(size: 12).monospacedDigit())
        .lineLimit(1)
        .padding(.horizontal, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }
}

/// Hover controls shared by the compact and nano panels.
private struct PanelControls: View {
    @ObservedObject var settings: SettingsStore
    @Binding var isAdjustingOpacity: Bool
    let close: () -> Void
    @Environment(\.controlSize) private var controlSize

    var body: some View {
        HStack(spacing: 2) {
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
                    symbol: "arrow.down.right.and.arrow.up.left",
                    isOn: false
                ) { settings.usageDetailsNano = true }
            }
            CompactControlButton(
                title: L("Expand"),
                symbol: "rectangle.expand.vertical",
                isOn: false
            ) {
                // The nano panel expands one step, to the compact panel.
                if settings.usageDetailsNano {
                    settings.usageDetailsCompact = true
                    settings.usageDetailsNano = false
                } else {
                    settings.usageDetailsCompact = false
                }
            }
        }
        .padding(controlSize == .small ? 2 : 3)
        .background(.regularMaterial, in: Capsule())
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
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    /// `.small` in the nano panel.
    @Environment(\.controlSize) private var controlSize

    private var small: Bool { !large && controlSize == .small }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: large ? 15 : small ? 10 : 12, weight: .semibold))
                .frame(width: large ? 30 : small ? 17 : 20, height: large ? 28 : small ? 17 : 20)
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
    let countDirection: CountDirection
    let labelWidth: CGFloat?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ProviderBadge(provider: entry.provider, size: 18)
            if entry.windows.isEmpty {
                summary
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(entry.windows.enumerated()), id: \.offset) { _, window in
                        CompactWindowMeter(
                            providerName: entry.provider.displayName,
                            window: window,
                            countDirection: countDirection,
                            labelWidth: labelWidth
                        )
                    }
                }
            }
        }
    }

    private var summary: some View {
        let color = Color(nsColor: MenuBarTitleRenderer.nsColor(for: entry.severity))
        return HStack(spacing: 4) {
            Text(entry.summary)
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
            if let symbol = entry.severity.symbolName {
                Image(systemName: symbol).font(.subheadline.weight(.medium)).foregroundStyle(color)
            }
        }
        .frame(height: 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.accessibilityLabel)
    }

}

private extension MenuBarSeverity {
    var symbolName: String? {
        switch self {
        case .normal: nil
        case .warning: UsageMeterSeverity.warning.symbolName
        case .critical: UsageMeterSeverity.critical.symbolName
        case .stale: "clock"
        }
    }
}

private struct CompactWindowMeter: View {
    let providerName: String
    let window: UsageWindow
    let countDirection: CountDirection
    let labelWidth: CGFloat?

    private static let barWidth: CGFloat = 80

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            meter(at: context.date)
        }
    }

    private func meter(at now: Date) -> some View {
        let severity = UsageMeterSeverity.forUsedPercent(window.usedPercent)
        return HStack(spacing: 8) {
            HStack(spacing: 5) {
                Text(window.label)
                    .foregroundStyle(.secondary)
                if let remaining = window.shortRemainingDescription(now: now) {
                    Text(verbatim: "(\(remaining))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .fixedSize()
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: CompactLabelWidthKey.self, value: proxy.size.width)
                }
            }
            .frame(width: labelWidth, alignment: .leading)
            UsageMeterBar(percent: countDirection.displayPercent(window.usedPercent), severity: severity)
                .frame(width: Self.barWidth)
            HStack(spacing: 3) {
                Text(countDirection.percentLabel(window.usedPercent, menuBar: true))
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(severity.color)
                // Severity is never shown by color alone.
                if let symbol = severity.symbolName {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(severity.color)
                }
            }
            .frame(width: 60, alignment: .trailing)
        }
        .frame(height: 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: L("%@, %@"), providerName, window.label))
        .accessibilityValue(accessibilityValue(severity: severity, now: now))
    }

    private func accessibilityValue(severity: UsageMeterSeverity, now: Date) -> String {
        var value = countDirection.accessibilityPercentPhrase(window.usedPercent)
        if let reset = window.resetDescription(style: .relative, now: now) {
            value = "\(value), \(reset)"
        }
        guard let qualifier = severity.qualifier else { return value }
        return MenuBarAccessibilitySummary.appendQualifier(value, qualifier)
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
/// hover controls each show one; content stays opaque as the material fades.
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
                Text(percent).font(.callout.monospacedDigit().weight(.semibold)).foregroundStyle(.secondary)
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

/// The translucent material of the menu bar dropdown, kept active while the
/// app is in the background so a floating window keeps the same look. Its
/// opacity is adjustable; content drawn on top stays fully opaque.
private struct MenuMaterialBackground: NSViewRepresentable {
    let opacity: Double

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        view.alphaValue = opacity
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.alphaValue = opacity
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
        /// Pointer and window origin, in screen coordinates, when a drag began.
        private var dragStart: (pointer: NSPoint, origin: NSPoint)?
        private var pointerTrackingArea: NSTrackingArea?
        private weak var pointerTrackingView: NSView?
        var onPointerInsideChange: (Bool) -> Void = { _ in }
        var onTitleBarHeightChange: (CGFloat) -> Void = { _ in }
        private var reportedTitleBarHeight: CGFloat?

        private var chromeObservers: [NSObjectProtocol] = []

        deinit {
            chromeObservers.forEach(NotificationCenter.default.removeObserver)
            if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
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
                    MainActor.assumeIsolated { self?.keepAnchorEdgesIfNeeded() }
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
        /// window so its bottom-right corner stays put instead, within the screen.
        private func keepAnchorEdgesIfNeeded() {
            guard let window else { return }
            let frame = window.frame
            defer { lastFrame = window.frame }
            guard anchorsBottomRight, compact, let old = lastFrame, frame.size != old.size else { return }
            var origin = NSPoint(x: old.maxX - frame.width, y: old.minY)
            if let screen = window.screen?.visibleFrame {
                origin.x = min(max(origin.x, screen.minX), screen.maxX - frame.width)
                origin.y = min(max(origin.y, screen.minY), screen.maxY - frame.height)
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

        override func mouseEntered(with event: NSEvent) {
            onPointerInsideChange(true)
        }

        override func mouseExited(with event: NSEvent) {
            // A fast drag can outrun the window for a moment; hiding the
            // controls then would resize the panel mid-drag.
            guard dragStart == nil else { return }
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
        /// The window follows the pointer directly rather than through
        /// `performDrag`, which lagged behind fast drags: the pointer left the
        /// window, the nano panel hid its controls and resized mid-drag, and
        /// the window jumped away from the pointer.
        private func updateDragMonitor() {
            if compact, dragMonitor == nil {
                dragMonitor = NSEvent.addLocalMonitorForEvents(
                    matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
                ) { [weak self] event in
                    guard let self, let window, event.window === window else { return event }
                    switch event.type {
                    case .leftMouseDown:
                        mouseDownLocation = event.locationInWindow
                        dragStart = nil
                        return event
                    case .leftMouseDragged:
                        if dragStart == nil {
                            // Small pointer jitter during a click must not start
                            // a drag, or the click never reaches the panel's buttons.
                            if let start = mouseDownLocation {
                                let distance = hypot(event.locationInWindow.x - start.x,
                                                     event.locationInWindow.y - start.y)
                                guard distance >= 3 else { return event }
                            }
                            dragStart = (NSEvent.mouseLocation, window.frame.origin)
                        }
                        guard let start = dragStart else { return event }
                        let pointer = NSEvent.mouseLocation
                        window.setFrameOrigin(NSPoint(x: start.origin.x + pointer.x - start.pointer.x,
                                                      y: start.origin.y + pointer.y - start.pointer.y))
                        return nil
                    default:
                        // A drag's mouse-up must not click the button it began on.
                        guard dragStart != nil else { return event }
                        dragStart = nil
                        onPointerInsideChange(window.frame.contains(NSEvent.mouseLocation))
                        return nil
                    }
                }
            } else if !compact, let monitor = dragMonitor {
                NSEvent.removeMonitor(monitor)
                dragMonitor = nil
            }
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
