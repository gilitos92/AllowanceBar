import SwiftUI
import ServiceManagement

struct SettingsRootView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: SettingsStore

    var body: some View {
        TabView {
            GeneralSettingsTab(store: store, settings: settings)
                .tabItem {
                    Label(L("General"), systemImage: "gearshape")
                }
            ProvidersSettingsTab(store: store, settings: settings)
                .tabItem {
                    Label(L("Providers"), systemImage: "list.bullet")
                }
            DisplaySettingsTab(settings: settings)
                .tabItem {
                    Label(L("Display"), systemImage: "eye")
                }
            AlertsSettingsTab(store: store, settings: settings)
                .tabItem {
                    Label(L("Alerts"), systemImage: "bell")
                }
        }
        .frame(width: 500, height: 420)
    }
}

private struct GeneralSettingsTab: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: SettingsStore
    @Environment(\.openWindow) private var openWindow
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var diagnosticsCopied = false
    @State private var cliInstallPath: String?
    @State private var cliInstallResultMessage: String?

    var body: some View {
        Form {
            Section {
                Toggle(L("Launch at Login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
            }
            Section {
                Toggle(L("Enable agent & CLI access"), isOn: $settings.agentAccessEnabled)
                    .onChange(of: settings.agentAccessEnabled) { _, enabled in
                        if enabled {
                            StatusSnapshotWriter.writeIfEnabled(store: store, settings: settings)
                        }
                    }

                cliToolInstallSection
            } footer: {
                Text(L("Writes a machine-readable usage snapshot (never credentials) to Application Support for the allowancebar command-line tool and other local agents."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
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
            }
            Section {
                Button {
                    copyDiagnostics()
                } label: {
                    if diagnosticsCopied {
                        Label(L("Copied"), systemImage: "checkmark")
                    } else {
                        Text(L("Copy Diagnostics"))
                    }
                }
            } footer: {
                Text(L("Copies redacted troubleshooting info to the clipboard — never includes keys or tokens."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button(L("About Allowance Bar")) {
                    openWindow(id: "about")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
        .formStyle(.grouped)
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

private struct ProvidersSettingsTab: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Form {
            ForEach(store.providers, id: \.id) { provider in
                Section {
                    Picker(L("Mode"), selection: Binding(
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
                    .pickerStyle(.segmented)

                    if settings.mode(for: provider.id) != .off {
                        Toggle(L("Show in menu bar"), isOn: Binding(
                            get: { settings.showsInMenuBar(provider.id) },
                            set: { settings.setShowsInMenuBar($0, for: provider.id) }
                        ))
                    }

                    ProviderCredentialSection(provider: provider, store: store)

                    if !provider.id.contains(":"),
                       let support = ProviderAccountSupport.support(for: provider.id) {
                        ProviderAccountsSection(
                            provider: provider,
                            support: support,
                            store: store,
                            settings: settings
                        )
                    }

                    if provider.id == "claude" {
                        CLIProxySection(store: store, settings: settings)
                    }
                } header: {
                    HStack(spacing: 6) {
                        ProviderBadge(provider: provider, size: 18)
                        Text(provider.displayName)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Optional CLIProxyAPI server that answers for Claude logins whose Claude
/// Code token has expired or is missing on this Mac.
private struct CLIProxySection: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: SettingsStore
    @State private var hasKey = CLIProxyConfig.isConfigured
    @State private var draftKey = ""
    @State private var keyError: String?
    @State private var checking = false
    @State private var checkResult: String?
    @State private var proxyEmails: [String] = []

    private var claudeProviderIDs: [String] {
        store.providers.map(\.id).filter { ProviderAccountConfig.baseProviderID(of: $0) == "claude" }
    }

    var body: some View {
        Group {
            Text(L("CLIProxyAPI"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(L("When Claude Code sends requests through CLIProxyAPI, its own login stops renewing. Allowance Bar can then ask the proxy for usage. Your Claude tokens stay on the proxy."))
                .font(.subheadline)
                .foregroundStyle(.tertiary)

            TextField(L("Server address"), text: $settings.cliProxyURL, prompt: Text(CLIProxyConfig.defaultURL))
                .onSubmit(connectionDidChange)

            if hasKey {
                LabeledContent(L("Management key")) {
                    HStack {
                        Text(L("Saved"))
                        Button(L("Remove")) { removeKey() }
                    }
                }
            } else {
                SecureField(L("Management key"), text: $draftKey)
                Button(L("Save")) { saveKey() }
                    .disabled(draftKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let keyError {
                Text(keyError).font(.callout).foregroundStyle(.orange)
            }

            if hasKey {
                HStack {
                    Button(L("Check connection"), action: connectionDidChange)
                        .disabled(checking)
                    if checking {
                        ProgressView().controlSize(.small)
                    }
                }
                if let checkResult {
                    Text(checkResult).font(.callout).foregroundStyle(.secondary)
                }
                if !proxyEmails.isEmpty {
                    ForEach(claudeProviderIDs, id: \.self) { providerID in
                        loginPicker(for: providerID)
                    }
                }
            }
        }
        .onAppear {
            if hasKey { check() }
        }
    }

    private func loginPicker(for providerID: String) -> some View {
        let name = store.providers.first { $0.id == providerID }?.displayName ?? providerID
        let selected = settings.cliProxyClaudeEmails[providerID]
        let options = proxyEmails + (selected.map { proxyEmails.contains($0) ? [] : [$0] } ?? [])
        return Picker(String(format: L("%@ proxy login"), name), selection: Binding(
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
    }

    private func connectionDidChange() {
        store.credentialsDidChange(for: claudeProviderIDs)
        check()
    }

    private func check() {
        guard let config = CLIProxyConfig.current() else {
            checkResult = L("Enter a valid server address, such as http://127.0.0.1:8317.")
            proxyEmails = []
            return
        }
        checking = true
        Task {
            let message: String
            do {
                let accounts = try await CLIProxyClient(config: config).claudeAccounts()
                proxyEmails = accounts.map(\.email)
                message = accounts.isEmpty
                    ? L("Connected. CLIProxyAPI has no Claude logins.")
                    : String(format: L("Connected. Claude logins found: %lld."), accounts.count)
            } catch {
                proxyEmails = []
                message = error.localizedDescription
            }
            checking = false
            checkResult = message
            AccessibilityNotification.Announcement(message).post()
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
        store.credentialsDidChange(for: claudeProviderIDs)
        AccessibilityNotification.Announcement(L("Management key removed")).post()
    }
}

private struct ProviderAccountsSection: View {
    let provider: any UsageProvider
    let support: ProviderAccountSupport
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: SettingsStore
    @State private var showingAddForm = false
    @State private var draftLabel = ""
    @State private var draftHomePath = ""
    @State private var addFormError: String?
    @State private var discoveredAccounts: [ProviderAccountDiscovery.Candidate] = []
    @State private var renamingAccountID: UUID?
    @State private var renameDraft = ""

    private var isCodex: Bool { provider.id == "codex" }
    private var accounts: [ProviderAccountConfig] { settings.accounts(for: provider.id) }

    var body: some View {
        Group {
            Text(String(format: L("%@ accounts"), provider.displayName))
                .font(.callout)
                .foregroundStyle(.secondary)

            if let folder = support.folder {
                defaultAccountRow(folder)
            }

            ForEach(accounts) { account in
                extraAccountRow(account)
            }

            ForEach(discoveredAccounts) { candidate in
                discoveredAccountRow(candidate)
            }

            if showingAddForm {
                addAccountForm
            } else {
                Button(L("Add account…")) {
                    draftLabel = ""
                    draftHomePath = support.folder.map {
                        ProviderAccountSupport.suggestedHomePath(prefix: $0.suggestedPrefix, label: "")
                    } ?? ""
                    showingAddForm = true
                    addFormError = nil
                }
                .accessibilityLabel(String(format: L("Add %@ account"), provider.displayName))
            }

            if isCodex {
                Text(L("OpenAI doesn't publish subscription renewal dates, so confirm yours on the platform that bills you — ChatGPT, Apple, or Google Play. Renewal dates are separate from usage-limit resets."))
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }

            switch support.credential {
            case .folder:
                Text(L("Removing only forgets the path; it does not sign out."))
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            case .apiKey:
                Text(L("Each account gets its own section below for its key. Removing an account deletes its saved key from Allowance Bar."))
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
        }
        .onAppear(perform: refreshDiscovered)
        .onChange(of: settings.extraAccounts) { _, _ in refreshDiscovered() }
    }

    private func refreshDiscovered() {
        guard let folder = support.folder else {
            discoveredAccounts = []
            return
        }
        discoveredAccounts = ProviderAccountDiscovery.discover(folder: folder, configured: accounts)
    }

    private func discoveredAccountRow(_ candidate: ProviderAccountDiscovery.Candidate) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: L("Found %@ account: %@"), provider.displayName, candidate.suggestedLabel))
                    .font(.callout)
                Text(candidate.homePath)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(L("Add")) {
                settings.addAccount(ProviderAccountConfig(
                    baseProviderID: provider.id,
                    label: candidate.suggestedLabel,
                    homePath: candidate.homePath
                ))
                refreshDiscovered()
            }
            .font(.callout)
            .help(L("Adds this account to Allowance Bar using the folder name as its label."))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(format: L("Found %@ account: %@"), provider.displayName, candidate.homePath))
    }

    private func defaultAccountRow(_ folder: ProviderAccountSupport.Folder) -> some View {
        let status = accountStatus(providerID: provider.id)
        let title = String(format: L("Default (%@)"), folder.defaultPath)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.callout)
                Spacer()
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(String(format: L("%@, %@"), title, status))

            if isCodex {
                CodexSubscriptionSettings(providerID: provider.id, settings: settings)
            }
        }
    }

    private func extraAccountRow(_ account: ProviderAccountConfig) -> some View {
        let status = accountStatus(providerID: account.providerID)
        let detail = account.homePath ?? status
        return VStack(alignment: .leading, spacing: 6) {
            if renamingAccountID == account.id {
                renameForm(account)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.label)
                            .font(.callout)
                        if let homePath = account.homePath {
                            Text(homePath)
                                .font(.subheadline.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if account.homePath != nil {
                        Text(status)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    Button(L("Rename")) {
                        renameDraft = account.label
                        renamingAccountID = account.id
                    }
                    .font(.callout)
                    .accessibilityLabel(String(format: L("Rename %@"), account.label))
                    Button(L("Remove")) { remove(account) }
                        .font(.callout)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(String(format: L("%@, %@, %@"), account.label, detail, status))
            }

            if isCodex {
                CodexSubscriptionSettings(providerID: account.providerID, settings: settings)
            }
        }
    }

    private func renameForm(_ account: ProviderAccountConfig) -> some View {
        let isValid = !renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(alignment: .firstTextBaseline) {
            TextField(L("Label"), text: $renameDraft)
                .onSubmit { if isValid { saveRename(account) } }
            Button(L("Save")) { saveRename(account) }
                .disabled(!isValid)
            Button(L("Cancel"), role: .cancel) { renamingAccountID = nil }
        }
        .font(.callout)
    }

    private func saveRename(_ account: ProviderAccountConfig) {
        settings.renameAccount(id: account.id, to: renameDraft)
        renamingAccountID = nil
        AccessibilityNotification.Announcement(String(format: L("Renamed to %@"), renameDraft)).post()
    }

    private func remove(_ account: ProviderAccountConfig) {
        if case .apiKey = support.credential {
            KeychainStore.delete("apikey.\(account.providerID)")
        }
        settings.removeAccount(id: account.id)
        AccessibilityNotification.Announcement(String(format: L("%@ removed"), account.label)).post()
    }

    private func accountStatus(providerID: String) -> String {
        if isCodex {
            return codexAccountStatus(providerID: providerID)
        }
        switch store.states[providerID] {
        case .error(let message):
            return message
        case .loading, nil:
            return L("Loading…")
        case .ready(let usage), .stale(let usage, _, _):
            return usage.planName ?? L("Connected")
        }
    }

    private func codexAccountStatus(providerID: String) -> String {
        if let state = store.states[providerID] {
            switch state {
            case .error(let message):
                return message
            case .loading:
                return L("Loading…")
            case .ready(let usage), .stale(let usage, _, _):
                if let email = CodexAccountCache.shared.lastEmail(for: providerID) {
                    let plan = usage.planName ?? CodexPlan.displayName(
                        CodexAccountCache.shared.lastPlanType(for: providerID)
                    )
                    if let plan {
                        return "\(email) · \(plan)"
                    }
                    return email
                }
                return L("Not signed in")
            }
        }
        if let email = CodexAccountCache.shared.lastEmail(for: providerID) {
            let plan = CodexPlan.displayName(CodexAccountCache.shared.lastPlanType(for: providerID))
            if let plan { return "\(email) · \(plan)" }
            return email
        }
        return L("Not signed in")
    }

    private var addAccountForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(L("Label"), text: $draftLabel)
                .onChange(of: draftLabel) { _, newValue in
                    guard let folder = support.folder else { return }
                    if draftHomePath.isEmpty || draftHomePath.hasPrefix(folder.suggestedPrefix) {
                        draftHomePath = ProviderAccountSupport.suggestedHomePath(
                            prefix: folder.suggestedPrefix,
                            label: newValue
                        )
                    }
                }

            if let folder = support.folder {
                folderFields(folder)
            }

            if let addFormError {
                Text(addFormError)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            HStack {
                Button(L("Save")) { saveAccount() }
                    .disabled(!isAddFormValid)
                Button(L("Cancel"), role: .cancel) {
                    showingAddForm = false
                    addFormError = nil
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func folderFields(_ folder: ProviderAccountSupport.Folder) -> some View {
        let loginCommand = folder.loginCommand(draftHomePath)
        TextField(L("Folder"), text: $draftHomePath)
            .font(.callout.monospaced())

        Text(loginCommand)
            .font(.callout.monospaced())
            .textSelection(.enabled)
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))

        Button(L("Copy login command")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(loginCommand, forType: .string)
            AccessibilityNotification.Announcement(L("Login command copied")).post()
        }
        .font(.callout)
        .accessibilityLabel(L("Copy login command"))
        .accessibilityHint(String(format: L("Copies the Terminal command to sign in this %@ account"), provider.displayName))

        Text(String(format: L("Run this in Terminal to sign in that account. Allowance Bar never handles your login or tokens — %@ does."), folder.loginTool))
            .font(.subheadline)
            .foregroundStyle(.secondary)
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
            baseProviderID: provider.id,
            label: trimmedLabel,
            homePath: support.folder == nil ? nil : trimmedPath
        ))
        showingAddForm = false
        addFormError = nil
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
        .font(.callout)
    }

    @ViewBuilder
    private func subscriptionForm(_ renewal: SubscriptionRenewal) -> some View {
        DatePicker(
            L("Renews on"),
            selection: anchorDateBinding,
            displayedComponents: .date
        )
        Picker(L("Billed through"), selection: platformBinding) {
            ForEach(SubscriptionRenewal.Platform.allCases, id: \.self) { platform in
                Text(platform.displayName).tag(platform)
            }
        }
        Picker(L("Remind me"), selection: remindDaysBinding) {
            Text(L("Off")).tag(0)
            Text(L("1 day before")).tag(1)
            Text(L("3 days before")).tag(3)
            Text(L("7 days before")).tag(7)
        }
        Button(L("I confirmed this date today")) {
            guard var updated = settings.renewal(for: providerID) else { return }
            updated.confirmedAt = Date()
            settings.setRenewal(updated, for: providerID)
        }
        .help(L("Marks today as the date you verified this renewal on your billing platform."))

        if let confirmedAt = renewal.confirmedAt {
            Text(String(
                format: L("Last confirmed %@"),
                confirmedAt.formatted(date: .abbreviated, time: .omitted)
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
        } else {
            Text(L("Not confirmed yet — check the platform that bills you."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
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
            LabeledContent(L("Status"), value: provider.isDetected ? L("Detected") : L("Not detected"))
        case .apiKey(let keyURL):
            Group {
                if let credentialError {
                    Text(credentialError).font(.callout).foregroundStyle(.orange)
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
                            Button(L("Remove")) { removeKey() }
                        }
                    }
                    CredentialAssessmentView(
                        provider: provider,
                        assessmentGeneration: assessmentGeneration
                    )
                } else {
                    SecureField(provider.apiKeyPlaceholder, text: $draftKey)
                    HStack {
                        Button(L("Save")) { saveKey() }
                            .disabled(draftKey.trimmingCharacters(in: .whitespaces).isEmpty)
                        if let url = URL(string: keyURL) {
                            Link(L("Get key"), destination: url)
                        }
                    }
                }
            }
        case .oauth:
            Group {
                if let credentialError {
                    Text(credentialError).font(.callout).foregroundStyle(.orange)
                }
                if hasKey {
                    LabeledContent(L("Status")) {
                        HStack {
                            Text(L("Connected"))
                            Button(L("Disconnect")) { removeKey() }
                        }
                    }
                    CredentialAssessmentView(
                        provider: provider,
                        assessmentGeneration: assessmentGeneration
                    )
                } else {
                    HStack {
                        Button(L("Connect…")) {
                            OpenRouterAuthFlow.shared.start(keychainAccount: provider.keychainAccount)
                        }
                        .disabled(openRouterAuth.status == .connecting)
                        if isAuthFlowTarget, openRouterAuth.status == .connecting {
                            ProgressView().controlSize(.small)
                            Text(L("Waiting for browser authorization…"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if isAuthFlowTarget, case .failed(let message) = openRouterAuth.status {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    SecureField(L("Or paste an API key"), text: $draftKey)
                    HStack {
                        Button(L("Save")) { saveKey() }
                            .disabled(draftKey.trimmingCharacters(in: .whitespaces).isEmpty)
                        if let url = provider.dashboardURL {
                            Link(L("Get key"), destination: url)
                        }
                    }
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
        Form {
            Section {
                Picker(L("Count direction"), selection: $settings.countDirection) {
                    Text(L("% used")).tag(CountDirection.used)
                    Text(L("% left")).tag(CountDirection.remaining)
                }
                .pickerStyle(.segmented)

                Picker(L("Reset times"), selection: $settings.resetTimeStyle) {
                    Text(L("Relative")).tag(ResetTimeStyle.relative)
                    Text(L("Exact")).tag(ResetTimeStyle.absolute)
                }
                .pickerStyle(.segmented)

                Picker(L("Menu bar style"), selection: $settings.menuBarStyle) {
                    Text(L("Full")).tag(MenuBarStyle.full)
                    Text(L("Compact (worst only)")).tag(MenuBarStyle.compact)
                    Text(L("Icon only")).tag(MenuBarStyle.icon)
                }
                .pickerStyle(.segmented)

                Toggle(L("Show all limits in the menu bar"), isOn: $settings.menuBarShowsAllLimits)
                    .disabled(settings.menuBarStyle == .icon)

                Toggle(L("Show all limits in the nano window"), isOn: $settings.nanoShowsAllLimits)
            } footer: {
                Text(L("Shows every limit in dropdown order, e.g. “Cx 8% (35%)” for the Codex 5-hour and weekly limits."))
            }
        }
        .formStyle(.grouped)
    }
}

private struct AlertsSettingsTab: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: SettingsStore

    private var countsDown: Bool { settings.countDirection == .remaining }

    var body: some View {
        Form {
            Section {
                Toggle(L("Alert when usage crosses threshold"), isOn: $settings.notificationsEnabled)
                    .onChange(of: settings.notificationsEnabled) { _, enabled in
                        if enabled {
                            store.notificationManager.requestAuthorizationIfNeeded()
                        }
                    }

                // Thresholds are stored as used-percent; only the labels adapt
                // to the count direction, so the alert fires at the same real
                // usage level in either display mode.
                Picker(
                    countsDown ? L("Alert when remaining falls below") : L("Alert when usage reaches"),
                    selection: $settings.notificationThreshold
                ) {
                    ForEach(SettingsStore.notificationThresholdOptions, id: \.self) { value in
                        Text(countsDown
                            ? L("\(Int(100 - value))% left")
                            : L("\(Int(value))%")
                        ).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!settings.notificationsEnabled)
                .modifier(DisabledControlAccessibilityHint(
                    isDisabled: !settings.notificationsEnabled,
                    hint: L("Enable notifications to change this.")
                ))

                Picker(L("Balance alert below"), selection: $settings.balanceNotificationThreshold) {
                    ForEach(SettingsStore.balanceThresholdOptions, id: \.self) { value in
                        Text("$\(Int(value))").tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!settings.notificationsEnabled)
                .modifier(DisabledControlAccessibilityHint(
                    isDisabled: !settings.notificationsEnabled,
                    hint: L("Enable notifications to change this.")
                ))
            } footer: {
                Text(countsDown
                    ? L("One notification per limit window, re-armed when the window resets. \"20% left\" is the same alert as \"80% used\" — it follows your Display setting.")
                    : L("One notification per limit window, re-armed when the window resets. Balance alerts apply to pay-as-you-go providers.")
                )
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
