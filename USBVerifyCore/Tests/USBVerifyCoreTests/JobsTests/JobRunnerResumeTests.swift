import Foundation
import Testing

@testable import USBVerifyCore

private let resumeChunkSize = 4 * Defaults.alignment

private final class OffsetBox: @unchecked Sendable {
    var values: [Int64] = []
}

@Test
func resumeTailStepsBackToTheFirstBadChunk() async throws {
    let data = (0..<(resumeChunkSize * 4 + 19)).map { UInt8($0 % 251) }
    let (harness, runner) = try makeHarness(data: data, mode: .quick)
    let pauseGate = ClockBox()
    harness.drive.flipByteOnWrite(fileOffset: Int64(resumeChunkSize * 2), times: 1)
    harness.drive.beforeWrite = { _, offset, _ in
        if pauseGate.value == 0, offset >= Int64(resumeChunkSize * 3) {
            pauseGate.value = 1
            throw VerifyError.driveDisconnected(atOffset: offset)
        }
    }
    let paused = await runner.run()
    #expect(paused.status == .paused(.driveDisconnected))
    let saved = try #require(try harness.store.load(id: runner.currentJob.id))
    let writesBeforeResume = harness.drive.writeCount
    let resumedOffsets = OffsetBox()
    harness.drive.beforeWrite = { _, offset, _ in resumedOffsets.values.append(offset) }
    let resumed = JobRunner(
        job: saved, volume: harness.volume, io: harness.drive, volumeControl: harness.control,
        store: harness.store, clock: testClock())
    let finished = await resumed.run()
    #expect(finished.results[0] == .passed(sourceHash: summaryHash(data), rereadHash: summaryHash(data)))
    #expect(harness.drive.contents(of: harness.finalPath) == data)
    #expect(writesBeforeResume == 3)
    #expect(resumedOffsets.values.first == Int64(resumeChunkSize * 2))
    #expect(!resumedOffsets.values.contains(0))
    #expect(!resumedOffsets.values.contains(Int64(resumeChunkSize)))
}

@Test
func resumeMissingTempFileStartsAtZero() async throws {
    let data = Array(repeating: UInt8(9), count: resumeChunkSize + 3)
    let (harness, runner) = try makeHarness(data: data)
    harness.drive.beforeWrite = { _, _, _ in throw VerifyError.driveDisconnected(atOffset: 0) }
    let paused = await runner.run()
    #expect(paused.status == .paused(.driveDisconnected))
    try harness.drive.removeFile(path: harness.tempPath)
    let saved = try #require(try harness.store.load(id: runner.currentJob.id))
    harness.drive.beforeWrite = nil
    let resumed = JobRunner(
        job: saved, volume: harness.volume, io: harness.drive, volumeControl: harness.control,
        store: harness.store, clock: testClock())
    let finished = await resumed.run()
    #expect(finished.results[0] == .passed(sourceHash: summaryHash(data), rereadHash: summaryHash(data)))
    #expect(harness.drive.contents(of: harness.finalPath) == data)
}

@Test
func changedSourceAfterPauseRestartsFileAndUpdatesIdentity() async throws {
    let oldData = Array(repeating: UInt8(1), count: resumeChunkSize + 3)
    let newData = Array(repeating: UInt8(8), count: resumeChunkSize + 3)
    let (harness, runner) = try makeHarness(data: oldData)
    let pauseGate = ClockBox()
    harness.drive.beforeWrite = { _, offset, _ in
        if pauseGate.value == 0, offset >= Int64(resumeChunkSize) {
            pauseGate.value = 1
            throw VerifyError.driveDisconnected(atOffset: offset)
        }
    }
    let paused = await runner.run()
    #expect(paused.status == .paused(.driveDisconnected))
    harness.drive.changeSource(path: harness.sourcePath, data: newData)
    let saved = try #require(try harness.store.load(id: runner.currentJob.id))
    harness.drive.beforeWrite = nil
    let resumed = JobRunner(
        job: saved, volume: harness.volume, io: harness.drive, volumeControl: harness.control,
        store: harness.store, clock: testClock())
    let finished = await resumed.run()
    #expect(finished.results[0] == .passed(sourceHash: summaryHash(newData), rereadHash: summaryHash(newData)))
    #expect(harness.drive.contents(of: harness.finalPath) == newData)
    #expect(finished.job.files[0].sourceIdentity.size == Int64(newData.count))
    #expect(finished.job.files[0].sourceIdentity.modifiedTimeNs == 2)
}

@Test
func changedSourceBeforeRunFailsWithoutFinalFile() async throws {
    let original = [UInt8](repeating: 2, count: resumeChunkSize)
    let changed = [UInt8](repeating: 3, count: resumeChunkSize)
    let (harness, runner) = try makeHarness(data: original)
    harness.drive.changeSource(path: harness.sourcePath, data: changed)
    let result = await runner.run()
    #expect(result.results[0] == .failed(reason: .sourceChanged, badRanges: []))
    #expect(harness.drive.fileSize(path: harness.finalPath) == nil)
}

