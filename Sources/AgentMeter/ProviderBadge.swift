import SwiftUI

/// Small monogram badge for a provider — a rounded square with its short code
/// in a fixed accent color. Pure shapes: no bundled artwork, no trademarked
/// logos, adapts to both color schemes for free.
struct ProviderBadge: View {
    let providerID: String
    let shortCode: String
    var size: CGFloat = 20

    init(provider: any UsageProvider, size: CGFloat = 20) {
        self.init(providerID: provider.id, shortCode: provider.shortCode, size: size)
    }

    init(providerID: String, shortCode: String, size: CGFloat = 20) {
        self.providerID = providerID
        self.shortCode = shortCode
        self.size = size
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(Self.color(for: providerID).gradient)
            .frame(width: size, height: size)
            .overlay {
                Text(shortCode)
                    .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }

    static func color(for providerID: String) -> Color {
        switch ProviderAccountConfig.baseProviderID(of: providerID) {
        case "codex": return Color(red: 0.06, green: 0.65, blue: 0.55)
        case "cursor": return Color(red: 0.45, green: 0.36, blue: 0.90)
        case "claude", "claude-api": return Color(red: 0.85, green: 0.47, blue: 0.25)
        case "gemini": return Color(red: 0.26, green: 0.52, blue: 0.96)
        case "muse": return Color(red: 0.80, green: 0.27, blue: 0.62)
        case "antigravity": return Color(red: 0.86, green: 0.55, blue: 0.10)
        case "openrouter": return Color(red: 0.35, green: 0.42, blue: 0.85)
        case "deepseek": return Color(red: 0.20, green: 0.60, blue: 0.86)
        case "moonshot": return Color(red: 0.16, green: 0.22, blue: 0.48)
        case "zai": return Color(red: 0.18, green: 0.62, blue: 0.41)
        case "venice": return Color(red: 0.78, green: 0.29, blue: 0.34)
        default: return .gray
        }
    }
}
