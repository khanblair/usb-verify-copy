import Foundation

/// Copies and verifies one file (spec section 8). One instance handles one file, once.
final class FileCopier {
    private(set) var state: FileJobState
    private var volume: Volume
    private let mode: VerifyMode
    private let fileIndex: Int
    private let fileCount: Int
    private let io: any DriveIO
    private let volumeControl: any VolumeControl
    private let clock: EngineClock
    private let control: JobControl
    private let emit: @Sendable (JobEvent) -> Void
    private let persist: @Sendable (FileJobState) -> Void
    private let batchBytesBefore: Int64
    private let batchBytesTotal: Int64

    private var plan: ChunkPlan
    private var runStart = 0.0
    private var lastProgress = -1.0
    private var unitsDone: Int64 = 0
    private var baselineUnits: Int64 = 0
    private var chunksRetried = 0
    private var currentOffset: Int64 = 0
    private var cacheWarned = false
    private var phase: JobPhase = .copying

    init(
        fileIndex: Int, fileCount: Int, state: FileJobState, mode: VerifyMode, volume: Volume,
        io: any DriveIO, volumeControl: any VolumeControl, clock: EngineClock, control: JobControl,
        batchBytesBefore: Int64, batchBytesTotal: Int64,
        emit: @escaping @Sendable (JobEvent) -> Void, persist: @escaping @Sendable (FileJobState) -> Void
    ) {
        self.fileIndex = fileIndex
        self.fileCount = fileCount
        self.state = state
        self.mode = mode
        self.volume = volume
        self.io = io
        self.volumeControl = volumeControl
        self.clock = clock
        self.control = control
        self.batchBytesBefore = batchBytesBefore
        self.batchBytesTotal = batchBytesTotal
        self.emit = emit
        self.persist = persist
        self.plan = ChunkPlan(size: state.sourceIdentity.size, chunkSize: state.chunkSize)
    }

    // MARK: Entry point

    func run() async -> FileRunOutcome {
        runStart = clock.now()
        do {
            return try await execute()
        } catch Interrupt.cancel {
            state.phase = .cancelled
            persist(state)
            return .finished(.cancelled)
        } catch Interrupt.pause(let reason, let offset) {
            return paused(reason, offset)
        } catch VerifyError.driveDisconnected(let offset) {
            return paused(.driveDisconnected, offset)
        } catch VerifyError.sourceChanged {
            return failed(.sourceChanged, [])
        } catch let error as VerifyError {
            state.errorDetail = error.technicalDetail
            return failed(.ioError, [])
        } catch {
            state.errorDetail = "\(error)"
            return failed(.ioError, [])
        }
    }

    private func paused(_ reason: PauseReason, _ offset: Int64) -> FileRunOutcome {
        state.phase = .paused
        persist(state)
        return .paused(reason, atOffset: offset)
    }

    // MARK: Copy loop

    private func execute() async throws -> FileRunOutcome {
        setPhase(.copying)
        let source = try io.openSource(path: state.sourcePath)
        defer { source.close() }

        if source.identity != state.sourceIdentity {
            guard !state.chunkHashes.isEmpty else { throw VerifyError.sourceChanged }
            // The source changed while the job was paused: start this file again from byte 0.
            restartFromZero(newIdentity: source.identity)
        }
        plan = ChunkPlan(size: state.sourceIdentity.size, chunkSize: state.chunkSize)

        var startIndex = try prepareResume()
        var sourceHasher = StreamingHasher()
        let bufferA = AlignedBuffer(capacity: max(min(plan.chunkSize, Int(max(plan.size, 1))), Defaults.alignment))
        let bufferB = AlignedBuffer(capacity: bufferA.capacity)

        // The whole-file source hash needs the chunks that an earlier run already wrote.
        for index in 0..<startIndex {
            let length = plan.length(of: index)
            currentOffset = plan.offset(of: index)
            let read = try ChunkIO.readSource(source, into: bufferA, offset: currentOffset, length: length) { _ in
                try self.checkInterrupt()
            }
            if read != length { throw VerifyError.sourceChanged }
            sourceHasher.update(bufferA.bytes(count: length))
        }
        baselineUnits = Int64(startIndex) * Int64(plan.chunkSize) * (mode == .strict ? 2 : 1)
        baselineUnits = min(baselineUnits, plan.size * (mode == .strict ? 2 : 1))
        unitsDone = baselineUnits

        let tempPath = try drivePath(state.tempName)
        try io.createDirectory(path: (tempPath as NSString).deletingLastPathComponent)
        let writer = try io.createWriter(path: tempPath, truncate: startIndex == 0)
        defer { try? writer.close() }
        let reader: (any DestinationReader)? = mode == .strict ? try io.openReader(path: tempPath) : nil
        defer { reader?.close() }

        while startIndex < plan.count {
            let index = startIndex
            let offset = plan.offset(of: index)
            let length = plan.length(of: index)
            currentOffset = offset
            try checkInterrupt()

            let read = try ChunkIO.readSource(source, into: bufferA, offset: offset, length: length) { _ in
                try self.checkInterrupt()
            }
            if read != length { throw VerifyError.sourceChanged }
            sourceHasher.update(bufferA.bytes(count: length))
            let hash = StreamingHasher.hash(of: bufferA.bytes(count: length))

            var attempt = 0
            var verified = false
            var diff: [BadRange] = []
            while true {
                try ChunkIO.write(writer, from: bufferA, offset: offset, length: length) { done in
                    try self.checkInterrupt()
                    self.addWork(done)
                    self.reportProgress()
                }
                if let warning = try writer.flush() { addWarning(warning) }
                guard let reader else {
                    verified = true
                    break
                }

                let started = clock.now()
                let got = try ChunkIO.readDestination(reader, into: bufferB, offset: offset, length: length) { done in
                    try self.checkInterrupt()
                    self.addWork(done)
                    self.reportProgress()
                }
                checkCacheGuard(bytes: got, seconds: clock.now() - started)
                if got == length && bufferA.equals(bufferB, count: length) {
                    verified = true
                    break
                }

                diff = bufferA.differences(from: bufferB, count: min(got, length))
                if got < length { diff.append(BadRange(offset: Int64(got), length: Int64(length - got))) }
                if attempt >= Defaults.maxRetries { break }
                attempt += 1
                state.retries += 1
            }
            if attempt > 0 { chunksRetried += 1 }

            if !verified {
                let absolute = ChunkIO.merge(diff.map { BadRange(offset: offset + $0.offset, length: $0.length) })
                if state.keepScanning {
                    state.badRanges = ChunkIO.merge(state.badRanges + absolute)
                } else {
                    state.failedChunkIndex = index
                    state.badRanges = absolute
                    try? writer.close()
                    reader?.close()
                    return failed(.chunkFailedAfterRetries, absolute)
                }
            }
            state.chunkHashes.append(hash)
            persist(state)
            reportProgress(force: true)
            startIndex += 1
        }

        try writer.close()
        reader?.close()
        return try await finalize(sourceHash: sourceHasher.finalize())
    }

