import SwiftUI
import ServiceManagement

struct SettingsRootView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: SettingsStore

    var body: some View {
        TabView {
            GeneralSettingsTab(store: store, settings: settings)
                .frame(width: 520, height: 400)
                .tabItem {
                    Label(L("General"), systemImage: "gearshape")
                }
            ProvidersSettingsTab(store: store, settings: settings)
                .frame(minWidth: 720, idealWidth: 760, minHeight: 460, idealHeight: 540)
                .tabItem {
                    Label(L("Providers"), systemImage: "list.bullet")
                }
            DisplaySettingsTab(settings: settings)
                .frame(width: 520, height: 520)
                .tabItem {
                    Label(L("Display"), systemImage: "macwindow")
                }
            AlertsSettingsTab(store: store, settings: settings)
                .frame(width: 520, height: 400)
                .tabItem {
                    Label(L("Alerts"), systemImage: "bell")
                }
            AgentsSettingsTab(store: store, settings: settings)
                .frame(width: 520, height: 340)
                .tabItem {
                    Label(L("Agents"), systemImage: "apple.terminal")
                }
        }
    }
}

private struct GeneralSettingsTab: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: SettingsStore
    @Environment(\.openWindow) private var openWindow
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var diagnosticsCopied = false

    var body: some View {
        SettingsPage {
            SettingsGroup {
                Toggle(L("Launch at Login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                Picker(L("Refresh interval"), selection: Binding(
                    get: { settings.refreshInterval },
                    set: { newValue in
                        settings.refreshInterval = newValue
                        store.rescheduleTimer()
                    }
                )) {
                    ForEach(SettingsStore.refreshOptions, id: \.seconds) { option in
                        Text(option.label).tag(option.seconds)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .settingsRow(L("Refresh interval"))
            }
            SettingsGroup {
                LabeledContent(L("Diagnostics")) {
                    Button {
                        copyDiagnostics()
                    } label: {
                        if diagnosticsCopied {
                            Label(L("Copied"), systemImage: "checkmark")
                        } else {
                            Text(L("Copy Diagnostics"))
                        }
                    }
                }
            } footer: {
                SettingsNote(L("Copies redacted troubleshooting info to the clipboard — never includes keys or tokens."))
            }
            SettingsGroup {
                LabeledContent(L("Allowance Bar")) {
                    Button(L("About Allowance Bar")) {
                        openWindow(id: "about")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
            }
        }
    }

    private func copyDiagnostics() {
        let report = Diagnostics.report(store: store, settings: settings)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        diagnosticsCopied = true
        AccessibilityNotification.Announcement(L("Diagnostics copied")).post()
        Task {
            try? await Task.sleep(for: .seconds(2))
            diagnosticsCopied = false
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// The opt-in snapshot for the allowancebar command-line tool and agents.
private struct AgentsSettingsTab: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: SettingsStore
    @State private var cliInstallPath: String?
    @State private var cliInstallResultMessage: String?

    var body: some View {
        SettingsPage {
            SettingsGroup {
                Toggle(L("Enable agent & CLI access"), isOn: $settings.agentAccessEnabled)
                    .onChange(of: settings.agentAccessEnabled) { _, enabled in
                        if enabled {
                            StatusSnapshotWriter.writeIfEnabled(store: store, settings: settings)
                        }
                    }
            } footer: {
                SettingsNote(L("Writes a machine-readable usage snapshot (never credentials) to Application Support for the allowancebar command-line tool and other local agents."))
            }
            SettingsGroup {
                cliToolInstallSection
            }
        }
        .onAppear {
            refreshCLIInstallStatus()
        }
    }

    @ViewBuilder
    private var cliToolInstallSection: some View {
        if CLIToolInstaller.isBundledApp {
            Group {
                if let path = cliInstallPath {
                    Text(String(format: L("Command-line tool installed at %@"), path))
                } else {
                    Text(L("Command-line tool not on your PATH."))
                }

                if let cliInstallResultMessage {
                    Text(cliInstallResultMessage)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Button(CLIToolInstaller.isInstalledAtLocalPath()
                ? L("Reinstall Command-Line Tool…")
                : L("Install Command-Line Tool…")) {
                installCLITool()
            }
        } else {
            Text(L("Run from Allowance Bar.app to install the command-line tool."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func refreshCLIInstallStatus() {
        cliInstallPath = CLIToolInstaller.detectedInstallPath()
    }

    private func installCLITool() {
        cliInstallResultMessage = nil

        switch CLIToolInstaller.install() {
        case .success:
            refreshCLIInstallStatus()
            let message = L("Installed. Open a new terminal and run allowancebar --help.")
            cliInstallResultMessage = message
            AccessibilityNotification.Announcement(message).post()
        case .failure(_ as CancellationError):
            break
        case .failure(let error):
            let message = String(format: L("Couldn't install the command-line tool: %@"), error.localizedDescription)
            cliInstallResultMessage = message
            AccessibilityNotification.Announcement(message).post()
        }
    }

}

/// A list of providers beside one page per provider. A provider with one
/// account shows that account's settings on its page; a provider with
/// several lists them, and each account opens its own settings sheet.
private struct ProvidersSettingsTab: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: SettingsStore
    @State private var selection: ProviderPane? = nil

    enum ProviderPane: Hashable {
        case provider(String)
        case cliProxy
    }

    private var groups: [ProviderGroup] {
        ProviderGroup.groups(store.providers)
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                Section {
                    ForEach(groups) { group in
                        sidebarRow(for: group)
                            .tag(ProviderPane.provider(group.baseID))
                    }
                }
                Section {
                    HStack(spacing: 8) {
                        CLIProxyBadge(size: 20)
                        Text(L("CLIProxyAPI"))
                        Spacer(minLength: 4)
                        if CLIProxyConfig.isConfigured {
                            Circle().fill(.green).frame(width: 7, height: 7)
                                .accessibilityLabel(L("Saved"))
                        }
                    }
                    .tag(ProviderPane.cliProxy)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 220)

            Divider()

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if selection == nil, let first = groups.first {
                selection = .provider(first.baseID)
            }
        }
    }

    private func sidebarRow(for group: ProviderGroup) -> some View {
        HStack(spacing: 8) {
            ProviderBadge(providerID: group.baseID, shortCode: group.baseShortCode, size: 20)
            Text(group.baseName)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let summary = summary(for: group) {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "Off", "3 accounts", the plan or the balance, in that order.
    private func summary(for group: ProviderGroup) -> String? {
        if group.members.allSatisfy({ settings.mode(for: $0.id) == .off }) {
            return L("Off")
        }
        if group.members.count > 1 {
            return String(format: L("%lld accounts"), group.members.count)
        }
        guard let provider = group.members.first, let usage = store.state(for: provider.id).usage else { return nil }
        return usage.planName ?? usage.balance?.shortDisplay
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .cliProxy:
            SettingsPage {
                SettingsPaneHeader(
                    badge: AnyView(CLIProxyBadge(size: 34)),
                    title: L("CLIProxyAPI"),
                    subtitle: L("Claude, Codex, Gemini and Antigravity logins from your proxy")
                )
                SettingsGroup {
                    CLIProxySection(store: store, settings: settings)
                }
            }
        case .provider(let baseID):
            if let group = groups.first(where: { $0.baseID == baseID }) {
                ProviderPage(group: group, store: store, settings: settings)
                    .id(group.baseID)
            } else {
                emptyDetail
            }
        case nil:
            emptyDetail
        }
    }

    private var emptyDetail: some View {
        Text(L("No providers enabled. Open Settings to turn some on."))
            .foregroundStyle(.secondary)
    }
}

/// CLIProxyAPI's green badge, which has no provider short code.
private struct CLIProxyBadge: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "arrow.left.arrow.right")
            .font(.system(size: size * 0.45, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(Color.green.gradient))
            .accessibilityHidden(true)
    }
}

/// The badge, name and one-line description at the top of a settings page.
private struct SettingsPaneHeader: View {
    let badge: AnyView
    let title: String
    let subtitle: String?

    var body: some View {
        HStack(spacing: 10) {
            badge.accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .textCase(nil)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One provider's page. With one account, its settings sit in a card; with
/// several, the page is a list of accounts.
private struct ProviderPage: View {
    let group: ProviderGroup
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: SettingsStore
    @State private var sheet: PageSheet?
    @State private var discovered: [ProviderAccountDiscovery.Candidate] = []
    @State private var findMessage: String?

    enum PageSheet: Identifiable {
        case account(String)
        case addAccount

        var id: String {
            switch self {
            case .account(let providerID): return "account:\(providerID)"
            case .addAccount: return "add"
            }
        }
    }

    /// How accounts are added to this provider; nil for providers that
    /// exist only as CLIProxyAPI logins, such as Antigravity.
    private var support: ProviderAccountSupport? {
        guard group.members.contains(where: { $0.id == group.baseID }) else { return nil }
        return ProviderAccountSupport.support(for: group.baseID)
    }

    private var labels: [String: ProviderGroup.AccountLabel] {
        let emails = group.members.reduce(into: [String: String]()) { result, provider in
            if let email = store.state(for: provider.id).usage?.accountEmail
                ?? (provider as? CodexProvider)?.accountEmail {
                result[provider.id] = email
            }
        }
        return group.accountLabels(emails: emails)
    }

    var body: some View {
        SettingsPage {
            header
            if group.members.count == 1, let provider = group.members.first {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsGroup {
                        AccountSettingsFields(provider: provider, store: store, settings: settings)
                    }
                    accountButtons
                }
                if provider.id == "codex" {
                    codexSubscriptionSection(providerID: provider.id)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsGroup(title: L("Accounts")) {
                        ForEach(group.members, id: \.id) { member in
                            accountRow(member)
                        }
                    }
                    accountButtons
                }
            }

            if !discovered.isEmpty {
                SettingsGroup(title: L("Found on this Mac")) {
                    ForEach(discovered) { candidate in
                        discoveredRow(candidate)
                    }
                }
            }
        }
        .onAppear(perform: refreshDiscovered)
        .onChange(of: settings.extraAccounts) { _, _ in refreshDiscovered() }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .account(let providerID):
                if let provider = group.members.first(where: { $0.id == providerID }) {
                    AccountSettingsSheet(
                        provider: provider,
                        label: labels[providerID] ?? .init(name: provider.displayName, detail: nil),
                        store: store,
                        settings: settings
                    )
                }
            case .addAccount:
                if let support {
                    AddAccountSheet(
                        baseProviderID: group.baseID,
                        providerName: group.baseName,
                        support: support,
                        settings: settings
                    )
                }
            }
        }
    }

    private var header: some View {
        SettingsPaneHeader(
            badge: AnyView(ProviderBadge(providerID: group.baseID, shortCode: group.baseShortCode, size: 34)),
            title: group.baseName,
            subtitle: Self.description(of: group.baseID)
        )
    }

    /// What the provider shows and where it reads it from.
    static func description(of baseID: String) -> String? {
        switch baseID {
        case "claude": return L("Subscription limits from Claude Code")
        case "codex": return L("Subscription limits from the Codex CLI")
        case "cursor": return L("Plan usage from the Cursor app")
        case "gemini": return L("Quotas from the Gemini CLI")
        case "muse": return L("Subscription limits from the Muse Code CLI")
        case "claude-api": return L("Organization spend from the Claude API")
        case "antigravity": return L("Quotas from your CLIProxyAPI logins")
        case "openrouter", "deepseek", "moonshot", "zai", "venice": return L("Pay-as-you-go balance")
        default: return nil
        }
    }

    // MARK: Accounts

    @ViewBuilder
    private var accountButtons: some View {
        if let support {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button(L("Add Account…")) { sheet = .addAccount }
                        .accessibilityLabel(String(format: L("Add %@ account"), group.baseName))
                    if support.folder != nil {
                        Button(L("Find Accounts")) { findAccounts() }
                            .help(L("Looks for other signed-in folders of this tool in your home folder."))
                    }
                }
                .controlSize(.large)
                if let findMessage {
                    SettingsNote(findMessage)
                }
            }
        }
    }

    private func accountRow(_ member: any UsageProvider) -> some View {
        let label = labels[member.id] ?? .init(name: member.displayName, detail: nil)
        let plan = plan(of: member)
        let detail = rowDetail(of: member, label: label)
        let problem = problem(of: member)
        return Button {
            sheet = .account(member.id)
        } label: {
            HStack(spacing: 10) {
                ProviderBadge(provider: member, size: 20)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(label.name)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        if let plan {
                            Text("· \(plan)")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    if let detail {
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(Color.warningText)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([label.name, plan].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue([detail, problem].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(L("Opens this account's settings"))
        .accessibilityAddTraits(.isButton)
    }

    private func plan(of member: any UsageProvider) -> String? {
        if let plan = store.state(for: member.id).usage?.planName { return plan }
        if ProviderAccountConfig.baseProviderID(of: member.id) == "codex" {
            return CodexPlan.displayName(CodexAccountCache.shared.lastPlanType(for: member.id))
        }
        return nil
    }

    /// The email when it adds something, where the account comes from, and
    /// whether it is off or still loading.
    private func rowDetail(of member: any UsageProvider, label: ProviderGroup.AccountLabel) -> String? {
        var parts: [String] = []
        if let detail = label.detail { parts.append(detail) }
        if let source = source(of: member), !(label.detail?.contains(source) ?? false) {
            parts.append(source)
        }
        if settings.mode(for: member.id) == .off {
            parts.append(L("Off"))
        } else if case .loading = store.state(for: member.id) {
            parts.append(L("Loading…"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The account's error, shown on its own line so it isn't cut short.
    private func problem(of member: any UsageProvider) -> String? {
        guard settings.mode(for: member.id) != .off,
              case .error(let message) = store.state(for: member.id) else { return nil }
        return message
    }

    private func source(of member: any UsageProvider) -> String? {
        if member is CLIProxyAccountProvider { return L("CLIProxyAPI") }
        if member.id == group.baseID { return support?.folder?.defaultPath }
        return settings.extraAccounts.first(where: { $0.providerID == member.id })?.homePath
    }

    private func discoveredRow(_ candidate: ProviderAccountDiscovery.Candidate) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(candidate.suggestedLabel)
                    .fontWeight(.semibold)
                Text(candidate.homePath)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(L("Add")) {
                settings.addAccount(ProviderAccountConfig(
                    baseProviderID: group.baseID,
                    label: candidate.suggestedLabel,
                    homePath: candidate.homePath
                ))
                AccessibilityNotification.Announcement(String(format: L("%@ added"), candidate.suggestedLabel)).post()
            }
            .help(L("Adds this account to Allowance Bar using the folder name as its label."))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(format: L("Found %@ account: %@"), group.baseName, candidate.homePath))
    }

    private func refreshDiscovered() {
        guard let folder = support?.folder else {
            discovered = []
            return
        }
        discovered = ProviderAccountDiscovery.discover(
            folder: folder,
            configured: settings.accounts(for: group.baseID)
        )
    }

    private func findAccounts() {
        refreshDiscovered()
        let message: String
        switch discovered.count {
        case 0: message = L("No other accounts found.")
        case 1: message = L("1 account found")
        default: message = String(format: L("%lld accounts found"), discovered.count)
        }
        findMessage = discovered.isEmpty ? message : nil
        AccessibilityNotification.Announcement(message).post()
    }

    private func codexSubscriptionSection(providerID: String) -> some View {
        SettingsGroup {
            CodexSubscriptionSettings(providerID: providerID, settings: settings)
        } footer: {
            SettingsNote(L("OpenAI doesn't publish subscription renewal dates, so confirm yours on the platform that bills you — ChatGPT, Apple, or Google Play. Renewal dates are separate from usage-limit resets."))
        }
    }
}

/// One account's visibility and credential, shared by the single-account
/// card and the account sheet.
private struct AccountSettingsFields: View {
    let provider: any UsageProvider
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Picker(L("Show"), selection: Binding(
            get: { settings.mode(for: provider.id) },
            set: { newValue in
                settings.setMode(newValue, for: provider.id)
                store.refresh()
            }
        )) {
            ForEach(ProviderMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .settingsSegmented()
        .help(L("Auto shows this account when Allowance Bar finds it on this Mac."))
        .settingsRow(L("Show"))

        if settings.mode(for: provider.id) != .off {
            Toggle(L("Show in menu bar"), isOn: Binding(
                get: { settings.showsInMenuBar(provider.id) },
                set: { settings.setShowsInMenuBar($0, for: provider.id) }
            ))
        }

        ProviderCredentialSection(provider: provider, store: store)

        if let localName = store.localDuplicateName(of: provider) {
            Text(String(format: L("Hidden because %@ shows the same account. Choose On to show both."), localName))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// The settings of one account of a provider with several accounts.
private struct AccountSettingsSheet: View {
    let provider: any UsageProvider
    let label: ProviderGroup.AccountLabel
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var nameDraft = ""

    /// The saved extra account; nil for the default account and proxy logins.
    private var account: ProviderAccountConfig? {
        settings.extraAccounts.first { $0.providerID == provider.id }
    }

    private var isCodex: Bool {
        ProviderAccountConfig.baseProviderID(of: provider.id) == "codex"
            && !(provider is CLIProxyAccountProvider)
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsColumn {
                SettingsPaneHeader(
                    badge: AnyView(ProviderBadge(provider: provider, size: 30)),
                    title: label.name,
                    subtitle: label.detail
                )

                SettingsGroup {
                    AccountSettingsFields(provider: provider, store: store, settings: settings)
                }

                if let account {
                    SettingsGroup {
                        TextField(L("Name"), text: $nameDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                            .onSubmit(saveName)
                            .settingsRow(L("Name"))
                        if let homePath = account.homePath {
                            LabeledContent(L("Folder")) {
                                Text(homePath)
                                    .font(.callout.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }

                if isCodex {
                    SettingsGroup {
                        CodexSubscriptionSettings(providerID: provider.id, settings: settings)
                    } footer: {
                        SettingsNote(L("OpenAI doesn't publish subscription renewal dates, so confirm yours on the platform that bills you — ChatGPT, Apple, or Google Play. Renewal dates are separate from usage-limit resets."))
                    }
                }

                if let account {
                    SettingsGroup {
                        Button(L("Remove Account"), role: .destructive) { remove(account) }
                    } footer: {
                        SettingsNote(account.homePath == nil
                            ? L("Removing deletes this account's saved key from Allowance Bar.")
                            : L("Removing only forgets the path; it does not sign out."))
                    }
                }
            }

            Divider()
            HStack {
                Spacer()
                Button(L("Done")) {
                    saveName()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .padding(14)
        }
        .frame(width: 480)
        .onAppear { nameDraft = account?.label ?? "" }
    }

    private func saveName() {
        guard let account else { return }
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != account.label else { return }
        settings.renameAccount(id: account.id, to: name)
        AccessibilityNotification.Announcement(String(format: L("Renamed to %@"), name)).post()
    }

    private func remove(_ account: ProviderAccountConfig) {
        if account.homePath == nil {
            KeychainStore.delete("apikey.\(account.providerID)")
        }
        dismiss()
        settings.removeAccount(id: account.id)
        AccessibilityNotification.Announcement(String(format: L("%@ removed"), account.label)).post()
    }
}

/// Adds an account: a name, and for tools that sign in through a folder,
/// the folder and the command that signs it in.
private struct AddAccountSheet: View {
    let baseProviderID: String
    let providerName: String
    let support: ProviderAccountSupport
    @ObservedObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var draftLabel = ""
    @State private var draftHomePath = ""
    @State private var addFormError: String?

    private var accounts: [ProviderAccountConfig] { settings.accounts(for: baseProviderID) }

    var body: some View {
        VStack(spacing: 0) {
            SettingsColumn {
                Text(String(format: L("Add %@ account"), providerName))
                    .font(.title3.weight(.bold))
                    .accessibilityAddTraits(.isHeader)

                SettingsGroup {
                    TextField(L("Name"), text: $draftLabel)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .onChange(of: draftLabel) { _, newValue in
                            guard let folder = support.folder else { return }
                            if draftHomePath.isEmpty || draftHomePath.hasPrefix(folder.suggestedPrefix) {
                                draftHomePath = ProviderAccountSupport.suggestedHomePath(
                                    prefix: folder.suggestedPrefix,
                                    label: newValue
                                )
                            }
                        }
                        .settingsRow(L("Name"))
                    if let folder = support.folder {
                        folderFields(folder)
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let addFormError {
                            Text(addFormError)
                                .font(.callout)
                                .foregroundStyle(Color.warningText)
                                .padding(.horizontal, 4)
                        }
                        if let folder = support.folder {
                            SettingsNote(String(format: L("Run this in Terminal to sign in that account. Allowance Bar never handles your login or tokens — %@ does."), folder.loginTool))
                        } else {
                            SettingsNote(L("After adding it, open the account to save its key."))
                        }
                    }
                }
            }

            Divider()
            HStack {
                Spacer()
                Button(L("Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Add")) { saveAccount() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isAddFormValid)
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .padding(14)
        }
        .frame(width: 480)
        .onAppear {
            draftHomePath = support.folder.map {
                ProviderAccountSupport.suggestedHomePath(prefix: $0.suggestedPrefix, label: "")
            } ?? ""
        }
    }

    @ViewBuilder
    private func folderFields(_ folder: ProviderAccountSupport.Folder) -> some View {
        let loginCommand = folder.loginCommand(draftHomePath)
        TextField(L("Folder"), text: $draftHomePath)
            .textFieldStyle(.roundedBorder)
            .font(.callout.monospaced())
            .frame(width: 220)
            .settingsRow(L("Folder"))

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("Sign-in command"))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(loginCommand, forType: .string)
                    AccessibilityNotification.Announcement(L("Login command copied")).post()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help(L("Copy login command"))
                .accessibilityLabel(L("Copy login command"))
                .accessibilityHint(String(format: L("Copies the Terminal command to sign in this %@ account"), providerName))
            }
            Text(loginCommand)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var trimmedLabel: String { draftLabel.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedPath: String { draftHomePath.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var isAddFormValid: Bool {
        guard !trimmedLabel.isEmpty else { return false }
        guard support.folder != nil else { return true }
        return pathError(trimmedPath) == nil
    }

    private func pathError(_ path: String) -> String? {
        guard let folder = support.folder else { return nil }
        guard !path.isEmpty else { return L("Folder is required") }
        let expanded = ProviderAccountPath.expand(path).standardizedFileURL.path
        let defaultPaths = [folder.defaultPath, "~"].map {
            ProviderAccountPath.expand($0).standardizedFileURL.path
        }
        if defaultPaths.contains(expanded) {
            return String(format: L("Choose a folder other than %@"), folder.defaultPath)
        }
        let taken = accounts.compactMap { $0.expandedHomeURL()?.standardizedFileURL.path }
        if taken.contains(expanded) {
            return L("This folder is already added")
        }
        return nil
    }

    private func saveAccount() {
        guard !trimmedLabel.isEmpty else {
            addFormError = L("Label is required")
            return
        }
        if let error = pathError(trimmedPath) {
            addFormError = error
            return
        }
        settings.addAccount(ProviderAccountConfig(
            baseProviderID: baseProviderID,
            label: trimmedLabel,
            homePath: support.folder == nil ? nil : trimmedPath
        ))
        AccessibilityNotification.Announcement(String(format: L("%@ added"), trimmedLabel)).post()
        dismiss()
    }
}

/// Optional CLIProxyAPI server. Each of its Claude, Codex, Antigravity and
/// Gemini logins shows as its own row, and it answers for Claude logins whose
/// Claude Code token has expired or is missing on this Mac.
private struct CLIProxySection: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: SettingsStore
    @State private var hasKey = CLIProxyConfig.isConfigured
    @State private var draftKey = ""
    @State private var keyError: String?
    @State private var checking = false
    @State private var checkResult: String?
    @State private var proxyEmails: [String] = []
    /// Saved only on Return or Check connection, so a refresh never sends
    /// the key to a half-typed address.
    @State private var draftURL = ""

    private var localClaudeProviderIDs: [String] {
        store.providers
            .filter { !($0 is CLIProxyAccountProvider) }
            .map(\.id)
            .filter { ProviderAccountConfig.baseProviderID(of: $0) == "claude" }
    }

    /// Every row the proxy affects: local Claude accounts and proxy logins.
    private var affectedProviderIDs: [String] {
        localClaudeProviderIDs + store.providers.filter { $0 is CLIProxyAccountProvider }.map(\.id)
    }

    var body: some View {
        Text(L("Allowance Bar shows every Claude, Codex, Antigravity and Gemini login on your CLIProxyAPI server. A login that matches an account on this Mac shows once. Your tokens stay on the proxy."))
            .font(.callout)
            .foregroundStyle(.secondary)
            .onAppear {
                draftURL = settings.cliProxyURL
                if hasKey { check(force: false) }
            }

        TextField(L("Server address"), text: $draftURL, prompt: Text(CLIProxyConfig.defaultURL))
            .textFieldStyle(.roundedBorder)
            .frame(width: 240)
            .onSubmit(connectionDidChange)
            .settingsRow(L("Server address"))

        if hasKey {
            LabeledContent(L("Management key")) {
                HStack {
                    Text(L("Saved"))
                        .foregroundStyle(.secondary)
                    Button(L("Remove")) { removeKey() }
                }
            }
        } else {
            LabeledContent(L("Management key")) {
                HStack {
                    SecureField(L("Management key"), text: $draftKey)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(width: 180)
                    Button(L("Save")) { saveKey() }
                        .disabled(draftKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        if let keyError {
            Text(keyError).font(.callout).foregroundStyle(Color.warningText)
        }

        if hasKey {
            HStack {
                Button(L("Check connection"), action: connectionDidChange)
                    .disabled(checking)
                if checking {
                    ProgressView().controlSize(.small)
                }
                if let checkResult {
                    Text(checkResult)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if !proxyEmails.isEmpty {
                Text(L("Allowance Bar uses the proxy login with the same email for each Claude Code login on this Mac: it shows the limits the proxy saw on recent messages, and reads through the proxy when the login on this Mac expires. Choose another login here if the emails differ."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(localClaudeProviderIDs, id: \.self) { providerID in
                    loginPicker(for: providerID)
                }
            }
        }
    }

    private func loginPicker(for providerID: String) -> some View {
        let name = store.providers.first { $0.id == providerID }?.displayName ?? providerID
        let title = String(format: L("%@ proxy login"), name)
        let selected = settings.cliProxyClaudeEmails[providerID]
        let options = proxyEmails + (selected.map { proxyEmails.contains($0) ? [] : [$0] } ?? [])
        return Picker(title, selection: Binding(
            get: { selected ?? "" },
            set: { newValue in
                settings.cliProxyClaudeEmails[providerID] = newValue.isEmpty ? nil : newValue
                store.credentialsDidChange(for: [providerID])
            }
        )) {
            Text(L("Same email as Claude Code")).tag("")
            ForEach(options, id: \.self) { email in
                Text(email).tag(email)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .settingsRow(title)
    }

    /// Checks first and refreshes afterwards, so a wrong key costs the proxy
    /// one failed check, not two.
    private func connectionDidChange() {
        settings.cliProxyURL = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasKey else { return }
        check(force: true) {
            store.credentialsDidChange(for: affectedProviderIDs)
        }
    }

    /// `force` skips the shared login list and a remembered failure.
    private func check(force: Bool, then completion: @escaping () -> Void = {}) {
        guard let config = CLIProxyConfig.current() else {
            checkResult = L("Enter a valid server address. A proxy on another Mac needs https or a Tailscale name ending in .ts.net.")
            proxyEmails = []
            completion()
            return
        }
        checking = true
        Task {
            let message: String
            do {
                let accounts = try await CLIProxyClient(config: config).logins(force: force)
                proxyEmails = accounts.filter { $0.kind == .claude }.map(\.email)
                let count = CLIProxyLoginKey.keys(from: accounts).count
                message = count == 0
                    ? L("Connected. CLIProxyAPI has no Claude, Codex, Antigravity or Gemini logins that are turned on.")
                    : String(format: L("Connected. Logins found: %lld."), count)
            } catch {
                proxyEmails = []
                message = error.localizedDescription
            }
            checking = false
            checkResult = message
            AccessibilityNotification.Announcement(message).post()
            completion()
        }
    }

    private func saveKey() {
        let key = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        guard KeychainStore.set(key, account: CLIProxyConfig.keychainAccount) else {
            keyError = L("Could not save the management key in Keychain. Please try again.")
            return
        }
        keyError = nil
        draftKey = ""
        hasKey = true
        connectionDidChange()
        AccessibilityNotification.Announcement(L("Management key saved")).post()
    }

    private func removeKey() {
        guard KeychainStore.delete(CLIProxyConfig.keychainAccount) else {
            keyError = L("Could not remove the management key from Keychain. Please try again.")
            return
        }
        keyError = nil
        hasKey = false
        checkResult = nil
        proxyEmails = []
        store.credentialsDidChange(for: affectedProviderIDs)
        AccessibilityNotification.Announcement(L("Management key removed")).post()
    }
}

private struct CodexSubscriptionSettings: View {
    let providerID: String
    @ObservedObject var settings: SettingsStore

    private var isTracking: Bool {
        settings.renewal(for: providerID) != nil
    }

    var body: some View {
        DisclosureGroup(L("Subscription")) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(L("Track renewal date"), isOn: Binding(
                    get: { isTracking },
                    set: { enabled in
                        if enabled {
                            let today = Calendar.current.startOfDay(for: Date())
                            settings.setRenewal(
                                SubscriptionRenewal(
                                    anchorDate: today,
                                    platform: .chatgpt,
                                    confirmedAt: nil,
                                    remindDaysBefore: 3
                                ),
                                for: providerID
                            )
                        } else {
                            settings.removeRenewal(for: providerID)
                        }
                    }
                ))

                if let renewal = settings.renewal(for: providerID) {
                    subscriptionForm(renewal)
                }
            }
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func subscriptionForm(_ renewal: SubscriptionRenewal) -> some View {
        DatePicker(
            L("Renews on"),
            selection: anchorDateBinding,
            displayedComponents: .date
        )
        .datePickerStyle(.compact)
        .fixedSize()
        .settingsRow(L("Renews on"))
        Picker(L("Billed through"), selection: platformBinding) {
            ForEach(SubscriptionRenewal.Platform.allCases, id: \.self) { platform in
                Text(platform.displayName).tag(platform)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .settingsRow(L("Billed through"))
        Picker(L("Remind me"), selection: remindDaysBinding) {
            Text(L("Off")).tag(0)
            Text(L("1 day before")).tag(1)
            Text(L("3 days before")).tag(3)
            Text(L("7 days before")).tag(7)
        }
        .pickerStyle(.menu)
        .fixedSize()
        .settingsRow(L("Remind me"))
        HStack {
            if let confirmedAt = renewal.confirmedAt {
                Text(String(
                    format: L("Last confirmed %@"),
                    confirmedAt.formatted(date: .abbreviated, time: .omitted)
                ))
            } else {
                Text(L("Not confirmed yet — check the platform that bills you."))
            }
            Spacer(minLength: 8)
            Button(L("I confirmed this date today")) {
                guard var updated = settings.renewal(for: providerID) else { return }
                updated.confirmedAt = Date()
                settings.setRenewal(updated, for: providerID)
            }
            .help(L("Marks today as the date you verified this renewal on your billing platform."))
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var anchorDateBinding: Binding<Date> {
        Binding(
            get: { settings.renewal(for: providerID)?.anchorDate ?? Date() },
            set: { newValue in
                guard var renewal = settings.renewal(for: providerID) else { return }
                renewal.anchorDate = newValue
                settings.setRenewal(renewal, for: providerID)
            }
        )
    }

    private var platformBinding: Binding<SubscriptionRenewal.Platform> {
        Binding(
            get: { settings.renewal(for: providerID)?.platform ?? .chatgpt },
            set: { newValue in
                guard var renewal = settings.renewal(for: providerID) else { return }
                renewal.platform = newValue
                settings.setRenewal(renewal, for: providerID)
            }
        )
    }

    private var remindDaysBinding: Binding<Int> {
        Binding(
            get: { settings.renewal(for: providerID)?.remindDaysBefore ?? 0 },
            set: { newValue in
                guard var renewal = settings.renewal(for: providerID) else { return }
                renewal.remindDaysBefore = newValue
                settings.setRenewal(renewal, for: providerID)
            }
        )
    }
}

private struct ProviderCredentialSection: View {
    let provider: any UsageProvider
    @ObservedObject var store: UsageStore
    @ObservedObject private var openRouterAuth = OpenRouterAuthFlow.shared
    @State private var draftKey = ""
    @State private var hasKey: Bool
    @State private var assessmentGeneration = 0
    @State private var credentialError: String?

    init(provider: any UsageProvider, store: UsageStore) {
        self.provider = provider
        self.store = store
        _hasKey = State(initialValue: KeychainStore.exists(provider.keychainAccount))
    }

    var body: some View {
        switch provider.authKind {
        case .localCredentials:
            if let help = provider.credentialHelpText, provider is CLIProxyAccountProvider {
                Text(help)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent(L("Status")) {
                    Text(provider.isDetected ? L("Detected") : L("Not detected"))
                        .foregroundStyle(.secondary)
                }
            }
        case .apiKey(let keyURL):
            Group {
                if let credentialError {
                    Text(credentialError).font(.callout).foregroundStyle(Color.warningText)
                }
                if let help = provider.credentialHelpText {
                    Text(help)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if ProviderAccountConfig.baseProviderID(of: provider.id) == "claude-api" {
                    Link(L("View prepaid credits"), destination: URL(string: "https://platform.claude.com/settings/billing")!)
                        .font(.callout)
                }
                if hasKey {
                    LabeledContent(provider.apiKeyPlaceholder) {
                        HStack {
                            Text(L("Saved"))
                                .foregroundStyle(.secondary)
                            Button(L("Remove")) { removeKey() }
                        }
                    }
                    CredentialAssessmentView(
                        provider: provider,
                        assessmentGeneration: assessmentGeneration
                    )
                } else {
                    keyEntryRow(title: provider.apiKeyPlaceholder, keyURL: URL(string: keyURL))
                }
            }
        case .oauth:
            Group {
                if let credentialError {
                    Text(credentialError).font(.callout).foregroundStyle(Color.warningText)
                }
                if hasKey {
                    LabeledContent(L("Status")) {
                        HStack {
                            Text(L("Connected"))
                                .foregroundStyle(.secondary)
                            Button(L("Disconnect")) { removeKey() }
                        }
                    }
                    CredentialAssessmentView(
                        provider: provider,
                        assessmentGeneration: assessmentGeneration
                    )
                } else {
                    LabeledContent(L("Account")) {
                        HStack {
                            if isAuthFlowTarget, openRouterAuth.status == .connecting {
                                ProgressView().controlSize(.small)
                                Text(L("Waiting for browser authorization…"))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Button(L("Connect…")) {
                                OpenRouterAuthFlow.shared.start(keychainAccount: provider.keychainAccount)
                            }
                            .disabled(openRouterAuth.status == .connecting)
                        }
                    }
                    if isAuthFlowTarget, case .failed(let message) = openRouterAuth.status {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(Color.warningText)
                    }
                    keyEntryRow(title: L("Or paste an API key"), keyURL: provider.dashboardURL)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .providerCredentialsChanged)) { _ in
                let connected = KeychainStore.exists(provider.keychainAccount)
                if connected && !hasKey {
                    assessmentGeneration += 1
                }
                hasKey = connected
            }
            .onChange(of: openRouterAuth.status) { _, newStatus in
                guard isAuthFlowTarget else { return }
                switch newStatus {
                case .connected:
                    AccessibilityNotification.Announcement(L("OpenRouter connected")).post()
                case .failed:
                    AccessibilityNotification.Announcement(L("Connection failed")).post()
                case .idle, .connecting:
                    break
                }
            }
        }
    }

    /// A key field with Save, and a link to the page that creates keys.
    private func keyEntryRow(title: String, keyURL: URL?) -> some View {
        LabeledContent {
            HStack {
                SecureField(title, text: $draftKey)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(width: 200)
                    .onSubmit(saveKey)
                Button(L("Save")) { saveKey() }
                    .disabled(draftKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let keyURL {
                    Link(L("Get key"), destination: keyURL)
                        .font(.callout)
                }
            }
        }
    }

    /// The OpenRouter connect flow belongs to this account.
    private var isAuthFlowTarget: Bool {
        openRouterAuth.targetKeychainAccount == provider.keychainAccount
    }

    private func saveKey() {
        let key = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        guard KeychainStore.set(key, account: provider.keychainAccount) else {
            credentialError = L("Could not save the API key in Keychain. Please try again.")
            return
        }
        credentialError = nil
        draftKey = ""
        hasKey = true
        assessmentGeneration += 1
        store.credentialDidChange(for: provider.id)
        AccessibilityNotification.Announcement(L("API key saved")).post()
    }

    private func removeKey() {
        guard KeychainStore.delete(provider.keychainAccount) else {
            credentialError = L("Could not remove the API key from Keychain. Please try again.")
            return
        }
        credentialError = nil
        hasKey = false
        store.credentialDidChange(for: provider.id)
        AccessibilityNotification.Announcement(L("API key removed")).post()
    }
}

private struct CredentialAssessmentView: View {
    let provider: any UsageProvider
    let assessmentGeneration: Int
    @State private var assessment: CredentialAssessment?
    @State private var isAssessing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isAssessing {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L("Checking key…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if let assessment {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(assessment.keyTypeLabel)
                        .font(.subheadline)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .help(assessment.summary)
                    Text(assessment.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    String(
                        format: L("Key type: %@. %@"),
                        assessment.keyTypeLabel,
                        assessment.summary
                    )
                )

                DisclosureGroup(L("About this key")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(assessment.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if let hint = assessment.upgradeHint {
                            Text(hint)
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                        if let url = assessment.manageURL {
                            Link(L("Manage keys"), destination: url)
                                .font(.callout)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
                .font(.callout)
            }
        }
        .task(id: assessmentGeneration) {
            isAssessing = true
            assessment = await provider.assessCredential()
            isAssessing = false
        }
    }
}

private struct DisplaySettingsTab: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        SettingsPage {
            SettingsGroup {
                Picker(L("Count direction"), selection: $settings.countDirection) {
                    Text(L("% used")).tag(CountDirection.used)
                    Text(L("% left")).tag(CountDirection.remaining)
                }
                .settingsSegmented()
                .settingsRow(L("Count direction"))

                Picker(L("Reset times"), selection: $settings.resetTimeStyle) {
                    Text(L("Relative")).tag(ResetTimeStyle.relative)
                    Text(L("Exact")).tag(ResetTimeStyle.absolute)
                }
                .settingsSegmented()
                .settingsRow(L("Reset times"))

                // A pop-up menu: the three labels are too long for a segmented
                // control at this width.
                Picker(L("Menu bar style"), selection: $settings.menuBarStyle) {
                    Text(L("Full")).tag(MenuBarStyle.full)
                    Text(L("Compact (worst only)")).tag(MenuBarStyle.compact)
                    Text(L("Icon only")).tag(MenuBarStyle.icon)
                }
                .pickerStyle(.menu)
                .fixedSize()
                .settingsRow(L("Menu bar style"))

                Toggle(L("Show all limits in the menu bar"), isOn: $settings.menuBarShowsAllLimits)
                    .disabled(settings.menuBarStyle == .icon)

                Toggle(L("Show all limits in the nano window"), isOn: $settings.nanoShowsAllLimits)
            } footer: {
                SettingsNote(L("Shows every limit in dropdown order, e.g. “Cx 8% (35%)” for the Codex 5-hour and weekly limits."))
            }

            SettingsGroup {
                Toggle(L("Show pace"), isOn: $settings.showsPace)
                Toggle(L("Show pace in the nano window"), isOn: $settings.nanoShowsPace)
            } footer: {
                SettingsNote(L("A line on each bar marks even pace: where usage would be if spread evenly until the reset. An arrow shows if you are ahead of pace (↗, may run out early), on pace (→) or under pace (↘, room to spare). The nano window shows only the arrow, after each percent."))
            }

            SettingsGroup {
                Toggle(L("Show CLIProxyAPI priority"), isOn: $settings.showsProxyPriority)
                Toggle(L("Show CLIProxyAPI priority in the nano window"), isOn: $settings.nanoShowsProxyPriority)
            } footer: {
                SettingsNote(L("Shows each account's place among its provider's logins in CLIProxyAPI's order of use, e.g. “Proxy #1”, from the login priorities. The proxy sends new requests to the highest priority first. It shows when the proxy has more than one login of a provider with different priorities. The nano window shows only “#1”, after each entry."))
            }
        }
    }
}

private struct AlertsSettingsTab: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: SettingsStore

    private var countsDown: Bool { settings.countDirection == .remaining }

    var body: some View {
        SettingsPage {
            SettingsGroup {
                Toggle(L("Alert when usage crosses threshold"), isOn: $settings.notificationsEnabled)
                    .onChange(of: settings.notificationsEnabled) { _, enabled in
                        if enabled {
                            store.notificationManager.requestAuthorizationIfNeeded()
                        }
                    }

                // Thresholds are stored as used-percent; only the labels adapt
                // to the count direction, so the alert fires at the same real
                // usage level in either display mode.
                VStack(alignment: .leading, spacing: 8) {
                    Text(thresholdTitle)
                    Picker(thresholdTitle, selection: $settings.notificationThreshold) {
                        ForEach(SettingsStore.notificationThresholdOptions, id: \.self) { value in
                            Text(countsDown
                                ? L("\(Int(100 - value))% left")
                                : L("\(Int(value))%")
                            ).tag(value)
                        }
                    }
                    .settingsSegmented()
                    .labelsHidden()
                    .disabled(!settings.notificationsEnabled)
                    .modifier(DisabledControlAccessibilityHint(
                        isDisabled: !settings.notificationsEnabled,
                        hint: L("Enable notifications to change this.")
                    ))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Balance alert below"))
                    Picker(L("Balance alert below"), selection: $settings.balanceNotificationThreshold) {
                        ForEach(SettingsStore.balanceThresholdOptions, id: \.self) { value in
                            Text("$\(Int(value))").tag(value)
                        }
                    }
                    .settingsSegmented()
                    .labelsHidden()
                    .disabled(!settings.notificationsEnabled)
                    .modifier(DisabledControlAccessibilityHint(
                        isDisabled: !settings.notificationsEnabled,
                        hint: L("Enable notifications to change this.")
                    ))
                }
            } footer: {
                SettingsNote(countsDown
                    ? L("One notification per limit window, re-armed when the window resets. \"20% left\" is the same alert as \"80% used\" — it follows your Display setting.")
                    : L("One notification per limit window, re-armed when the window resets. Balance alerts apply to pay-as-you-go providers.")
                )
            }

            SettingsGroup {
                Toggle(L("Alert when a limit runs ahead of pace"), isOn: $settings.paceNotificationsEnabled)
                    .onChange(of: settings.paceNotificationsEnabled) { _, enabled in
                        if enabled {
                            store.notificationManager.requestAuthorizationIfNeeded()
                        }
                    }
            } footer: {
                SettingsNote(L("Notifies once per limit window when usage is 15 or more points ahead of even pace, after the first 10% of the window. At that rate the limit runs out before it resets."))
            }
        }
    }

    private var thresholdTitle: String {
        countsDown ? L("Alert when remaining falls below") : L("Alert when usage reaches")
    }
}

private struct DisabledControlAccessibilityHint: ViewModifier {
    let isDisabled: Bool
    let hint: String

    func body(content: Content) -> some View {
        if isDisabled {
            content.accessibilityHint(hint)
        } else {
            content
        }
    }
}
