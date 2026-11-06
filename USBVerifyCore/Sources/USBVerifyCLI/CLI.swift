import Darwin
import Foundation
import USBVerifyCore

public enum CLI {
    public static func run(arguments: [String]) async -> Int32 {
        // --include-disk-images works for every command. It is for testing with a RAM disk only.
        // Progress must appear line by line even when output goes through a pipe, for example `| tee log.txt`.
        setvbuf(stdout, nil, _IOLBF, 0)
        let includeImages = arguments.contains("--include-disk-images")
        let rest = arguments.filter { $0 != "--include-disk-images" }
        if includeImages { print("Testing mode: disk images (for example a RAM disk) are included as drives.") }
        return await run(arguments: rest, environment: .live(includeDiskImages: includeImages), output: { print($0) })
    }

    public static func run(
        arguments: [String], environment: CLIEnvironment,
        output: @escaping @Sendable (String) -> Void
    ) async -> Int32 {
        do {
            let command = try ArgumentParser.parse(arguments)
            switch command {
            case .help:
                output(ArgumentParser.helpText)
                return 0
            case .list(let includeImages):
                return await list(environment, includeImages: includeImages, output: output)
            case .jobs:
                return jobs(environment, output: output)
            case .eject(let selector):
                return await eject(selector, environment: environment, output: output)
            case .copy(let options):
                return await copy(options, environment: environment, output: output)
            case .verify(let options):
                return await verify(options, environment: environment, output: output)
            case .resume(let id):
                return await resume(id, environment: environment, output: output)
            }
        } catch let error as CLIError {
            output(error.message)
            return error.isUsage ? 2 : 4
        } catch {
            output("Internal error: \(error)")
            return 4
        }
    }

    private static func list(
        _ environment: CLIEnvironment, includeImages: Bool,
        output: @escaping @Sendable (String) -> Void
    ) async -> Int32 {
        let volumes = await environment.volumes.currentVolumes()
        if volumes.isEmpty {
            output("No usable volumes found.")
            return 0
        }
        for (index, volume) in volumes.enumerated() {
            let reason: String
            if !volume.filesystem.isCopyTarget {
                reason = volume.filesystem == .ntfs ? "NTFS is read-only on macOS" : "unsupported filesystem"
            } else if volume.isReadOnly {
                reason = "read-only"
            } else {
                reason = "usable"
            }
            let timeMachine = volume.hasTimeMachineBackups ? " Time Machine volume" : ""
            output(
                "\(index + 1). \(volume.name) | size \(volume.totalBytes) | free \(volume.freeBytes) | \(volume.filesystem.displayName) | \(Console.route(volume.route)) | UUID \(volume.id.uuid) | \(reason).\(timeMachine)"
            )
        }
        return 0
    }

    private static func jobs(_ environment: CLIEnvironment, output: @escaping @Sendable (String) -> Void) -> Int32 {
        do {
            let jobs = try environment.jobStore.loadAll()
            for job in jobs {
                let reason = job.pausedReason?.rawValue ?? ""
                output(
                    "\(job.id) \(job.pausedReason == nil ? "running or saved" : "paused") \(job.currentIndex) of \(job.files.count) \(job.volumeID.uuid) \(reason)"
                )
            }
            return 0
        } catch {
            output("Could not read saved jobs: \(error)")
            return 4
        }
    }

    private static func eject(
        _ selector: DriveSelector, environment: CLIEnvironment,
        output: @escaping @Sendable (String) -> Void
    ) async -> Int32 {
        do {
            let volume = try DriveResolver.resolve(selector, from: await environment.volumes.currentVolumes())
            try await environment.volumeControl.eject(volume: volume.id)
            output("Ejected \(volume.name).")
            return 0
        } catch {
            output(error.plainMessage)
            return 4
        }
    }

