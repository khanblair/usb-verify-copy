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

public struct ProcessCommandRunner: CommandRunner {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandOutput {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw VerifyError.commandFailed(
                command: commandText(executable, arguments), output: error.localizedDescription)
        }

        let stdoutTask = Task.detached {
            stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let stderrTask = Task.detached {
            stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let finished = await waitForProcess(process, timeout: timeout)
        if !finished {
            process.terminate()
            _ = await stdoutTask.value
            _ = await stderrTask.value
            throw VerifyError.commandFailed(
                command: commandText(executable, arguments),
                output: "timed out after \(timeout.cleanDescription) s")
        }

        let stdout = String(decoding: await stdoutTask.value, as: UTF8.self)
        let stderr = String(decoding: await stderrTask.value, as: UTF8.self)
        return CommandOutput(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}

private func waitForProcess(_ process: Process, timeout: TimeInterval) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            process.waitUntilExit()
            return true
        }
        group.addTask {
            let duration = UInt64(max(0, timeout) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: duration)
            return false
        }
        let result = await group.next() ?? false
        group.cancelAll()
        return result
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
