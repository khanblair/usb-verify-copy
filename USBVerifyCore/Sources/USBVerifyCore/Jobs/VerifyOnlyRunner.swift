import Foundation

/// One file already on the drive, paired with its source (spec section 11).
public struct VerifyOnlyItem: Equatable, Sendable {
    public var sourcePath: String
    /// Folder relative to the volume root.
    public var destinationFolder: String
    public var name: String
    public init(sourcePath: String, destinationFolder: String, name: String) {
        self.sourcePath = sourcePath
        self.destinationFolder = destinationFolder
        self.name = name
    }
}

/// Checks files on the drive against their sources. It never writes to the drive.
public final class VerifyOnlyRunner: @unchecked Sendable {
    public let control = JobControl()
    public let events: AsyncStream<JobEvent>

    private let continuation: AsyncStream<JobEvent>.Continuation
    private let items: [VerifyOnlyItem]
    private var volume: Volume
    private let io: any DriveIO
    private let volumeControl: any VolumeControl
    private let sink: (any RunSink)?
    private let environment: RunEnvironment
    private let clock: EngineClock
    private let chunkSize: Int

    public init(items: [VerifyOnlyItem], volume: Volume, io: any DriveIO, volumeControl: any VolumeControl,
                sink: (any RunSink)? = nil, environment: RunEnvironment = RunEnvironment(),
                clock: EngineClock = .system, chunkSize: Int = Defaults.chunkSize) {
        self.items = items
        self.volume = volume
        self.io = io
        self.volumeControl = volumeControl
        self.sink = sink
        self.environment = environment
        self.clock = clock
        self.chunkSize = chunkSize
        var cont: AsyncStream<JobEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        self.continuation = cont
    }

    public func run() async -> [FileResult] {
        defer {
            continuation.yield(.finished)
            continuation.finish()
        }
        var results: [FileResult] = []
        // Remount first, so no cached copy of the file can hide damage.
        do {
            continuation.yield(.phase(fileIndex: 0, .remounting))
            try await unmountWithRetry()
            volume.mountPath = try await volumeControl.mount(volume: volume.id)
        } catch {
            let reason = (error as? VerifyError)?.plainMessage ?? "\(error)"
            return items.map { _ in FileResult.skipped(reason: reason) }
        }

        for (index, item) in items.enumerated() {
            if control.isCancelled { results.append(.cancelled); continue }
            let started = Date()
            let result = await verify(item, index: index)
            results.append(result)
            continuation.yield(.fileFinished(fileIndex: index, result))
            await record(item, result: result, started: started)
        }
        return results
    }

    private func unmountWithRetry() async throws {
        while true {
            if control.isCancelled { throw VerifyError.cancelled }
            do {
                try await volumeControl.unmount(volume: volume.id)
                return
            } catch VerifyError.unmountBusy(let blockers) {
                continuation.yield(.phase(fileIndex: 0, .waitingUnmount))
                continuation.yield(.waitingForUnmount(blockers: blockers))
                while !control.takeRetry() {
                    if control.isCancelled { throw VerifyError.cancelled }
                    await clock.sleep(0.25)
                }
            }
        }
    }

    private func verify(_ item: VerifyOnlyItem, index: Int) async -> FileResult {
        do {
            let guardrail = DestinationGuard(volume: volume)
            let path = try guardrail.path(folder: item.destinationFolder, name: item.name)
            try guardrail.validate(path: path)
            guard io.fileSize(path: path) != nil else { return .skipped(reason: "not found on the drive") }
            let source = try io.openSource(path: item.sourcePath)
            let size = source.identity.size
            source.close()
            let plan = ChunkPlan(size: size, chunkSize: chunkSize)
            continuation.yield(.phase(fileIndex: index, .finalCheck))
            let result = try FinalPass.run(
                io: io, sourcePath: item.sourcePath, destinationPath: path, plan: plan, expectedChunkHashes: nil,
                interrupt: { if self.control.isCancelled { throw Interrupt.cancel } },
                progress: { done in
                    self.continuation.yield(.progress(ProgressSnapshot(
                        fileIndex: index, fileCount: self.items.count, fileName: item.name, phase: .finalCheck,
                        fileBytesDone: done, fileBytesTotal: size, chunksVerified: Int(done / Int64(self.chunkSize)),
                        chunksRetried: 0, bytesPerSecond: 0, secondsRemaining: nil,
                        batchBytesDone: done, batchBytesTotal: size)))
                })
            if !result.badRanges.isEmpty { return .failed(reason: .finalCheckMismatch, badRanges: result.badRanges) }
            guard let sourceHash = result.sourceHash, sourceHash == result.rereadHash else {
                return .failed(reason: .wholeFileHashMismatch, badRanges: [])
            }
            return .passed(sourceHash: sourceHash, rereadHash: result.rereadHash)
        } catch Interrupt.cancel {
            return .cancelled
        } catch VerifyError.sourceChanged {
            return .failed(reason: .sourceChanged, badRanges: [])
        } catch {
            return .failed(reason: .ioError, badRanges: [])
        }
    }

    private func record(_ item: VerifyOnlyItem, result: FileResult, started: Date) async {
        guard let sink else { return }
        var text = "FAIL"
        var sourceHash: String?
        var rereadHash: String?
        var bad: [BadRange] = []
        switch result {
        case .passed(let s, let r): text = "PASS"; sourceHash = s; rereadHash = r
        case .failed(_, let ranges): bad = ranges
        case .skipped: text = "SKIPPED"
        case .cancelled: text = "CANCELLED"
        }
        await sink.record(RunRecord(
            startedAt: started, endedAt: Date(), kind: .verifyOnly, mode: nil, driveName: volume.name,
            volumeUUID: volume.id.uuid, model: volume.model, filesystem: volume.filesystem.displayName,
            filesystemDriver: environment.filesystemDriver, macOSVersion: environment.macOSVersion,
            route: volume.route ?? environment.route, sourcePath: item.sourcePath,
            destinationPath: [volume.mountPath, item.destinationFolder, item.name].filter { !$0.isEmpty }.joined(separator: "/"),
            sizeBytes: 0, chunkSize: chunkSize, retries: 0, badRanges: bad, sourceHash: sourceHash,
            rereadHash: rereadHash, result: text))
    }
}