    private static func copy(
        _ options: CopyOptions, environment: CLIEnvironment,
        output: @escaping @Sendable (String) -> Void
    ) async -> Int32 {
        do {
            let volume = try DriveResolver.resolve(options.drive, from: await environment.volumes.currentVolumes())
            let io = environment.drive(volume)
            let states = try makeStates(options, volume: volume, io: io, output: output)
            let files = states.map {
                PreflightFile(sourcePath: $0.sourcePath, size: $0.sourceIdentity.size, destinationName: $0.finalName)
            }
            let report = Preflight.check(volume: volume, files: files)
            guard report.isOK else {
                printIssues(report.issues, output: output)
                return 2
            }
            output(planText(volume: volume, states: states, mode: options.mode, io: io))
            if options.dryRun { return 0 }
            guard options.yes else {
                output("Type yes to start.")
                return 2
            }
            return await runCopy(
                states: states, volume: volume, mode: options.mode, environment: environment, io: io, output: output,
                dotClean: options.dotClean, confirmed: options.yes)
        } catch {
            output(error.plainMessage)
            return 2
        }
    }

    private static func makeStates(
        _ options: CopyOptions, volume: Volume, io: any DriveIO,
        output: @escaping @Sendable (String) -> Void
    ) throws -> [FileJobState] {
        var result: [FileJobState] = []
        let guardrail = DestinationGuard(volume: volume)
        for path in options.files {
            var sourceInfo = stat()
            if path.withCString({ lstat($0, &sourceInfo) == 0 }) && (sourceInfo.st_mode & S_IFMT) == S_IFDIR {
                throw CLIError.usage("Folders are not supported yet")
            }
            let name = URL(fileURLWithPath: path).lastPathComponent
            var finalName = name
            let target = try guardrail.path(folder: options.folder, name: finalName)
            if io.fileSize(path: target) != nil {
                guard let policy = options.conflict else {
                    throw CLIError.usage("A conflict exists. Choose --on-conflict replace, skip, or keep-both.")
                }
                switch policy {
                case .replace: break
                case .skip:
                    output("SKIPPED \(name): existing file")
                    continue
                case .ask:
                    throw CLIError.usage("Conflict prompts need an explicit policy in this non-interactive command.")
                case .keepBoth:
                    finalName = Plan.keepBothName(name) { candidate in
                        guard let path = try? guardrail.path(folder: options.folder, name: candidate) else {
                            return false
                        }
                        return io.fileSize(path: path) != nil
                    }
                }
            }
            result.append(
                try JobFactory.fileState(
                    sourcePath: path, destinationFolder: options.folder,
                    finalName: finalName, replaceExisting: options.conflict == .replace, io: io))
        }
        return result
    }

    private static func runCopy(
        states: [FileJobState], volume: Volume, mode: VerifyMode,
        environment: CLIEnvironment, io: any DriveIO,
        output: @escaping @Sendable (String) -> Void, dotClean: Bool, confirmed: Bool
    ) async -> Int32 {
        var job = JobFactory.job(volume: volume, mode: mode, files: states)
        let runner = JobRunner(
            job: job, volume: volume, io: io, volumeControl: environment.volumeControl,
            store: environment.jobStore, sink: environment.sink,
            environment: RunEnvironment(route: volume.route))
        let signal = installSIGINT { runner.control.requestPause(.appQuit) }
        let events = Task { for await event in runner.events { render(event, output: output) } }
        let token = environment.power.begin(reason: "USB Verify copy")
        let summary = await runner.run()
        token.end()
        signal.cancel()
        await events.value
        job = summary.job
        for file in job.files {
            if let result = file.result {
                output(Console.resultText(name: file.finalName, result: result))
                if case .failed = result, let detail = file.errorDetail { output("Detail: \(detail)") }
            }
        }
        if case .paused = summary.status {
            output("Paused. Resume with: usbverify resume \(job.id)")
            return 3
        }
        let failed = summary.results.contains {
            if case .failed = $0 { return true }
            return false
        }
        if dotClean && confirmed && !failed {
            let root = URL(fileURLWithPath: volume.mountPath).appendingPathComponent(
                job.files.first?.destinationFolder ?? ""
            ).path
            let paths = DotCleaner.scan(root: root)
            for path in paths { output("Delete \(path)") }
            _ = DotCleaner.delete(paths, within: root)
        }
        return failed ? 1 : 0
    }

