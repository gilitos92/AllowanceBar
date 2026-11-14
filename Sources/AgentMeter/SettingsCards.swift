import SwiftUI

// Settings draw their own cards instead of the grouped form, so they share
// the dropdown's rounder platters and macOS's capsule controls.

/// A scrolling settings pane.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            SettingsColumn { content }
        }
    }
}

/// The column of a settings pane or sheet, without scrolling, so a sheet
/// fits its content.
struct SettingsColumn<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            content
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .labeledContentStyle(SettingsRowStyle())
        .toggleStyle(SettingsSwitchStyle())
        .buttonBorderShape(.capsule)
    }
}

/// An optional title, a card of rows, and an optional note under it.
struct SettingsGroup<Content: View, Footer: View>: View {
    var title: String?
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                    .accessibilityAddTraits(.isHeader)
            }
            SettingsCard { content }
            footer
        }
    }
}

extension SettingsGroup where Footer == EmptyView {
    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, content: content, footer: { EmptyView() })
    }
}

/// A short secondary note under a card.
struct SettingsNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

/// A rounded card. Each view inside is a row, with a separator between rows.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    private static var radius: CGFloat { 12 }

    var body: some View {
        rows
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(Color.settingsCardFill))
            .overlay(shape.strokeBorder(Color.settingsCardEdge, lineWidth: 0.5))
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
    }

    @ViewBuilder
    private var rows: some View {
        if #available(macOS 15, *) {
            Group(subviews: content) { subviews in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(subviews) { subview in
                        if subview.id != subviews.first?.id {
                            Divider().padding(.leading, 14)
                        }
                        subview.modifier(SettingsRowPadding())
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Group { content }.modifier(SettingsRowPadding())
            }
        }
    }
}

private struct SettingsRowPadding: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
    }
}

/// A label on the leading edge and its control or value on the trailing edge.
struct SettingsRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 12) {
            configuration.label
            Spacer(minLength: 0)
            configuration.content
        }
    }
}

/// A switch on the trailing edge of a full-width row.
struct SettingsSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

extension View {
    /// Puts a control on the trailing edge of a row titled `title`. The
    /// control keeps the title as its spoken label.
    func settingsRow(_ title: String) -> some View {
        LabeledContent {
            labelsHidden()
        } label: {
            Text(title)
        }
    }

    /// A segmented control in the capsule shape of large controls.
    func settingsSegmented() -> some View {
        pickerStyle(.segmented)
            .controlSize(.large)
            .fixedSize()
    }
}

extension Color {
    /// Settings windows are white in light mode, so cards are a faint gray
    /// there, like the system's grouped forms, and a faint lift in dark mode.
    static let settingsCardFill = adaptive(
        light: NSColor(white: 0, alpha: 0.035),
        dark: NSColor(white: 1, alpha: 0.07)
    )
    static let settingsCardEdge = adaptive(
        light: NSColor(white: 0, alpha: 0.06),
        dark: NSColor(white: 1, alpha: 0.06)
    )
}
