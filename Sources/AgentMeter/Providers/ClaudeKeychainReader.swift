import Foundation
import Darwin

enum ClaudeKeychainReaderError: Error, Sendable, Equatable {
    case launchFailed
    case commandFailed
    case timedOut
    case outputTooLarge
    case emptyOutput
    case readFailed
}

enum ClaudeKeychainReader {
    private static let securityExecutable = URL(fileURLWithPath: "/usr/bin/security")
    private static let timeout: TimeInterval = 5
    private static let maximumOutputBytes = 1_048_576

    static func read(service: String) async throws -> Data? {
        try await read(
            service: service,
            executableURL: securityExecutable,
            account: NSUserName(),
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes
        )
    }

    // Internal injection point for tests. Production always uses /usr/bin/security
    // and the fixed argument vector below.
    static func read(
        service: String,
        executableURL: URL,
        account: String,
        timeout: TimeInterval = 5,
        maximumOutputBytes: Int = 1_048_576
    ) async throws -> Data? {
        try Task.checkCancellation()
        let arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        let operation = ClaudeKeychainReadOperation(
            executableURL: executableURL,
            arguments: arguments,
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes
        )

        return try await withTaskCancellationHandler {
            try await operation.run()
        } onCancel: {
            operation.cancel()
        }
    }
}

private final class ClaudeKeychainReadOperation: @unchecked Sendable {
    private let executableURL: URL
    private let arguments: [String]
    private let timeout: TimeInterval
    private let maximumOutputBytes: Int
    private let queue = DispatchQueue(label: "com.ggv.AllowanceBar.ClaudeKeychainReader")

    // All mutable state below is confined to queue.
    private var continuation: CheckedContinuation<Data?, Error>?
    private var process: Process?
    private var outputPipe: Pipe?
    private var outputHandle: FileHandle?
    private var readSource: DispatchSourceRead?
    private var timeoutSource: DispatchSourceTimer?
    private var output = Data()
    private var processExitStatus: Int32?
    private var outputReachedEOF = false
    private var didComplete = false
    private var cancellationRequested = false

    init(executableURL: URL, arguments: [String], timeout: TimeInterval, maximumOutputBytes: Int) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.timeout = timeout
        self.maximumOutputBytes = maximumOutputBytes
    }

    func run() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                self.continuation = continuation
                if cancellationRequested {
                    complete(.failure(CancellationError()))
                } else {
                    startProcess()
                }
            }
        }
    }

    func cancel() {
        queue.async { [self] in
            cancellationRequested = true
            guard continuation != nil else { return }
            complete(.failure(CancellationError()))
        }
    }

    private func startProcess() {
        guard timeout > 0, maximumOutputBytes > 0 else {
            complete(.failure(ClaudeKeychainReaderError.launchFailed))
            return
        }

        let pipe = Pipe()
        let outputHandle = pipe.fileHandleForReading
        let descriptor = outputHandle.fileDescriptor
        let existingFlags = fcntl(descriptor, F_GETFL)
        guard existingFlags != -1, fcntl(descriptor, F_SETFL, existingFlags | O_NONBLOCK) != -1 else {
            outputHandle.closeFile()
            pipe.fileHandleForWriting.closeFile()
            complete(.failure(ClaudeKeychainReaderError.readFailed))
            return
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drainOutput()
        }
        source.setCancelHandler {
            outputHandle.closeFile()
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            self?.queue.async { [weak self] in
                self?.didTerminate(status: status)
            }
        }

        self.process = process
        self.outputPipe = pipe
        self.outputHandle = outputHandle
        self.readSource = source
        source.resume()

        do {
            try process.run()
            pipe.fileHandleForWriting.closeFile()
        } catch {
            pipe.fileHandleForWriting.closeFile()
            complete(.failure(ClaudeKeychainReaderError.launchFailed))
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in
            self?.complete(.failure(ClaudeKeychainReaderError.timedOut))
        }
        timeoutSource = timer
        timer.resume()
    }

    private func drainOutput() {
        guard !didComplete, let descriptor = outputHandle?.fileDescriptor else { return }

        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }

            if bytesRead > 0 {
                guard output.count + bytesRead <= maximumOutputBytes else {
                    complete(.failure(ClaudeKeychainReaderError.outputTooLarge))
                    return
                }
                output.append(contentsOf: buffer.prefix(bytesRead))
                continue
            }

            if bytesRead == 0 {
                outputReachedEOF = true
                readSource?.cancel()
                readSource = nil
                finishIfReady()
                return
            }

            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            complete(.failure(ClaudeKeychainReaderError.readFailed))
            return
        }
    }

    private func didTerminate(status: Int32) {
        guard !didComplete else { return }
        processExitStatus = status
        finishIfReady()
    }

    private func finishIfReady() {
        guard !didComplete, let status = processExitStatus, outputReachedEOF else { return }

        if status == 44 {
            complete(.success(nil))
        } else if status != 0 {
            complete(.failure(ClaudeKeychainReaderError.commandFailed))
        } else if output.allSatisfy({ [UInt8(9), 10, 11, 12, 13, 32].contains($0) }) {
            complete(.failure(ClaudeKeychainReaderError.emptyOutput))
        } else {
            complete(.success(output))
        }
    }

    private func complete(_ result: Result<Data?, Error>) {
        guard !didComplete else { return }
        didComplete = true

        timeoutSource?.setEventHandler {}
        timeoutSource?.cancel()
        timeoutSource = nil

        if let source = readSource {
            source.setEventHandler {}
            source.cancel()
            readSource = nil
        }

        if case .failure = result {
            stopProcess()
        }

        let continuation = self.continuation
        self.continuation = nil
        outputPipe = nil
        outputHandle = nil
        continuation?.resume(with: result)
    }

    private func stopProcess() {
        guard let process, process.isRunning else { return }
        process.terminate()
        queue.asyncAfter(deadline: .now() + .milliseconds(200)) { [process] in
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
    }
}
