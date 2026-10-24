import AppKit

enum MenuBarSeverity { case normal, warning, critical, stale }

@MainActor
enum MenuBarTitleRenderer {
    nonisolated static func severity(
        for state: ProviderState,
        balanceThreshold: Double
    ) -> MenuBarSeverity {
        switch state {
        case .stale:
            return .stale
        case .loading:
            return .normal
        case .error:
            return .critical
        case .ready(let usage):
            if let worst = usage.worstWindow {
                return menuBarSeverity(from: UsageMeterSeverity.forUsedPercent(worst.usedPercent))
            }
            if let balance = usage.balance, balance.kind == .remaining {
                return balance.remaining < balanceThreshold ? .warning : .normal
            }
            return .normal
        }
    }

    static func nsColor(for severity: MenuBarSeverity) -> NSColor {
        switch severity {
        case .normal: .labelColor
        case .warning: .systemYellow
        case .critical: .systemRed
        case .stale: .secondaryLabelColor
        }
    }

    nonisolated private static func menuBarSeverity(from meter: UsageMeterSeverity) -> MenuBarSeverity {
        switch meter {
        case .normal: .normal
        case .warning: .warning
        case .critical: .critical
        }
    }

    static func image(
        entries: [(text: String, severity: MenuBarSeverity)],
        accessibilityDescription: String
    ) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let attributed = NSMutableAttributedString()
        for (index, entry) in entries.enumerated() {
            if index > 0 {
                attributed.append(NSAttributedString(
                    string: " · ",
                    attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
                ))
            }
            attributed.append(NSAttributedString(
                string: entry.text,
                attributes: [.font: font, .foregroundColor: nsColor(for: entry.severity)]
            ))
        }
        let size = attributed.size()
        let image = NSImage(size: NSSize(width: ceil(size.width), height: ceil(size.height)), flipped: false) { _ in
            attributed.draw(at: .zero)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    /// Fill fractions of the three meter bars, matching the app icon.
    nonisolated static let iconBarFills: [CGFloat] = [0.84, 0.57, 0.30]

    /// Icon-only menu bar style: three allowance meters, like the app icon.
    /// Normal and stale states are template images, so macOS tints them for
    /// light and dark menu bars; warning and critical keep their color.
    static func iconImage(severity: MenuBarSeverity, accessibilityDescription: String) -> NSImage {
        let barWidth: CGFloat = 16
        let barHeight: CGFloat = 3
        let gap: CGFloat = 2
        let count = CGFloat(iconBarFills.count)
        let size = NSSize(width: barWidth, height: count * barHeight + (count - 1) * gap)
        let tint: NSColor? = switch severity {
        case .warning, .critical: nsColor(for: severity)
        case .normal, .stale: nil
        }
        let opacity: CGFloat = severity == .stale ? 0.5 : 1

        let image = NSImage(size: size, flipped: true) { _ in
            let color = tint ?? .black
            for (index, fill) in iconBarFills.enumerated() {
                let y = CGFloat(index) * (barHeight + gap)
                let radius = barHeight / 2
                let track = NSRect(x: 0, y: y, width: barWidth, height: barHeight)
                color.withAlphaComponent(0.35 * opacity).setFill()
                NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
                let filled = NSRect(x: 0, y: y, width: (barWidth * fill).rounded(), height: barHeight)
                color.withAlphaComponent(opacity).setFill()
                NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
            }
            return true
        }
        image.isTemplate = tint == nil
        image.accessibilityDescription = accessibilityDescription
        return image
    }
}
