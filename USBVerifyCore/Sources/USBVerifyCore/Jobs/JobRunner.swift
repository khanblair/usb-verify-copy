import Foundation

public struct JobSummary: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case completed
        case paused(PauseReason)
        case cancelled
    }
    public var status: Status
    public var job: PersistedJob
    public var results: [FileResult?] { job.files.map(\.result) }
}

/// Runs a batch of files for one volume, one file at a time (spec sections 6 to 10).
/// Create a new runner to resume a paused job: pass the saved `PersistedJob` and the volume found again by its UUID.
public final class JobRunner: @unchecked Sendable {
    public let control = JobControl()
    public let events: AsyncStream<JobEvent>

    private let continuation: AsyncStream<JobEvent>.Continuation
    private var job: PersistedJob
    private var volume: Volume
    private let io: any DriveIO
    private let volumeControl: any VolumeControl
    private let store: JobStore?
    private let sink: (any RunSink)?
    private let environment: RunEnvironment
    private let clock: EngineClock

    public init(job: PersistedJob, volume: Volume, io: any DriveIO, volumeControl: any VolumeControl,
                store: JobStore? = nil, sink: (any RunSink)? = nil,
                environment: RunEnvironment = RunEnvironment(), clock: EngineClock = .system) {
        self.job = job
        self.volume = volume
        self.io = io
        self.volumeControl = volumeControl
        self.store = store
        self.sink = sink
        self.environment = environment
        self.clock = clock
        var cont: AsyncStream<JobEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        self.continuation = cont
    }

    public var currentJob: PersistedJob { job }

    /// Runs from `currentIndex` to the end, or until a pause or cancel.
    public func run() async -> JobSummary {
        job.pausedReason = nil
        control.clearPause()
        let total = job.files.reduce(Int64(0)) { $0 + $1.sourceIdentity.size }
        var status = JobSummary.Status.completed
        var index = job.currentIndex

        while index < job.files.count {
            if control.isCancelled {
                for rest in index..<job.files.count where job.files[rest].result == nil {
                    job.files[rest].result = .cancelled
                    job.files[rest].phase = .cancelled
                }
                status = .cancelled
                break
            }
            if job.files[index].result != nil { index += 1; continue }

            job.currentIndex = index
            let before = job.files[..<index].reduce(Int64(0)) { $0 + $1.sourceIdentity.size }
            let started = Date()
            let fileIndex = index
            let copier = FileCopier(
                fileIndex: fileIndex, fileCount: job.files.count, state: job.files[index], mode: job.mode,
                volume: volume, io: io, volumeControl: volumeControl, clock: clock, control: control,
                batchBytesBefore: before, batchBytesTotal: total,
                emit: { [continuation] event in continuation.yield(event) },
                persist: { [weak self] state in self?.saveFile(fileIndex, state) })
            let outcome = await copier.run()
            job.files[index] = copier.state

            switch outcome {
            case .finished(let result):
                job.files[index].result = result
                continuation.yield(.fileFinished(fileIndex: index, result))
                await record(copier.state, result: result, started: started)
                if case .cancelled = result { status = .cancelled }
                index += 1
            case .paused(let reason, let offset):
                job.pausedReason = reason
                saveJob()
                continuation.yield(.paused(reason, atOffset: offset))
                continuation.yield(.finished)
                continuation.finish()
                return JobSummary(status: .paused(reason), job: job)
            }
            if status == .cancelled { continue }
        }

        if status == .cancelled {
            for rest in index..<job.files.count where job.files[rest].result == nil {
                job.files[rest].result = .cancelled
            }
        }
        // Keep the state file when a failed file can still be scanned further. Otherwise the job is done.
        let canKeepScanning = job.files.contains { $0.failedChunkIndex != nil }
        if canKeepScanning { saveJob() } else { try? store?.delete(id: job.id) }
        continuation.yield(.finished)
        continuation.finish()
        return JobSummary(status: status, job: job)
    }

    /// Prepares a file that stopped at a failed chunk for "Keep scanning". Call `run()` afterwards.
    public func prepareKeepScanning(fileIndex: Int) throws {
        guard job.files.indices.contains(fileIndex), job.files[fileIndex].failedChunkIndex != nil else { return }
        let file = job.files[fileIndex]
        let guardrail = DestinationGuard(volume: volume)
        let failedPath = try guardrail.path(folder: file.destinationFolder, name: file.finalName + Defaults.failedSuffix)
        let tempPath = try guardrail.path(folder: file.destinationFolder, name: file.tempName)
        if io.fileSize(path: failedPath) != nil {
            try io.rename(from: failedPath, to: tempPath)
        }
        job.files[fileIndex].keepScanning = true
        job.files[fileIndex].result = nil
        job.files[fileIndex].phase = .queued
        job.currentIndex = fileIndex
    }

    /// Deletes partial files of failed or cancelled files (the user chose "delete").
    public func discardPartialFiles() {
        let guardrail = DestinationGuard(volume: volume)
        for file in job.files {
            if case .passed = file.result { continue }
            for name in [file.tempName, file.finalName + Defaults.failedSuffix] {
                if let path = try? guardrail.path(folder: file.destinationFolder, name: name),
                   io.fileSize(path: path) != nil {
                    try? io.removeFile(path: path)
                }
            }
        }
    }

    private func saveFile(_ index: Int, _ state: FileJobState) {
        guard job.files.indices.contains(index) else { return }
        job.files[index] = state
        saveJob()
    }

    private func saveJob() {
        job.updatedAt = Date()
        try? store?.save(job)
    }

    private func record(_ state: FileJobState, result: FileResult, started: Date) async {
        guard let sink else { return }
        var resultText = "FAIL"
        var sourceHash: String?
        var rereadHash: String?
        var bad = state.badRanges
        switch result {
        case .passed(let source, let reread):
            resultText = "PASS"; sourceHash = source; rereadHash = reread
        case .failed(_, let ranges):
            bad = ranges
        case .skipped: resultText = "SKIPPED"
        case .cancelled: resultText = "CANCELLED"
        }
        var notes = state.warnings.filter { !$0.hasPrefix("F_FULLFSYNC") }
        if let detail = state.errorDetail { notes.append(detail) }
        if case .failed(let reason, _) = result { notes.append("reason: \(reason.rawValue)") }
        let destination = [volume.mountPath, state.destinationFolder, state.finalName]
            .filter { !$0.isEmpty }.joined(separator: "/")
        await sink.record(RunRecord(
            startedAt: started, endedAt: Date(), kind: job.kind, mode: job.mode, driveName: volume.name,
            volumeUUID: volume.id.uuid, model: volume.model, filesystem: volume.filesystem.displayName,
            filesystemDriver: environment.filesystemDriver, macOSVersion: environment.macOSVersion,
            route: volume.route ?? environment.route, sourcePath: state.sourcePath, destinationPath: destination,
            sizeBytes: state.sourceIdentity.size, chunkSize: state.chunkSize, retries: state.retries,
            badRanges: bad, fullSyncWarnings: state.warnings.filter { $0.hasPrefix("F_FULLFSYNC") },
            sourceHash: sourceHash, rereadHash: rereadHash, result: resultText, notes: notes))
    }
}
