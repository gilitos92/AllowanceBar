import Foundation

/// Where a login stands in CLIProxyAPI's order of use.
///
/// The proxy sends new requests to the enabled logins with the highest
/// priority first, and moves to the next priority only when those can't take
/// them (CLIProxyAPI `sdk/cliproxy/auth/selector.go`). Logins with the same
/// priority share a place. A login without a priority counts as 0.
///
/// The place counts only logins of the same provider, like the Mac mini
/// usage dashboard. When several providers serve the same model, the proxy
/// can also rank them together; the text says "among Claude logins" so the
/// place isn't read as the proxy's whole order.
struct ProxyPriority: Equatable, Sendable {
    /// The provider whose logins are ranked.
    let kind: CLIProxyLoginKind
    /// The login's priority on the proxy.
    let priority: Int
    /// 1 = used first: one more than the number of logins with a higher priority.
    let place: Int
    /// Enabled logins of the same kind on the proxy.
    let loginCount: Int

    /// The place of `login` among the proxy's enabled logins of its kind.
    /// Nil when the order says nothing: the login is missing or turned off,
    /// it is the kind's only login, or all its logins share one priority.
    static func of(_ login: CLIProxyLoginKey, in accounts: [CLIProxyClient.Account]) -> ProxyPriority? {
        let enabled = accounts.filter { !$0.disabled && $0.kind == login.kind }
        guard enabled.count > 1,
              Set(enabled.map(\.priority)).count > 1,
              let account = enabled.first(where: login.matches) else { return nil }
        let ahead = enabled.filter { $0.priority > account.priority }.count
        return ProxyPriority(kind: login.kind, priority: account.priority, place: ahead + 1, loginCount: enabled.count)
    }

    /// Short text for the nano and compact panels, e.g. "#1".
    var shortLabel: String { "#\(place)" }

    /// Text for the provider sections' capsule, e.g. "Proxy #1".
    var label: String { L("Proxy #\(place)") }

    /// Tooltip that explains the place.
    var explanation: String {
        L("Place \(place) of \(loginCount) among \(kind.displayName) logins in CLIProxyAPI's order of use (priority \(priority)). The proxy sends new requests to the highest priority first.")
    }

    /// Spoken value, e.g. "place 1 of 3 among Claude logins in CLIProxyAPI order, priority 3".
    var phrase: String {
        L("place \(place) of \(loginCount) among \(kind.displayName) logins in CLIProxyAPI order, priority \(priority)")
    }
}
