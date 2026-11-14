import Foundation

/// Window usage severity from percent thresholds (shared by menu bar tinting,
/// progress bar color, and accessibility qualifiers).
enum UsageMeterSeverity: Equatable {
    case normal, warning, critical

    nonisolated static func forUsedPercent(_ percent: Double) -> Self {
        switch percent {
        case ..<60: return .normal
        case ..<85: return .warning
        default: return .critical
        }
    }

    nonisolated var qualifier: String? {
        switch self {
        case .normal: return nil
        case .warning: return L("high usage")
        case .critical: return L("nearly used up")
        }
    }

    nonisolated var symbolName: String? {
        switch self {
        case .normal: return nil
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }
}

import SwiftUI

extension UsageMeterSeverity {
    /// Meter fill: quiet when healthy, system orange and red otherwise.
    var color: Color {
        switch self {
        case .normal: return .meterNormal
        case .warning: return Color(nsColor: .systemOrange)
        case .critical: return Color(nsColor: .systemRed)
        }
    }

    /// Percent text tint; nil keeps the surrounding text color.
    var textColor: Color? {
        switch self {
        case .normal: return nil
        case .warning: return .warningText
        case .critical: return .criticalText
        }
    }
}

/// Horizontal usage bar. Drawn with SwiftUI shapes rather than a tinted
/// `ProgressView`: AppKit resolves the tint once, so `.primary` stayed black in
/// dark mode and colors went stale after an appearance change.
struct UsageMeterBar: View {
    /// 0...100.
    let percent: Double
    let severity: UsageMeterSeverity
    /// Even-pace position, 0...100 in the same units as `percent`: where the
    /// fill would end with even use across the window. Nil hides the marker.
    var paceMarkerPercent: Double? = nil
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.meterTrack)
                Capsule()
                    .fill(severity.color)
                    .frame(width: proxy.size.width * min(1, max(0, percent / 100)))
                if let paceMarkerPercent {
                    // Taller than the bar, with a background-colored edge, so
                    // it stays visible on top of a fill of the same color.
                    let x = proxy.size.width * min(1, max(0, paceMarkerPercent / 100))
                    Capsule()
                        .fill(.primary)
                        .frame(width: 2, height: height + 6)
                        .padding(.horizontal, 1)
                        .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
                        .position(x: min(max(x, 2), max(2, proxy.size.width - 2)), y: proxy.size.height / 2)
                }
            }
        }
        .frame(height: height)
        // Room for the pace marker above and below the bar.
        .padding(.vertical, 3)
        .accessibilityHidden(true)
    }
}

extension CountDirection {
    /// Where the bar's fill would end with even use: the elapsed share in
    /// "% used" mode, the share of time left in "% left" mode.
    nonisolated func paceMarkerPercent(for window: UsageWindow, now: Date) -> Double? {
        window.elapsedFraction(now: now).map { displayPercent($0 * 100) }
    }
}

/// A percent or balance value with its severity symbol. Warning and critical
/// values take the severity's text color; severity is never shown by color
/// alone, so they also carry a symbol.
struct SeverityValueLabel: View {
    let text: String
    let symbolName: String?
    /// Severity tint; nil draws the value in `plainColor`.
    let tint: Color?
    var plainColor: Color = .primary
    var font: Font = .meterValue()
    var symbolFont: Font = .system(size: 10.5, weight: .semibold)

    var body: some View {
        HStack(spacing: 3) {
            Text(text).font(font)
            if let symbolName {
                Image(systemName: symbolName)
                    .font(symbolFont)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(tint ?? plainColor)
        .lineLimit(1)
        .fixedSize()
    }
}
