import AppKit
import SwiftUI

/// Shared look of the "Glass Modules" design: Liquid Glass only on the
/// floating layer (the dropdown, the panels and their controls), and the
/// usage itself on quiet platters that sit on that glass.
enum GlassStyle {
    /// Gap between a surface's edge and its platters, and between platters.
    static let inset: CGFloat = 8
    /// Corner radius of a platter: the surface's radius minus the inset,
    /// so platter and surface corners stay concentric.
    static let platterRadius: CGFloat = 12
}

extension Color {
    /// A color with separate light and dark appearance values.
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    /// Platter fill: a soft white lift in light mode, a faint lift in dark mode.
    static let platterFill = adaptive(
        light: NSColor(white: 1, alpha: 0.6),
        dark: NSColor(white: 1, alpha: 0.07)
    )
    static let platterEdge = adaptive(
        light: NSColor(white: 0, alpha: 0.05),
        dark: NSColor(white: 1, alpha: 0.06)
    )
    /// Fill of chips such as the plan name.
    static let chipFill = adaptive(
        light: NSColor(white: 0, alpha: 0.06),
        dark: NSColor(white: 1, alpha: 0.10)
    )
    /// Track behind a meter's fill.
    static let meterTrack = adaptive(
        light: NSColor(srgbRed: 120 / 255, green: 120 / 255, blue: 128 / 255, alpha: 0.2),
        dark: NSColor(srgbRed: 120 / 255, green: 120 / 255, blue: 128 / 255, alpha: 0.36)
    )
    /// Fill of a healthy meter: the label color, softened so a healthy limit
    /// stays quieter than a warning.
    static let meterNormal = adaptive(
        light: NSColor(white: 0.11, alpha: 0.78),
        dark: NSColor(white: 0.96, alpha: 0.82)
    )
    /// Warning and critical text. Light mode uses darker shades of orange
    /// and red (about 4.5:1 on white), so small text stays readable on light
    /// platters and the two severities stay apart.
    static let warningText = adaptive(
        light: NSColor(srgbRed: 0xC2 / 255, green: 0x57 / 255, blue: 0x00 / 255, alpha: 1),
        dark: NSColor(srgbRed: 0xFF / 255, green: 0x9F / 255, blue: 0x0A / 255, alpha: 1)
    )
    static let criticalText = adaptive(
        light: NSColor(srgbRed: 0xD7 / 255, green: 0x00 / 255, blue: 0x15 / 255, alpha: 1),
        dark: NSColor(srgbRed: 0xFF / 255, green: 0x45 / 255, blue: 0x3A / 255, alpha: 1)
    )
}

extension Font {
    /// Numbers: SF Pro Rounded with fixed-width digits, so values don't
    /// shift sideways when they update.
    static func meterValue(size: CGFloat = 12.5, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}

/// A rounded platter that groups one provider's usage.
struct PlatterModifier: ViewModifier {
    var padding = EdgeInsets(top: 11, leading: 12, bottom: 12, trailing: 12)

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(platterShape.fill(Color.platterFill))
            .overlay(platterShape.strokeBorder(Color.platterEdge, lineWidth: 0.5))
    }

    private var platterShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: GlassStyle.platterRadius, style: .continuous)
    }
}

extension View {
    func platter() -> some View {
        modifier(PlatterModifier())
    }
}

/// A small capsule with secondary text, e.g. a plan name.
struct InfoChip: View {
    let text: String

    var body: some View {
        // Names come from the providers (e.g. Google's "Google AI Pro"), so a
        // long one stays on one line and shows in full on hover.
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.chipFill))
            .help(text)
    }
}

/// A round icon button for the dropdown's footer. It is a light platter
/// rather than glass, because it already sits on the dropdown's glass.
struct CircleIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CircleIconButtonBody(configuration: configuration)
    }
}

private struct CircleIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: 30, height: 30)
            .background(Circle().fill(fill))
            .overlay(Circle().strokeBorder(Color.platterEdge, lineWidth: 0.5))
            .contentShape(Circle())
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var fill: Color {
        if configuration.isPressed { return Color.primary.opacity(0.16) }
        if isHovering { return Color.primary.opacity(0.10) }
        return .platterFill
    }
}

extension UsageWindow {
    /// The label for tight layouts: "5h" and "Week" for the two common limits,
    /// the full label otherwise. Spoken labels keep the full name.
    var shortLabel: String {
        switch label {
        case L("5h limit"): return L("5h")
        case L("Weekly limit"): return L("Week")
        default: return label
        }
    }

    /// The reset in few characters, following the Reset times setting:
    /// "2h 10m" (relative), or "21:41", "Fri 21:41", "14 Nov" (exact).
    /// `prefixed` adds "in" to the relative form.
    func compactReset(style: ResetTimeStyle, prefixed: Bool, now: Date = Date()) -> String? {
        guard let resetsAt else { return nil }
        switch style {
        case .relative:
            guard let remaining = shortRemainingDescription(now: now) else { return nil }
            guard resetsAt > now else { return remaining }
            return prefixed ? L("in \(remaining)") : remaining
        case .absolute:
            let calendar = Calendar.current
            let time = Date.FormatStyle().hour().minute()
            if calendar.isDate(resetsAt, inSameDayAs: now) {
                return resetsAt.formatted(time)
            }
            if resetsAt.timeIntervalSince(now) < 6 * 86_400 {
                return resetsAt.formatted(Date.FormatStyle().weekday(.abbreviated).hour().minute())
            }
            return resetsAt.formatted(Date.FormatStyle().month(.abbreviated).day())
        }
    }
}

/// Liquid Glass behind a floating window's content on macOS 26 and later,
/// and the menu material before that. It fills the window, whose own corners
/// and outline shape it: a glass shape of its own would not line up with the
/// outline macOS draws around the window. The opacity setting fades only the
/// background; content drawn on top stays fully opaque.
struct WindowGlassBackground: NSViewRepresentable {
    let opacity: Double

    func makeNSView(context: Context) -> GlassBackgroundView {
        GlassBackgroundView()
    }

    func updateNSView(_ nsView: GlassBackgroundView, context: Context) {
        nsView.opacity = opacity
    }
}

final class GlassBackgroundView: NSView {
    private let effectView: NSView

    var opacity: Double = 1 {
        didSet { effectView.alphaValue = opacity }
    }

    init() {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 0
            effectView = glass
        } else {
            let material = NSVisualEffectView()
            material.material = .menu
            material.blendingMode = .behindWindow
            material.state = .active
            effectView = material
        }
        super.init(frame: .zero)
        effectView.frame = bounds
        effectView.autoresizingMask = [.width, .height]
        addSubview(effectView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        effectView.frame = bounds
    }
}