    // MARK: Resume

    /// Returns the chunk index to continue from. Re-reads the last chunks when resuming (spec section 10).
    private func prepareResume() throws -> Int {
        var count = state.chunkHashes.count
        guard count > 0 else {
            state.failedChunkIndex = nil
            return 0
        }
        if count > plan.count {
            restartFromZero(newIdentity: state.sourceIdentity)
            return 0
        }
        let tempPath = try drivePath(state.tempName)
        guard let size = io.fileSize(path: tempPath), size >= plan.offset(of: count - 1) else {
            restartFromZero(newIdentity: state.sourceIdentity)
            return 0
        }
        // A file that stopped at a failed chunk continues exactly there. No tail check.
        if state.failedChunkIndex != nil {
            state.failedChunkIndex = nil
            return count
        }
        let reader = try io.openReader(path: tempPath)
        defer { reader.close() }
        let buffer = AlignedBuffer(capacity: max(min(plan.chunkSize, Int(max(plan.size, 1))), Defaults.alignment))
        func chunkMatches(_ index: Int) throws -> Bool {
            let length = plan.length(of: index)
            let got = try ChunkIO.readDestination(reader, into: buffer, offset: plan.offset(of: index), length: length)
            { _ in try self.checkInterrupt() }
            return got == length && StreamingHasher.hash(of: buffer.bytes(count: length)) == state.chunkHashes[index]
        }
        var firstBad: Int?
        for index in max(0, count - Defaults.resumeTailChunks)..<count {
            if try !chunkMatches(index) {
                firstBad = index
                break
            }
        }
        if var bad = firstBad {
            while bad > 0 {
                if try chunkMatches(bad - 1) { break }
                bad -= 1
            }
            count = bad
        }
        state.chunkHashes = Array(state.chunkHashes.prefix(count))
        let keepBefore = plan.offset(of: min(count, max(plan.count - 1, 0)))
        state.badRanges = state.badRanges.filter { $0.end <= keepBefore }
        return count
    }

    private func restartFromZero(newIdentity: FileIdentity) {
        state.chunkHashes = []
        state.badRanges = []
        state.failedChunkIndex = nil
        state.sourceIdentity = newIdentity
        plan = ChunkPlan(size: newIdentity.size, chunkSize: state.chunkSize)
    }

    // MARK: Final pass

