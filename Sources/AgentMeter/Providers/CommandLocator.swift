import Foundation

/// Finds another tool's command-line program (Codex, Muse Code). Apps opened
/// from Finder get a minimal PATH, so the usual install folders come first,
/// then PATH, then the user's login shell. A found path is cached. After a
/// miss the folders are still checked on every call (a few file checks), so
/// a fresh install is found at once; only the login-shell lookup waits
/// `missRetryInterval`.
enum CommandLocator {
    nonisolated static let missRetryInterval: TimeInterval = 300

    private struct Lookup {
        let url: URL?
        let date: Date
    }

    private nonisolated static let cacheLock = NSLock()
    private nonisolated(unsafe) static var cache: [String: Lookup] = [:]

    nonisolated static func candidatePaths(command: String, home: String, pathEnv: String?) -> [String] {
        var paths = [
            "/opt/homebrew/bin/\(command)",
            "/usr/local/bin/\(command)",
            "\(home)/.local/bin/\(command)",
        ]
        if let pathEnv {
            for entry in pathEnv.split(separator: ":") {
                let trimmed = entry.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                paths.append("\(trimmed)/\(command)")
            }
        }
        return paths
    }

    /// `command` must be a plain program name such as "codex"; it is passed
    /// to the login shell as is.
    nonisolated static func resolve(_ command: String) -> URL? {
        cacheLock.withLock {
            let cached = cache[command]
            if let url = cached?.url {
                return url
            }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let pathEnv = ProcessInfo.processInfo.environment["PATH"]
            for candidate in candidatePaths(command: command, home: home, pathEnv: pathEnv)
            where FileManager.default.isExecutableFile(atPath: candidate) {
                let url = URL(fileURLWithPath: candidate)
                cache[command] = Lookup(url: url, date: Date())
                return url
            }
            if let cached, Date().timeIntervalSince(cached.date) < missRetryInterval {
                return nil
            }
            let resolved = resolveViaShell(command)
            cache[command] = Lookup(url: resolved, date: Date())
            return resolved
        }
    }

    /// Forgets a cached result (testing only).
    nonisolated static func resetCache(for command: String) {
        cacheLock.withLock {
            cache[command] = nil
        }
    }

    nonisolated private static func resolveViaShell(_ command: String) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(command)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty,
                  FileManager.default.isExecutableFile(atPath: path) else {
                return nil
            }
            return URL(fileURLWithPath: path)
        } catch {
            return nil
        }
    }
}