@Test
func keepScanningReportsBothPermanentBadRanges() async throws {
    let data = Array(repeating: UInt8(4), count: resumeChunkSize * 3)
    let (harness, runner) = try makeHarness(data: data)
    let firstBad = Int64(resumeChunkSize)
    let secondBad = Int64(resumeChunkSize * 2)
    harness.drive.flipByteOnWrite(fileOffset: firstBad, times: 100)
    harness.drive.flipByteOnWrite(fileOffset: secondBad, times: 100)
    let first = await runner.run()
    #expect(
        first.results[0]
            == .failed(
                reason: .chunkFailedAfterRetries, badRanges: [BadRange(offset: firstBad, length: 1)]))
    #expect(harness.drive.fileSize(path: harness.failedPath) == Int64(resumeChunkSize * 2))
    #expect(runner.currentJob.files[0].failedChunkIndex == 1)
    #expect(try harness.store.load(id: runner.currentJob.id) != nil)
    try runner.prepareKeepScanning(fileIndex: 0)
    let second = await runner.run()
    #expect(
        second.results[0]
            == .failed(
                reason: .finalCheckMismatch,
                badRanges: [BadRange(offset: firstBad, length: 1), BadRange(offset: secondBad, length: 1)]))
    #expect(
        second.job.files[0].badRanges == [
            BadRange(offset: firstBad, length: 1), BadRange(offset: secondBad, length: 1),
        ])
    runner.discardPartialFiles()
    #expect(harness.drive.fileSize(path: harness.failedPath) == nil)
}

@Test
func strictProgressIsMonotonicAndCoversAllPhases() async throws {
    let data = Array(repeating: UInt8(5), count: resumeChunkSize * 3 + 1)
    let (harness, runner) = try makeHarness(data: data)
    let (_, events) = await run(runner)
    let progress = events.compactMap { event -> ProgressSnapshot? in
        if case .progress(let value) = event { return value }
        return nil
    }
    let phases = events.compactMap { event -> JobPhase? in
        if case .phase(_, let phase) = event { return phase }
        return nil
    }
    #expect(progress.count >= 3)
    #expect(progress.allSatisfy { $0.fileBytesDone <= data.count })
    #expect(zip(progress, progress.dropFirst()).allSatisfy { $0.fileBytesDone <= $1.fileBytesDone })
    #expect(progress.last?.fileBytesDone == Int64(data.count))
    #expect(phases == [.copying, .finalizing, .remounting, .finalCheck, .renaming])
    #expect(harness.drive.contents(of: harness.finalPath) == data)
}

@Test
func multiFileBatchContinuesAndCompletesByteProgress() async throws {
    let mount = "/Volumes/Batch"
    let drive = FakeDrive(mountPath: mount, capacityBytes: 10_000_000)
    let values = [
        [UInt8(1)],
        Array(repeating: UInt8(2), count: resumeChunkSize + 1),
        [UInt8(3)],
    ]
    for (index, value) in values.enumerated() {
        drive.addSource(path: "/source/\(index).bin", data: value)
    }
    let volume = makeTestVolume(drive: drive, mountPath: mount)
    let control = FakeVolumeControl(drive: drive, mountPath: mount)
    let states = try values.indices.map { index in
        try JobFactory.fileState(
            sourcePath: "/source/\(index).bin", destinationFolder: "Exports", finalName: "\(index).bin",
            chunkSize: resumeChunkSize, io: drive)
    }
    let store = JobStore(directory: NSTemporaryDirectory() + "USBVerifyBatch-" + UUID().uuidString)
    let sink = FakeRunSink()
    let job = JobFactory.job(volume: volume, mode: .strict, files: states)
    let runner = JobRunner(
        job: job, volume: volume, io: drive, volumeControl: control, store: store, sink: sink,
        clock: testClock())
    drive.flipByteOnWrite(fileOffset: 1, times: 100)
    let (_, events) = await run(runner)
    let progress = events.compactMap { event -> ProgressSnapshot? in
        if case .progress(let value) = event { return value }
        return nil
    }
    #expect(
        runner.currentJob.files.map(\.result) == [
            .some(.passed(sourceHash: summaryHash(values[0]), rereadHash: summaryHash(values[0]))),
            .some(.failed(reason: .chunkFailedAfterRetries, badRanges: [BadRange(offset: 1, length: 1)])),
            .some(.passed(sourceHash: summaryHash(values[2]), rereadHash: summaryHash(values[2]))),
        ])
    #expect(progress.last?.batchBytesDone == progress.last?.batchBytesTotal)
    #expect(sink.records.map(\.result) == ["PASS", "FAIL", "PASS"])
}

