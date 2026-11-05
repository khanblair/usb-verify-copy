import Foundation
import Testing
import USBVerifyCore

@testable import USBVerifySystem

@Suite("ProcessCommandRunner")
struct CommandRunnerTests {
    private let runner = ProcessCommandRunner()

    @Test func collectsStdoutAndExitCode() async throws {
        let output = try await runner.run("/bin/echo", ["hello"], timeout: 10)
        #expect(output.exitCode == 0)
        #expect(output.stdout == "hello\n")
        #expect(output.stderr.isEmpty)
    }

    @Test func collectsStderrAndNonZeroExit() async throws {
        let output = try await runner.run("/bin/sh", ["-c", "echo oops 1>&2; exit 3"], timeout: 10)
        #expect(output.exitCode == 3)
        #expect(output.stderr == "oops\n")
        #expect(output.stdout.isEmpty)
    }

    @Test func timeoutStopsALongRunningCommand() async {
        let started = ContinuousClock.now
        do {
            _ = try await runner.run("/bin/sleep", ["30"], timeout: 0.5)
            Issue.record("expected a timeout")
        } catch VerifyError.commandFailed(_, let output) {
            #expect(output.contains("timed out"))
        } catch {
            Issue.record("wrong error: \(error)")
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func largeOutputDoesNotDeadlock() async throws {
        let output = try await runner.run("/usr/bin/seq", ["1", "300000"], timeout: 30)
        #expect(output.exitCode == 0)
        #expect(output.stdout.hasSuffix("300000\n"))
        #expect(output.stdout.split(separator: "\n").count == 300_000)
    }

    @Test func stdinIsClosedSoReadersEndAtOnce() async throws {
        let started = ContinuousClock.now
        let output = try await runner.run("/bin/cat", [], timeout: 10)
        #expect(output.exitCode == 0)
        #expect(output.stdout.isEmpty)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func missingProgramFailsWithACommandError() async {
        do {
            _ = try await runner.run("/nonexistent/program", [], timeout: 5)
            Issue.record("expected a launch failure")
        } catch VerifyError.commandFailed {
            // expected
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test func backgroundChildHoldingThePipeDoesNotBlockTheResult() async throws {
        let started = ContinuousClock.now
        // The shell exits at once, but its background `sleep` still holds the output pipes open.
        let output = try await runner.run("/bin/sh", ["-c", "sleep 4 & echo done"], timeout: 20)
        #expect(output.exitCode == 0)
        #expect(output.stdout == "done\n")
        #expect(ContinuousClock.now - started < .seconds(3))
    }
}
