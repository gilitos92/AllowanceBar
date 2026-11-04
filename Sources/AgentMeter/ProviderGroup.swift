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

    /// The name of one account inside its group: an extra account's label,
    /// a proxy login's email, or for the default account the signed-in email
    /// when the provider knows it.
    func accountName(of provider: any UsageProvider, usage: ProviderUsage?) -> String {
        if provider.id == baseID {
            if let email = usage?.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines),
               !email.isEmpty {
                return email
            }
            return L("Default account")
        }
        let prefix = "\(baseName) — "
        if provider.displayName.hasPrefix(prefix) {
            let name = String(provider.displayName.dropFirst(prefix.count))
            if !name.isEmpty { return name }
        }
        return provider.displayName
    }

    /// The signed-in email to show next to an account's name, when it adds
    /// something (an extra account named "Work", not a proxy row named by
    /// its email).
    func accountDetail(of provider: any UsageProvider, usage: ProviderUsage?) -> String? {
        guard let email = usage?.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty,
              email.caseInsensitiveCompare(accountName(of: provider, usage: usage)) != .orderedSame
        else { return nil }
        return email
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