@Test
func pausedJobLoadsAndUsesTheNewMountPath() async throws {
    let oldMount = "/Volumes/Old"
    let newMount = "/Volumes/New"
    let data = [UInt8](repeating: 6, count: resumeChunkSize + 2)
    let drive = FakeDrive(mountPath: oldMount)
    drive.addSource(path: "/source/copy.bin", data: data)
    let oldVolume = makeTestVolume(drive: drive, mountPath: oldMount)
    let control = FakeVolumeControl(drive: drive, mountPath: oldMount)
    let state = try JobFactory.fileState(
        sourcePath: "/source/copy.bin", destinationFolder: "Exports", finalName: "copy.bin",
        chunkSize: resumeChunkSize, io: drive)
    let store = JobStore(directory: NSTemporaryDirectory() + "USBVerifyMount-" + UUID().uuidString)
    let runner = JobRunner(
        job: JobFactory.job(volume: oldVolume, mode: .quick, files: [state]), volume: oldVolume, io: drive,
        volumeControl: control, store: store, clock: testClock())
    drive.beforeWrite = { _, _, _ in throw VerifyError.driveDisconnected(atOffset: 0) }
    let paused = await runner.run()
    #expect(paused.status == .paused(.driveDisconnected))
    let loaded = try #require(try store.loadAll().first)
    #expect(loaded.files[0].destinationFolder == "Exports")
    let newDrive = FakeDrive(mountPath: newMount)
    newDrive.addSource(path: "/source/copy.bin", data: data)
    let newVolume = makeTestVolume(drive: newDrive, mountPath: newMount)
    let newControl = FakeVolumeControl(drive: newDrive, mountPath: newMount)
    let resumed = JobRunner(
        job: loaded, volume: newVolume, io: newDrive, volumeControl: newControl, store: store,
        clock: testClock())
    let finished = await resumed.run()
    #expect(finished.results[0] == .passed(sourceHash: summaryHash(data), rereadHash: summaryHash(data)))
    #expect(newDrive.contents(of: "\(newMount)/Exports/copy.bin") == data)
}

@Test
func cacheGuardWarnsOnlyForFastLargeReadBack() async throws {
    let data = [UInt8](repeating: 7, count: 1 << 20)
    let (fastHarness, fastRunner) = try makeHarness(data: data)
    var fastJob = fastRunner.currentJob
    fastJob.files[0].chunkSize = 1 << 20
    let fastBox = ClockBox()
    let fastClock = EngineClock(
        now: {
            fastBox.value += 0.000000001
            return fastBox.value
        }, sleep: { _ in })
    let fast = JobRunner(
        job: fastJob, volume: fastHarness.volume, io: fastHarness.drive,
        volumeControl: fastHarness.control, clock: fastClock)
    let (_, fastEvents) = await run(fast)
    #expect(
        fastEvents.contains { event in
            if case .warning = event { return true }
            return false
        })
    let (normalHarness, normalRunner) = try makeHarness(data: data)
    var normalJob = normalRunner.currentJob
    normalJob.files[0].chunkSize = 1 << 20
    let normalBox = ClockBox()
    let normalClock = EngineClock(
        now: {
            normalBox.value += 1.0
            return normalBox.value
        }, sleep: { _ in })
    let normal = JobRunner(
        job: normalJob, volume: normalHarness.volume, io: normalHarness.drive,
        volumeControl: normalHarness.control, clock: normalClock)
    let (_, normalEvents) = await run(normal)
    #expect(
        !normalEvents.contains { event in
            if case .warning = event { return true }
            return false
        })
}

@Test
func verifyOnlyReportsRemountCorruptionAndHistoryKind() async throws {
    let mount = "/Volumes/Verify"
    let drive = FakeDrive(mountPath: mount)
    let data = [UInt8](repeating: 8, count: 20)
    drive.addSource(path: "/source/a.bin", data: data)
    let writer = try drive.createWriter(path: "\(mount)/a.bin", truncate: true)
    try data.withUnsafeBytes { try writer.write($0, at: 0) }
    try writer.close()
    drive.corruptOnRemount(pathSuffix: "/a.bin", fileOffset: 7)
    let sink = FakeRunSink()
    let runner = VerifyOnlyRunner(
        items: [VerifyOnlyItem(sourcePath: "/source/a.bin", destinationFolder: "", name: "a.bin")],
        volume: makeTestVolume(drive: drive, mountPath: mount), io: drive,
        volumeControl: FakeVolumeControl(drive: drive, mountPath: mount), sink: sink,
        clock: testClock(), chunkSize: resumeChunkSize)
    let result = await runner.run()
    #expect(result == [.failed(reason: .finalCheckMismatch, badRanges: [BadRange(offset: 7, length: 1)])])
    #expect(sink.records.count == 1)
    #expect(sink.records[0].result == "FAIL")
    #expect(sink.records[0].kind == .verifyOnly)
}