    private static func verify(
        _ options: VerifyOptions, environment: CLIEnvironment,
        output: @escaping @Sendable (String) -> Void
    ) async -> Int32 {
        do {
            let volume = try DriveResolver.resolve(options.drive, from: await environment.volumes.currentVolumes())
            let io = environment.drive(volume)
            let items = options.files.map {
                VerifyOnlyItem(
                    sourcePath: $0, destinationFolder: options.folder, name: URL(fileURLWithPath: $0).lastPathComponent)
            }
            let runner = VerifyOnlyRunner(
                items: items, volume: volume, io: io, volumeControl: environment.volumeControl, sink: environment.sink)
            let events = Task { for await event in runner.events { render(event, output: output) } }
            let results = await runner.run()
            await events.value
            for (index, result) in results.enumerated() {
                output(Console.resultText(name: items[index].name, result: result))
            }
            let anyFailed = results.contains {
                if case .failed = $0 { return true }
                return false
            }
            // A file that was not found was not checked, so that must never look like success.
            let anySkipped = results.contains {
                if case .skipped = $0 { return true }
                return false
            }
            return anyFailed ? 1 : (anySkipped ? 2 : 0)
        } catch {
            output(error.plainMessage)
            return 2
        }
    }

    private static func resume(
        _ id: String, environment: CLIEnvironment,
        output: @escaping @Sendable (String) -> Void
    ) async -> Int32 {
        do {
            guard let job = try environment.jobStore.load(id: id) else {
                throw CLIError.operational("Job \(id) was not found.")
            }
            guard let volume = await environment.volumes.currentVolumes().first(where: { $0.id == job.volumeID }) else {
                output("Reconnect the drive.")
                return 3
            }
            return await runCopy(
                states: job.files, volume: volume, mode: job.mode, environment: environment,
                io: environment.drive(volume), output: output, dotClean: false, confirmed: true)
        } catch {
            output(error.plainMessage)
            return 4
        }
    }

    private static func printIssues(_ issues: [PreflightIssue], output: @escaping @Sendable (String) -> Void) {
        for issue in issues {
            output(issue.error.plainMessage)
            output(issue.error.technicalDetail)
        }
    }

    private static func planText(volume: Volume, states: [FileJobState], mode: VerifyMode, io: any DriveIO) -> String {
        let bytes = states.reduce(Int64(0)) { $0 + $1.sourceIdentity.size }
        let free = (try? io.freeSpace(path: volume.mountPath)) ?? volume.freeBytes
        let files = states.map { "\($0.finalName) (\($0.sourceIdentity.size) bytes)" }.joined(separator: ", ")
        return
            "Drive: \(volume.name), \(volume.filesystem.displayName), \(Console.route(volume.route))\nFiles: \(files)\nMode: \(mode.rawValue)\nFree space: \(free) bytes\nEstimate: \(Plan.estimateText(bytes: bytes, mode: mode))"
    }

    private static func render(_ event: JobEvent, output: @escaping @Sendable (String) -> Void) {
        switch event {
        case .progress(let snapshot): output(Console.progressLine(snapshot))
        case .warning(let text): output("Warning: \(text)")
        case .waitingForUnmount(let blockers):
            output("Close them, then press Enter to retry: \(blockers.joined(separator: ", "))")
        case .paused(let reason, let offset): output(Console.pausedText(reason: reason, offset: offset))
        default: break
        }
    }

    private static func installSIGINT(_ action: @escaping @Sendable () -> Void) -> DispatchSourceSignal {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global(qos: .userInitiated))
        source.setEventHandler(handler: action)
        source.resume()
        return source
    }
}

extension CLIError {
    fileprivate var message: String {
        switch self {
        case .usage(let text): return "Usage error: \(text)\n\(ArgumentParser.helpText)"
        case .operational(let text): return text
        }
    }
    fileprivate var isUsage: Bool {
        if case .usage = self { return true }
        return false
    }
}

extension Error {
    fileprivate var plainMessage: String { (self as? any UserFacingError)?.plainMessage ?? String(describing: self) }
}
