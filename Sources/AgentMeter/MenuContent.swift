import AppKit
import SwiftUI

struct MenuContent: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: SettingsStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL
    @State private var menuScreenVisibleHeight: CGFloat?
    @State private var providerContentHeight: CGFloat?
    @State private var providerContentBottom: CGFloat = 0
    /// Whether the Usage Details window is on screen; only then does the
    /// footer's view switcher highlight its view.
    @State private var usageDetailsIsOpen = false

    private let tipJarURL = URL(string: "https://www.buymeacoffee.com/gilitos92")!


    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            usageView
        }
        .padding(GlassStyle.inset)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GeometryReader { proxy in
                MenuWindowScreenReader(contentSize: proxy.size) { height in
                    DispatchQueue.main.async {
                        guard menuScreenVisibleHeight != height else { return }
                        menuScreenVisibleHeight = height
                    }
                }
            }
        }
    }

    private var usageView: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: GlassStyle.inset) {
                    ProviderUsageSections(store: store, settings: settings, layout: .dropdown)
                }
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ProviderContentHeightKey.self,
                            value: proxy.size.height
                        )
                        .preference(
                            key: ProviderContentBottomKey.self,
                            value: proxy.frame(in: .named("providerViewport")).maxY
                        )
                    }
                }
            }
            .scrollIndicators(.automatic)
            .frame(height: providerViewportHeight, alignment: .top)
            .clipShape(RoundedRectangle(cornerRadius: GlassStyle.platterRadius, style: .continuous))
            .coordinateSpace(name: "providerViewport")
            .onPreferenceChange(ProviderContentHeightKey.self) { height in
                guard providerContentHeight != height else { return }
                providerContentHeight = height
            }
            .onPreferenceChange(ProviderContentBottomKey.self) { bottom in
                providerContentBottom = bottom
            }
            .overlay(alignment: .bottom) {
                if providerContentBottom > providerViewportHeight + 1 {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(.regularMaterial))
                        .overlay(Circle().strokeBorder(Color.platterEdge, lineWidth: 0.5))
                        .padding(.bottom, 6)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            footer
        }
    }

    private var providerViewportHeight: CGFloat {
        // Keep the footer reachable while leaving a little room for the
        // menu's outer padding and title-bar/menu-bar overlap. The fallback
        // covers the first layout pass, before the popup has an owning window.
        let screenHeight = menuScreenVisibleHeight ?? 820
        let maxHeight = max(1, min(680, screenHeight - 150))
        guard let providerContentHeight else { return 1 }
        return min(providerContentHeight, maxHeight)
    }

    /// The refresh time, the Usage Details views and round buttons. Less
    /// frequent commands live in the More menu, so nothing wraps.
    private var footer: some View {
        HStack(spacing: 6) {
            // Two short lines, so the time stays whole next to the buttons.
            Group {
                if let refreshed = store.lastRefreshed {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(L("Updated"))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.tertiary)
                        Text(refreshed.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L("Updated \(refreshed.formatted(date: .omitted, time: .shortened))"))
                } else {
                    Text(L("Loading…"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            Spacer(minLength: 4)
            Button {
                store.refresh(forceRefresh: true)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(L("Refresh"))
            .accessibilityLabel(L("Refresh"))
            ViewModeButtons(
                current: settings.usageDetailsMode,
                highlightsCurrent: usageDetailsIsOpen
            ) { mode in
                settings.usageDetailsMode = mode
                openUsageDetails()
            }
            // The dropdown's window becomes key each time it opens, and the
            // Usage Details window can close while the dropdown is open.
            .onAppear(perform: refreshUsageDetailsState)
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                refreshUsageDetailsState()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
                // The closing window is still visible during this notification.
                DispatchQueue.main.async(execute: refreshUsageDetailsState)
            }
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .help(L("Settings…"))
            .accessibilityLabel(L("Settings…"))
            .simultaneousGesture(TapGesture().onEnded {
                NSApp.activate(ignoringOtherApps: true)
                Self.closeMenuBarWindow()
            })
            Button {
                Self.closeMenuBarWindow()
                openURL(tipJarURL)
            } label: {
                Image(systemName: "heart")
            }
            .help(L("Support Allowance Bar"))
            .accessibilityLabel(L("Support Allowance Bar"))
            moreMenu
        }
        .buttonStyle(CircleIconButtonStyle())
        .padding(.top, GlassStyle.inset)
        .padding(.horizontal, 4)
    }

    private var moreMenu: some View {
        Menu {
            Button(L("Check for Updates…")) {
                Self.closeMenuBarWindow()
                Updater.shared.checkForUpdates()
            }
            Button(L("About Allowance Bar")) {
                Self.closeMenuBarWindow()
                openWindow(id: "about")
                NSApp.activate(ignoringOtherApps: true)
            }
            Divider()
            Button(L("Quit")) { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: [.command])
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("More"))
        .accessibilityLabel(L("More"))
    }

    private func refreshUsageDetailsState() {
        usageDetailsIsOpen = NSApp.windows.contains { window in
            // SwiftUI names the window after its scene ID.
            window.isVisible && (window.identifier?.rawValue.contains("usage-details") ?? false)
        }
    }

    private func openUsageDetails() {
        Self.closeMenuBarWindow()
        openWindow(id: "usage-details")
        NSApp.activate(ignoringOtherApps: true)
    }

    /// MenuBarExtra's window doesn't auto-dismiss when another window opens;
    /// close it explicitly so Settings doesn't appear behind the dropdown.
    private static func closeMenuBarWindow() {
        for window in NSApp.windows where window.className.contains("MenuBarExtraWindow") {
            window.close()
        }
    }
}

private struct ProviderContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ProviderContentBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Reports the visible height of the display that owns MenuBarExtra's popup.
/// The popup window is created after the initial SwiftUI layout, so this is a
/// zero-size probe rather than a GeometryReader that could participate in a
/// layout feedback loop.
private struct MenuWindowScreenReader: NSViewRepresentable {
    let contentSize: CGSize
    let onVisibleHeightChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScreenProbeView {
        ScreenProbeView(onVisibleHeightChange: onVisibleHeightChange)
    }

    func updateNSView(_ nsView: ScreenProbeView, context: Context) {
        nsView.onVisibleHeightChange = onVisibleHeightChange
        nsView.contentSize = contentSize
        nsView.scheduleContentResize()
    }

    final class ScreenProbeView: NSView {
        var onVisibleHeightChange: (CGFloat) -> Void
        private weak var observedWindow: NSWindow?
        private var lastReportedHeight: CGFloat?
        var contentSize: CGSize = .zero
        private var resizeScheduled = false

        // MenuBarExtra can retain its first layout's native window height even
        // after SwiftUI has measured and contracted the provider list.
        func scheduleContentResize() {
            guard !resizeScheduled else { return }
            resizeScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.resizeScheduled = false
                guard let window = self.window,
                      window.className.contains("MenuBarExtraWindow"),
                      self.contentSize.width > 0, self.contentSize.height > 0 else { return }
                let size = NSSize(width: ceil(self.contentSize.width),
                                  height: ceil(self.contentSize.height))
                let current = window.contentRect(forFrameRect: window.frame).size
                guard abs(current.height - size.height) > 1 ||
                      abs(current.width - size.width) > 1 else { return }
                let top = window.frame.maxY
                window.contentMinSize = size
                window.contentMaxSize = size
                window.setContentSize(size)
                window.setFrameOrigin(NSPoint(x: window.frame.minX,
                                              y: top - window.frame.height))
            }
        }

        init(onVisibleHeightChange: @escaping (CGFloat) -> Void) {
            self.onVisibleHeightChange = onVisibleHeightChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if observedWindow !== window {
                removeObservers()
                observedWindow = window
                if let window {
                    NotificationCenter.default.addObserver(
                        self,
                        selector: #selector(windowScreenChanged),
                        name: NSWindow.didChangeScreenNotification,
                        object: window
                    )
                }
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(windowScreenChanged),
                    name: NSApplication.didChangeScreenParametersNotification,
                    object: nil
                )
            }
            reportVisibleHeight()
            scheduleContentResize()
        }

        deinit {
            removeObservers()
        }

        @objc private func windowScreenChanged() {
            reportVisibleHeight()
        }

        func reportVisibleHeight() {
            guard let height = window?.screen?.visibleFrame.height else { return }
            guard lastReportedHeight != height else { return }
            lastReportedHeight = height
            onVisibleHeightChange(height)
        }

        private func removeObservers() {
            NotificationCenter.default.removeObserver(self)
            observedWindow = nil
        }
    }
}

