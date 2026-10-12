import Darwin
import Foundation
import XCTest
@testable import AgentMeter

final class ClaudeKeychainReaderTests: XCTestCase {
    func testPassesServiceAndAccountAsSeparateArguments() async throws {
        let script = try makeScript("printf '<%s>\\n' \"$@\"\n")
        defer { try? FileManager.default.removeItem(at: script.directory) }

        let service = "Claude Code-credentials; echo unsafe"
        let result = try await ClaudeKeychainReader.read(
            service: service,
            executableURL: script.executable,
            account: "test user"
        )

        XCTAssertEqual(
            result,
            Data("<find-generic-password>\n<-s>\n<\(service)>\n<-a>\n<test user>\n<-w>\n".utf8)
        )
    }

    func testStreamsOutputLargerThanPipeBufferAndPreservesTrailingNewline() async throws {
        let script = try makeScript("printf '%65536s' '' | /usr/bin/tr ' ' x; printf '{\"ok\":true}\\n'\n")
        defer { try? FileManager.default.removeItem(at: script.directory) }

        let result = try await ClaudeKeychainReader.read(
            service: "test-service",
            executableURL: script.executable,
            account: "test-account"
        )

        let expected = Data((String(repeating: "x", count: 65_536) + "{\"ok\":true}\n").utf8)
        XCTAssertEqual(result, expected)
    }

    func testOversizedOutputFailsWithoutReturningPartialCredentials() async throws {
        let script = try makeScript("printf '%65536s' '' | /usr/bin/tr ' ' x; printf '%65536s' '' | /usr/bin/tr ' ' y\n")
        defer { try? FileManager.default.removeItem(at: script.directory) }

        do {
            _ = try await ClaudeKeychainReader.read(
                service: "test-service",
                executableURL: script.executable,
                account: "test-account",
                maximumOutputBytes: 70_000
            )
            XCTFail("Expected output limit failure")
        } catch let error as ClaudeKeychainReaderError {
            XCTAssertEqual(error, .outputTooLarge)
        }
    }

    func testExitCode44MeansItemNotFound() async throws {
        let script = try makeScript("exit 44\n")
        defer { try? FileManager.default.removeItem(at: script.directory) }

        let result = try await ClaudeKeychainReader.read(
            service: "test-service",
            executableURL: script.executable,
            account: "test-account"
        )

        XCTAssertNil(result)
    }

    func testOtherNonzeroExitHidesStandardError() async throws {
        let script = try makeScript("printf 'private diagnostic' >&2; exit 2\n")
        defer { try? FileManager.default.removeItem(at: script.directory) }

        do {
            _ = try await ClaudeKeychainReader.read(
                service: "test-service",
                executableURL: script.executable,
                account: "test-account"
            )
            XCTFail("Expected command failure")
        } catch let error as ClaudeKeychainReaderError {
            XCTAssertEqual(error, .commandFailed)
            XCTAssertFalse(error.localizedDescription.contains("private diagnostic"))
        }
    }

    func testEmptyOutputIsRejected() async throws {
        let script = try makeScript("printf ' \n\\t'\n")
        defer { try? FileManager.default.removeItem(at: script.directory) }

        do {
            _ = try await ClaudeKeychainReader.read(
                service: "test-service",
                executableURL: script.executable,
                account: "test-account"
            )
            XCTFail("Expected empty output failure")
        } catch let error as ClaudeKeychainReaderError {
            XCTAssertEqual(error, .emptyOutput)
        }
    }

    func testLaunchFailureIsSafe() async throws {
        do {
            _ = try await ClaudeKeychainReader.read(
                service: "test-service",
                executableURL: URL(fileURLWithPath: "/missing-security-\(UUID().uuidString)"),
                account: "test-account"
            )
            XCTFail("Expected launch failure")
        } catch let error as ClaudeKeychainReaderError {
            XCTAssertEqual(error, .launchFailed)
        }
    }

    func testAlreadyCancelledReadDoesNotLaunchChild() async throws {
        let script = try makeSleepingScript()
        defer { try? FileManager.default.removeItem(at: script.directory) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ClaudeKeychainReader.read(
                service: "test-service",
                executableURL: script.executable,
                account: "test-account"
            )
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertFalse(FileManager.default.fileExists(atPath: script.pidFile.path))
        }
    }

    func testTimeoutTerminatesChildProcess() async throws {
        let script = try makeSleepingScript()
        defer { try? FileManager.default.removeItem(at: script.directory) }

        do {
            _ = try await ClaudeKeychainReader.read(
                service: "test-service",
                executableURL: script.executable,
                account: "test-account",
                timeout: 0.2
            )
            XCTFail("Expected timeout")
        } catch let error as ClaudeKeychainReaderError {
            XCTAssertEqual(error, .timedOut)
        }

        guard let pid = await waitForPID(in: script.pidFile) else {
            XCTFail("The fake child did not start")
            return
        }
        await assertProcessHasExited(pid)
    }

    func testCancellationTerminatesChildProcess() async throws {
        let script = try makeSleepingScript()
        defer { try? FileManager.default.removeItem(at: script.directory) }

        let task = Task {
            try await ClaudeKeychainReader.read(
                service: "test-service",
                executableURL: script.executable,
                account: "test-account",
                timeout: 10
            )
        }

        guard let pid = await waitForPID(in: script.pidFile) else {
            task.cancel()
            XCTFail("The fake child did not start")
            return
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        await assertProcessHasExited(pid)
    }

    private func makeScript(_ body: String) throws -> (directory: URL, executable: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeKeychainReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fake-security")
        try Data(("#!/bin/sh\n" + body).utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (directory, executable)
    }

    private func makeSleepingScript() throws -> (directory: URL, executable: URL, pidFile: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeKeychainReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fake-security")
        let pidFile = directory.appendingPathComponent("child.pid")
        let quotedPIDFile = "'\(pidFile.path.replacingOccurrences(of: "'", with: "'\\''"))'"
        let body = "echo $$ > \(quotedPIDFile)\nexec /bin/sleep 30\n"
        try Data(("#!/bin/sh\n" + body).utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (directory, executable, pidFile)
    }

    private func waitForPID(in file: URL) async -> pid_t? {
        for _ in 0..<200 {
            if let value = try? String(contentsOf: file, encoding: .utf8),
               let pid = pid_t(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    private func assertProcessHasExited(_ pid: pid_t) async {
        for _ in 0..<200 {
            if Darwin.kill(pid, 0) == -1, errno == ESRCH { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Child process \(pid) remained alive")
    }
}