    private func finalize(sourceHash: String) async throws -> FileRunOutcome {
        setPhase(.finalizing)
        guard state.chunkHashes.count == plan.count else {
            state.errorDetail = "chunk hash count \(state.chunkHashes.count) does not match chunk count \(plan.count)"
            return failed(.ioError, [])
        }
        let current = try io.openSource(path: state.sourcePath)
        let identity = current.identity
        current.close()
        if identity != state.sourceIdentity { return failed(.sourceChanged, []) }

        try await unmountWithRetry()
        setPhase(.remounting)
        do {
            volume.mountPath = try await volumeControl.mount(volume: volume.id)
        } catch VerifyError.volumeNotFound {
            throw VerifyError.driveDisconnected(atOffset: plan.size)
        }

        setPhase(.finalCheck)
        persist(state)
        let tempPath = try drivePath(state.tempName)
        let copyUnits = plan.size * (mode == .strict ? 2 : 1)
        let passResult = try FinalPass.run(
            io: io, sourcePath: state.sourcePath, destinationPath: tempPath, plan: plan,
            expectedChunkHashes: state.chunkHashes,
            interrupt: { try self.checkInterrupt() },
            progress: { done in
                self.unitsDone = copyUnits + done
                self.reportProgress()
            })
        let allBad = ChunkIO.merge(state.badRanges + passResult.badRanges)
        if !allBad.isEmpty { return failed(.finalCheckMismatch, allBad) }
        if passResult.rereadHash != sourceHash { return failed(.wholeFileHashMismatch, []) }

        setPhase(.renaming)
        let finalPath = try drivePath(state.finalName)
        if io.fileSize(path: finalPath) != nil {
            guard state.replaceExisting else {
                state.errorDetail = "A file named \(state.finalName) already exists on the drive."
                return failed(.nameConflict, [])
            }
            try io.removeFile(path: finalPath)
        }
        try io.rename(from: tempPath, to: finalPath)
        let result = FileResult.passed(sourceHash: sourceHash, rereadHash: passResult.rereadHash)
        state.result = result
        state.phase = .passed
        persist(state)
        reportProgress(force: true)
        return .finished(result)
    }

    private func unmountWithRetry() async throws {
        while true {
            try checkInterrupt()
            do {
                try await volumeControl.unmount(volume: volume.id)
                return
            } catch VerifyError.unmountBusy(let blockers) {
                setPhase(.waitingUnmount)
                emit(.waitingForUnmount(blockers: blockers))
                while !control.takeRetry() {
                    try checkInterrupt()
                    await clock.sleep(0.25)
                }
                setPhase(.finalizing)
            } catch VerifyError.volumeNotFound {
                throw VerifyError.driveDisconnected(atOffset: plan.size)
            }
        }
    }

    // MARK: Helpers

    private func failed(_ reason: FailureReason, _ ranges: [BadRange]) -> FileRunOutcome {
        renamePartialToFailed()
        state.phase = .failed
        let result = FileResult.failed(reason: reason, badRanges: ranges)
        state.result = result
        persist(state)
        return .finished(result)
    }

    /// A failed file never keeps a name that looks valid (decision D2, D5).
    private func renamePartialToFailed() {
        guard let temp = try? drivePath(state.tempName), io.fileSize(path: temp) != nil,
            let failedPath = try? drivePath(state.finalName + Defaults.failedSuffix)
        else { return }
        try? io.removeFile(path: failedPath)
        try? io.rename(from: temp, to: failedPath)
    }

    private func drivePath(_ name: String) throws -> String {
        let guardrail = DestinationGuard(volume: volume)
        let path = try guardrail.path(folder: state.destinationFolder, name: name)
        try guardrail.validate(path: path)
        return path
    }

    private func checkInterrupt() throws {
        if control.isCancelled { throw Interrupt.cancel }
        if let reason = control.pendingPause { throw Interrupt.pause(reason, atOffset: currentOffset) }
    }

    private func setPhase(_ newPhase: JobPhase) {
        phase = newPhase
        state.phase = newPhase
        emit(.phase(fileIndex: fileIndex, newPhase))
        reportProgress(force: true)
    }

    private func addWork(_ bytes: Int) { unitsDone += Int64(bytes) }

    private func addWarning(_ text: String) {
        state.warnings.append(text)
        emit(.warning(text))
    }

    /// A read-back faster than the drive can deliver came from a cache, so it proves nothing.
    private func checkCacheGuard(bytes: Int, seconds: Double) {
        guard !cacheWarned, bytes >= 1 << 20, seconds > 0 else { return }
        let rate = Double(bytes) / seconds
        if rate > Defaults.cacheGuardBytesPerSecond {
            cacheWarned = true
            addWarning(
                "Read-back ran at \(Int(rate / 1_000_000)) MB/s, faster than a USB drive can deliver. The read probably came from a cache, so it is not trusted."
            )
        }
    }

    private func reportProgress(force: Bool = false) {
        let now = clock.now()
        if !force && lastProgress >= 0 && now - lastProgress < 0.2 { return }
        lastProgress = now
        let passes: Int64 = mode == .strict ? 3 : 2
        let total = max(plan.size * passes, 1)
        let done = min(unitsDone, total)
        let elapsed = max(now - runStart, 0.001)
        let speed = Double(max(unitsDone - baselineUnits, 0)) / elapsed
        let remaining = speed > 0 && total > done ? Double(total - done) / speed : nil
        let fileDone = plan.size == 0 ? 0 : min(plan.size, done * plan.size / total)
        emit(
            .progress(
                ProgressSnapshot(
                    fileIndex: fileIndex, fileCount: fileCount, fileName: state.finalName, phase: phase,
                    fileBytesDone: fileDone, fileBytesTotal: plan.size, chunksVerified: state.chunkHashes.count,
                    chunksRetried: chunksRetried, bytesPerSecond: speed, secondsRemaining: remaining,
                    batchBytesDone: batchBytesBefore + fileDone, batchBytesTotal: batchBytesTotal)))
    }
}
