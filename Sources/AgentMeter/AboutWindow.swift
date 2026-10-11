import SwiftUI

struct AboutView: View {
    private var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    var body: some View {
        VStack(spacing: 12) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
            }
            Text("Allowance Bar")
                .font(.title2.bold())
            Text(L("Version \(version)"))
                .font(.callout)
                .foregroundStyle(.secondary)

            Text(L("Menu bar monitor for AI coding usage limits."))
                .font(.callout)
                .multilineTextAlignment(.center)

            Divider().padding(.horizontal, 24)

            VStack(spacing: 4) {
                Link(L("Website & source code"), destination: URL(string: "https://github.com/gilitos92/AllowanceBar")!)
                Link(L("Report an issue"), destination: URL(string: "https://github.com/gilitos92/AllowanceBar/issues")!)
                Link(L("Support ♥"), destination: URL(string: "https://www.buymeacoffee.com/gilitos92")!)
            }
            .font(.callout)

            Divider().padding(.horizontal, 24)

            VStack(spacing: 2) {
                Text(L("Based on AgentMeter by Felix Torres (MIT License)."))
                Text(L("Auto-updates powered by Sparkle (MIT License)."))
                Text(L("Provider endpoint research credits CodexBar by Peter Steinberger."))
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            Text("© 2026 Felix Torres, gilitos92 · MIT License")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(width: 340)
    }
}
