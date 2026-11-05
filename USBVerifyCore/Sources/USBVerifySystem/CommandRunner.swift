import Foundation
import USBVerifyCore

public struct CommandOutput: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol CommandRunner: Sendable {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandOutput
}

/// Runs a program and collects its output. No thread blocks while the program runs:
/// exit comes from `terminationHandler`, output from `readabilityHandler`, and the timeout from a timer.
public struct ProcessCommandRunner: CommandRunner {
    /// After the program exits, wait this long for its output pipes to close. A background child that
    /// inherited the pipes must not hold up the result.
    private static let drainGraceSeconds = 1.0

    public init() {}

    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandOutput {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // A child process must never read the app's own stdin.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let collector = OutputCollector()
        attach(stdoutPipe.fileHandleForReading, isError: false, to: collector)
        attach(stderrPipe.fileHandleForReading, isError: true, to: collector)

        let outcome: Outcome = await withCheckedContinuation { continuation in
            let gate = ResumeOnce(continuation)
            process.terminationHandler = { _ in gate.resume(.exited) }
            do {
                try process.run()
            } catch {
                gate.resume(.launchFailed(error.localizedDescription))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + max(timeout, 0)) { gate.resume(.timedOut) }
        }

        switch outcome {
        case .launchFailed(let message):
            detach(stdoutPipe, stderrPipe)
            throw VerifyError.commandFailed(command: commandText(executable, arguments), output: message)
        case .timedOut:
            process.terminate()
            detach(stdoutPipe, stderrPipe)
            throw VerifyError.commandFailed(
                command: commandText(executable, arguments),
                output: "timed out after \(timeout.cleanDescription) s")
        case .exited:
            await collector.waitForEndOfOutput(maxSeconds: Self.drainGraceSeconds)
            detach(stdoutPipe, stderrPipe)
            let output = collector.snapshot()
            return CommandOutput(
                exitCode: process.terminationStatus,
                stdout: String(decoding: output.stdout, as: UTF8.self),
                stderr: String(decoding: output.stderr, as: UTF8.self))
        }
    }

    private func attach(_ handle: FileHandle, isError: Bool, to collector: OutputCollector) {
        handle.readabilityHandler = { readable in
            let data = readable.availableData
            if data.isEmpty {
                readable.readabilityHandler = nil
                collector.markEnd(isError: isError)
            } else {
                collector.append(data, isError: isError)
            }
        }
    }

    private func detach(_ pipes: Pipe...) {
        for pipe in pipes {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
    }

    private enum Outcome: Sendable {
        case exited
        case timedOut
        case launchFailed(String)
    }
}

/// Thread-safe buffer for the two output streams.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var stdoutEnded = false
    private var stderrEnded = false

    func append(_ data: Data, isError: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isError { stderr.append(data) } else { stdout.append(data) }
    }

    func markEnd(isError: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isError { stderrEnded = true } else { stdoutEnded = true }
    }

    private var bothEnded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stdoutEnded && stderrEnded
    }

    func waitForEndOfOutput(maxSeconds: Double) async {
        let deadline = Date().addingTimeInterval(maxSeconds)
        while !bothEnded && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func snapshot() -> (stdout: Data, stderr: Data) {
        lock.lock()
        defer { lock.unlock() }
        return (stdout, stderr)
    }
}

/// Resumes a continuation exactly once, whichever event comes first.
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

private func commandText(_ executable: String, _ arguments: [String]) -> String {
    ([executable] + arguments).joined(separator: " ")
}

extension TimeInterval {
    fileprivate var cleanDescription: String {
        truncatingRemainder(dividingBy: 1) == 0 ? String(Int(self)) : String(self)
    }
}
