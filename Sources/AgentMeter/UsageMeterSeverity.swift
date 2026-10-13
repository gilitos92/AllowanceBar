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
    /// Progress bar and percent tint.
    var color: Color {
        switch self {
        case .normal: return .primary
        case .warning: return .yellow
        case .critical: return .red
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

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(severity.color)
                    .frame(width: proxy.size.width * min(1, max(0, percent / 100)))
            }
        }
        .frame(height: 6)
        // Matches the spacing the system progress bar used to reserve.
        .padding(.vertical, 6)
        .accessibilityHidden(true)
    }
}

/// Fill and text colors for a warning or critical value badge.
struct SeverityBadgeStyle {
    let fill: Color
    let foreground: Color
}

extension UsageMeterSeverity {
    /// Yellow or red text is hard to read on light backgrounds, so warning
    /// and critical values sit in a pill of the severity color instead. The
    /// red is darker than `.red` so white text on it stays readable.
    var badgeStyle: SeverityBadgeStyle? {
        switch self {
        case .normal: return nil
        case .warning: return SeverityBadgeStyle(fill: .yellow, foreground: .black)
        case .critical: return SeverityBadgeStyle(fill: Color(red: 0.8, green: 0.1, blue: 0.1), foreground: .white)
        }
    }
}

/// A percent or balance value with its severity symbol. Values with a badge
/// style are drawn as a pill; others as plain text in `plainColor`.
struct SeverityValueLabel: View {
    let text: String
    let symbolName: String?
    let badge: SeverityBadgeStyle?
    var plainColor: Color = .primary
    var font: Font = .callout.monospacedDigit().weight(.semibold)
    var symbolFont: Font = .subheadline.weight(.medium)

    var body: some View {
        let content = HStack(spacing: 3) {
            Text(text).font(font)
            if let symbolName {
                Image(systemName: symbolName)
                    .font(symbolFont)
                    .accessibilityHidden(true)
            }
        }
        if let badge {
            content
                .foregroundStyle(badge.foreground)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(badge.fill))
        } else {
            content.foregroundStyle(plainColor)
        }
    }
}
