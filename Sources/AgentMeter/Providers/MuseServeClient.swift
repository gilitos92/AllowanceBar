import Foundation

/// Muse Code subscription usage as `usage/refresh` reports it.
struct MuseUsageReading: Equatable, Sendable {
    /// The plan's display name, e.g. "Power Usage".
    let tierName: String?
    /// The plan's id, used only when Muse Code sends no display name.
    let tierID: String?
    /// The current window (about five hours).
    let window: MuseWindow?
    let weekly: MuseWindow?
    /// When Muse Code received the numbers.
    let observedAt: Date?
    /// The signed-in Meta account, when Muse Code names it.
    let accountLabel: String?
}

struct MuseWindow: Equatable, Sendable {
    let usedPercent: Double
    let resetsAt: Date?
    /// Nil for the weekly window, whose length Muse Code does not send.
    let minutes: Int?
}

enum MuseServeError: LocalizedError, Equatable {
    case museNotFound
    case notSignedIn
    case notSignedInExtraAccount
    case apiKeyOnly
    case noSubscription
    case noUsageData
    case rateLimited(retryAfter: TimeInterval?)
    case unsupportedVersion
    case protocolError(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .museNotFound:
            return L("Muse Code CLI not found")
        case .notSignedIn:
            return L("Not signed in — run muse login in Terminal")
        case .notSignedInExtraAccount:
            return L("Not signed in — run the login command in Settings")
        case .apiKeyOnly:
            return L("Muse Code is using an API key. Sign in with your Meta account (muse login) to show subscription limits.")
        case .noSubscription:
            return L("This Meta account has no Muse Code subscription. Allowance Bar can only show subscription limits.")
        case .noUsageData:
            return L("Muse Code has no usage data yet. It appears after your first prompt in a new window.")
        case .rateLimited:
            return L("Muse Code asked to wait before checking usage again")
        case .unsupportedVersion:
            return L("Update Muse Code — this version can't report usage")
        case .protocolError(let detail):
            return detail
        case .timeout:
            return L("Muse Code timed out")
        }
    }
}

/// Starts the user's `muse serve` (Muse Code's session host) and asks it for
/// the subscription's usage over newline-delimited JSON-RPC (Meta's MSP,
/// github.com/meta-models/muse-code-sdk). Muse Code reads and refreshes its
/// own login; this app never sees a Meta credential. The host is stopped
/// right after the answer.
///
/// `usage/refresh` is an experimental MSP method: it fetches fresh numbers
/// without spending a prompt, at most once per host per minute. The stable
/// `usage/read` only repeats what the host saw during a prompt, so a new host
/// has nothing to report.
enum MuseServeClient {
    /// How long one answer is reused.
    nonisolated static let pollInterval: TimeInterval = 300
    /// Muse Code allows one refresh per host per minute; forced refreshes
    /// wait at least that long too.
    nonisolated static let minimumInterval: TimeInterval = 60

