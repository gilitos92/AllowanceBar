import Foundation
import XCTest
@testable import AgentMeter

final class CodexAppServerClientTests: XCTestCase {
    func testConcurrentExecutableResolutionAndReset() {
        CodexAppServerClient.resetExecutableCache()
        let expected = CodexAppServerClient.resolveCodexExecutable()?.path
        let mismatchLock = NSLock()
        var mismatches = 0

        DispatchQueue.concurrentPerform(iterations: 256) { index in
            if index.isMultiple(of: 8) {
                CodexAppServerClient.resetExecutableCache()
            }
            let actual = CodexAppServerClient.resolveCodexExecutable()?.path
            if actual != expected {
                mismatchLock.withLock { mismatches += 1 }
            }
        }

        XCTAssertEqual(mismatches, 0)
        XCTAssertEqual(CodexAppServerClient.resolveCodexExecutable()?.path, expected)
    }
}

final class CommandLocatorTests: XCTestCase {
    /// A tool installed after a miss is found on the next lookup, without
    /// waiting for the login-shell retry.
    func testToolInstalledAfterAMissIsFoundAtOnce() throws {
        let command = "allowancebar-test-tool-\(UUID().uuidString.prefix(8).lowercased())"
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("locator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", "\(folder.path):\(originalPath)", 1)
        defer {
            setenv("PATH", originalPath, 1)
            try? FileManager.default.removeItem(at: folder)
            CommandLocator.resetCache(for: command)
        }
        XCTAssertNil(CommandLocator.resolve(command))

        let tool = folder.appendingPathComponent(command)
        try "#!/bin/sh\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        XCTAssertEqual(CommandLocator.resolve(command)?.path, tool.path)
    }
}
