import Foundation

/// The shown providers grouped by base provider, so several accounts of one
/// provider (extra accounts and CLIProxyAPI logins) share one header, e.g.
/// three Claude logins under one "Claude" heading.
struct ProviderGroup: Identifiable {
    let baseID: String
    /// In the order they were shown before grouping.
    let members: [any UsageProvider]

    var id: String { baseID }

    /// Base provider name for the shared header, e.g. "Claude".
    var baseName: String { identity.name }
    /// Base short code for the shared header's badge, e.g. "Cl".
    var baseShortCode: String { identity.shortCode }

    /// Groups providers by base provider. A group takes the place of its
    /// first member, so the provider order stays as it was.
    static func groups(_ providers: [any UsageProvider]) -> [ProviderGroup] {
        var order: [String] = []
        var members: [String: [any UsageProvider]] = [:]
        for provider in providers {
            let base = ProviderAccountConfig.baseProviderID(of: provider.id)
            if members[base] == nil { order.append(base) }
            members[base, default: []].append(provider)
        }
        return order.compactMap { base in
            members[base].map { ProviderGroup(baseID: base, members: $0) }
        }
    }

    /// How one account is named inside its group.
    struct AccountLabel: Equatable {
        /// An extra account's label, a proxy login's email, or for the
        /// default account its signed-in email ("Default account" when unknown).
        let name: String
        /// The signed-in email when it adds something, or where the account
        /// comes from when two accounts would otherwise look the same.
        let detail: String?
    }

    /// Labels for every member, keyed by provider id. `emails` holds each
    /// account's signed-in email, when known.
    func accountLabels(emails: [String: String]) -> [String: AccountLabel] {
        var labels: [String: AccountLabel] = [:]
        for provider in members {
            let email = emails[provider.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let knownEmail = (email?.isEmpty ?? true) ? nil : email
            let name = accountName(of: provider, email: knownEmail)
            let detail = knownEmail.flatMap { $0.caseInsensitiveCompare(name) == .orderedSame ? nil : $0 }
            labels[provider.id] = AccountLabel(name: name, detail: detail)
        }
        // The local login and a CLIProxyAPI login of the same email can both
        // show; say where each comes from so they don't look identical.
        // Accounts already told apart by their email keep it as it is.
        let counts = Dictionary(grouping: labels.values.map(Self.comparisonKey), by: { $0 }).mapValues(\.count)
        for provider in members {
            guard let label = labels[provider.id], (counts[Self.comparisonKey(label)] ?? 0) > 1 else { continue }
            let source: String
            if let proxy = provider as? CLIProxyAccountProvider {
                // One Gemini email can have a login per project.
                source = ["CLIProxyAPI", proxy.login.projectID].compactMap { $0 }.joined(separator: " · ")
            } else {
                source = L("This Mac")
            }
            let detail = [label.detail, source].compactMap { $0 }.joined(separator: " · ")
            labels[provider.id] = AccountLabel(name: label.name, detail: detail)
        }
        return labels
    }

    private static func comparisonKey(_ label: AccountLabel) -> String {
        "\(label.name.lowercased())\n\(label.detail?.lowercased() ?? "")"
    }

    private func accountName(of provider: any UsageProvider, email: String?) -> String {
        if provider.id == baseID {
            return email ?? L("Default account")
        }
        let prefix = "\(baseName) — "
        if provider.displayName.hasPrefix(prefix) {
            let name = String(provider.displayName.dropFirst(prefix.count))
            if !name.isEmpty { return name }
        }
        return provider.displayName
    }

    /// The plan shared by every account with a known plan, shown once in the
    /// header. Nil when accounts have different plans or none is known yet.
    static func sharedPlan(of usages: [ProviderUsage?]) -> String? {
        let plans = Set(usages.compactMap { $0?.planName })
        guard plans.count == 1, usages.allSatisfy({ $0 == nil || $0?.planName != nil }) else { return nil }
        return plans.first
    }

    private var identity: (name: String, shortCode: String) {
        if let base = members.first(where: { $0.id == baseID }) {
            return (base.displayName, base.shortCode)
        }
        if let known = Self.baseIdentities[baseID] {
            return known
        }
        let first = members.first
        return (first?.displayName ?? baseID, first?.shortCode ?? "")
    }

    /// Names and badge codes of every base provider, including proxy-only
    /// ones like Antigravity, for groups whose default account is hidden.
    private static let baseIdentities: [String: (name: String, shortCode: String)] = {
        var identities: [String: (name: String, shortCode: String)] = [:]
        for kind in CLIProxyLoginKind.allCases {
            identities[kind.baseProviderID] = (kind.displayName, kind.shortCode)
        }
        for provider in UsageStore.defaultProviders(extraAccounts: []) {
            identities[provider.id] = (provider.displayName, provider.shortCode)
        }
        return identities
    }()
}