    nonisolated static var defaultConfigRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
    }

    /// Muse Code keeps its login record in `<XDG_CONFIG_HOME>/muse/auth.json`
    /// (`~/.config/muse/auth.json` by default).
    nonisolated static func authFile(configRoot: URL) -> URL {
        configRoot.appendingPathComponent("muse/auth.json")
    }

    // MARK: - Public API

    /// `configHome` is set for extra accounts and becomes `XDG_CONFIG_HOME`.
    nonisolated static func readUsage(
        configHome: URL?,
        executable: URL? = nil,
        timeout: TimeInterval = 15
    ) async throws -> MuseUsageReading {
        guard let executable = executable ?? CommandLocator.resolve("muse") else {
            throw MuseServeError.museNotFound
        }

        let process = Process()
        process.executableURL = executable
        // Memory-only sessions: nothing is written to Muse Code's history.
        process.arguments = ["serve", "--no-session-log"]
        process.environment = environment(base: ProcessInfo.processInfo.environment, configHome: configHome)
        process.currentDirectoryURL = FileManager.default.temporaryDirectory

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        defer { terminate(process) }

        let writer = stdinPipe.fileHandleForWriting
        let reader = stdoutPipe.fileHandleForReading

        return try await withThrowingTaskGroup(of: MuseUsageReading.self) { group in
            group.addTask {
                try await exchange(reading: reader, writing: writer, process: process)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                // The reader blocks on the pipe and the group waits for it,
                // so stop the host first: its exit ends the read.
                process.terminate()
                throw MuseServeError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// `META_API_KEY` would replace the Meta account login, which is the
    /// only login that has subscription usage.
    ///
    /// An extra account's login lives in its own folder
    /// (`TBH_CREDENTIAL_BACKEND=file`, see its login command). Muse Code
    /// moves a folder login into its one shared Keychain item whenever it
    /// runs without that variable, which would replace the default
    /// account's login, so the variable is always set for those folders.
    nonisolated static func environment(base: [String: String], configHome: URL?) -> [String: String] {
        var environment = base
        environment.removeValue(forKey: "META_API_KEY")
        if let configHome {
            environment["XDG_CONFIG_HOME"] = configHome.path
            environment["TBH_CREDENTIAL_BACKEND"] = "file"
        }
        return environment
    }

    nonisolated static func usage(from reading: MuseUsageReading, now: Date) -> ProviderUsage {
        var windows: [UsageWindow] = []
        if let window = reading.window {
            let minutes = window.minutes ?? 0
            windows.append(UsageWindow(
                label: CodexUsageReader.windowLabel(minutes: minutes),
                usedPercent: window.usedPercent,
                resetsAt: window.resetsAt,
                duration: CodexUsageReader.windowDuration(minutes: minutes)
            ))
        }
        if let weekly = reading.weekly {
            windows.append(UsageWindow(
                label: L("Weekly limit"),
                usedPercent: weekly.usedPercent,
                resetsAt: weekly.resetsAt,
                duration: 7 * 86_400
            ))
        }
        let email = reading.accountLabel.flatMap { $0.contains("@") ? $0 : nil }
        return ProviderUsage(
            planName: reading.tierName ?? reading.tierID,
            windows: windows,
            asOf: reading.observedAt ?? now,
            accountEmail: email
        )
    }

    // MARK: - Parsing (pure)

    /// Turns the `account/read` and `usage/refresh` responses (whole JSON-RPC
    /// frames) into a reading or the error to show.
    nonisolated static func reading(
        account accountFrame: [String: Any]?,
        refresh refreshFrame: [String: Any]
    ) throws -> MuseUsageReading {
        let account = accountFrame?["result"] as? [String: Any]
        let accountState = account?["state"] as? String
        let accountLabel = (account?["label"] as? String).flatMap { label in
            accountState == "accountLogin" && !label.isEmpty ? label : nil
        }

        if let error = refreshFrame["error"] as? [String: Any] {
            let data = error["data"] as? [String: Any]
            let kind = data?["kind"] as? String
            let code = error["code"] as? Int
            switch kind {
            case "usageRefreshUnavailable":
                if accountState == "apiKey" || accountState == "envKey" {
                    throw MuseServeError.apiKeyOnly
                }
                throw MuseServeError.notSignedIn
            case "usageRefreshRateLimited":
                let milliseconds = (data?["retryAfterMs"] as? NSNumber)?.doubleValue
                throw MuseServeError.rateLimited(retryAfter: milliseconds.map { $0 / 1000 })
            case "experimentalRequired", "methodNotFound":
                throw MuseServeError.unsupportedVersion
            default:
                if code == -32601 { throw MuseServeError.unsupportedVersion }
                let message = error["message"] as? String ?? L("Muse Code protocol error")
                throw MuseServeError.protocolError(message)
            }
        }

        guard let result = refreshFrame["result"] as? [String: Any] else {
            throw MuseServeError.protocolError(L("Muse Code protocol error"))
        }
        guard let usage = result["usage"] as? [String: Any] else {
            if accountState == "loggedOut" { throw MuseServeError.notSignedIn }
            if result["subscriptionActive"] as? Bool == false {
                throw MuseServeError.noSubscription
            }
            throw MuseServeError.noUsageData
        }

        let tierName = (result["tierName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let tierID = (usage["tier"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return MuseUsageReading(
            tierName: tierName,
            tierID: tierID,
            window: (usage["window"] as? [String: Any]).flatMap(window),
            weekly: (usage["weekly"] as? [String: Any]).flatMap(window),
            observedAt: date(milliseconds: usage["observedAtMs"]),
            accountLabel: accountLabel
        )
    }

    nonisolated private static func window(_ dict: [String: Any]) -> MuseWindow? {
        guard let used = (dict["usedPercent"] as? NSNumber)?.doubleValue else { return nil }
        let minutes = (dict["windowDurationMins"] as? NSNumber)?.intValue
        return MuseWindow(
            usedPercent: used,
            resetsAt: date(milliseconds: dict["resetsAtMs"]),
            minutes: minutes.flatMap { $0 > 0 ? $0 : nil }
        )
    }

    nonisolated private static func date(milliseconds value: Any?) -> Date? {
        guard let milliseconds = (value as? NSNumber)?.doubleValue, milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    // MARK: - Protocol I/O

    nonisolated private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// MSP rejects requests sent before the host answers `initialize`, so the
    /// other requests go out only after that answer.
    nonisolated private static func exchange(
        reading stdout: FileHandle,
        writing stdin: FileHandle,
        process: Process
    ) async throws -> MuseUsageReading {
        // MSP client names must match ^[a-z0-9_]+$.
        try writeLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"allowancebar","version":"\#(appVersion)"},"capabilities":{"experimentalApi":true}}}"#, to: stdin)

        var accountFrame: [String: Any]?
        var refreshFrame: [String: Any]?
        var accountAnswered = false
        var buffer = Data()

        while refreshFrame == nil || !accountAnswered {
            let chunk = stdout.availableData
            buffer.append(chunk)

            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard !line.isEmpty,
                      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = (object["id"] as? NSNumber)?.intValue else {
                    continue
                }
                switch id {
                case 1:
                    if let error = object["error"] as? [String: Any] {
                        throw MuseServeError.protocolError(error["message"] as? String ?? L("Muse Code protocol error"))
                    }
                    let result = object["result"] as? [String: Any]
                    guard result?["experimentalApi"] as? Bool == true else {
                        throw MuseServeError.unsupportedVersion
                    }
                    try writeLine(#"{"jsonrpc":"2.0","method":"initialized"}"#, to: stdin)
                    try writeLine(#"{"jsonrpc":"2.0","id":2,"method":"account/read"}"#, to: stdin)
                    try writeLine(#"{"jsonrpc":"2.0","id":3,"method":"usage/refresh"}"#, to: stdin)
                case 2:
                    accountAnswered = true
                    // An older host may not know account/read; the refresh
                    // answer still decides.
                    if object["result"] != nil { accountFrame = object }
                case 3:
                    refreshFrame = object
                default:
                    break
                }
            }

            if refreshFrame != nil && accountAnswered { break }
            if chunk.isEmpty {
                // EOF: fail fast instead of waiting for the timeout.
                if !process.isRunning {
                    throw MuseServeError.protocolError(L("Muse Code exited unexpectedly"))
                }
                try await Task.sleep(for: .milliseconds(25))
            }
        }

        return try reading(account: accountFrame, refresh: refreshFrame ?? [:])
    }

    nonisolated private static func writeLine(_ line: String, to handle: FileHandle) throws {
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    nonisolated private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.interrupt()
        }
    }
}