/// The Usage Details window's three views on one capsule, like the window's
/// own view switcher. Each opens the window in that view, and ⌘D opens the
/// current one. The current view is highlighted while the window is open.
private struct ViewModeButtons: View {
    let current: UsageDetailsMode
    let highlightsCurrent: Bool
    let open: (UsageDetailsMode) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(UsageDetailsMode.allCases, id: \.self) { mode in
                let button = Button { open(mode) } label: {
                    Image(systemName: mode.symbol)
                }
                .buttonStyle(ViewModeButtonStyle(isSelected: highlightsCurrent && mode == current))
                .help(mode.help)
                .accessibilityLabel(mode.title)
                .accessibilityAddTraits(highlightsCurrent && mode == current ? .isSelected : [])
                if mode == current {
                    button.keyboardShortcut("d", modifiers: [.command])
                } else {
                    button
                }
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.platterFill))
        .overlay(Capsule().strokeBorder(Color.platterEdge, lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Usage Details"))
    }
}

private struct ViewModeButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        ViewModeButtonBody(configuration: configuration, isSelected: isSelected)
    }
}

private struct ViewModeButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .frame(width: 30, height: 26)
            .background(Capsule().fill(fill))
            .contentShape(Capsule())
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var fill: Color {
        if configuration.isPressed { return Color.primary.opacity(0.18) }
        if isSelected { return Color.primary.opacity(0.13) }
        if isHovering { return Color.primary.opacity(0.08) }
        return .clear
    }
}
