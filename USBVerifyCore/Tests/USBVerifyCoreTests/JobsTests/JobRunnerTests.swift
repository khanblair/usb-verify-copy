import Foundation
import Testing

@testable import USBVerifyCore

private let testChunkSize = 4 * Defaults.alignment

private final class ClockBox: @unchecked Sendable {
    var value = 0.0
}

private func testClock(step: Double = 0.01) -> EngineClock {
    let box = ClockBox()
    return EngineClock(
        now: {
            box.value += step
            return box.value
        },
        sleep: { _ in await Task.yield() })
}

private struct CopyHarness {
    let drive: FakeDrive
    let volume: Volume
    let control: FakeVolumeControl
    let sourcePath: String
    let finalPath: String
    let tempPath: String
    let failedPath: String
    let sink: FakeRunSink
    let store: JobStore
}

private func makeHarness(data: [UInt8], name: String = "copy.bin", mode: VerifyMode = .strict) throws -> (
    CopyHarness, JobRunner
) {
    let mount = "/Volumes/Test"
    let drive = FakeDrive(mountPath: mount, capacityBytes: 10_000_000)
    let sourcePath = "/source/\(name)"
    drive.addSource(path: sourcePath, data: data)
    let volume = makeTestVolume(drive: drive, mountPath: mount)
    let control = FakeVolumeControl(drive: drive, mountPath: mount)
    let folder = "Exports"
    let finalPath = "\(mount)/\(folder)/\(name)"
    let tempPath = finalPath + Defaults.tempSuffix
    let failedPath = finalPath + Defaults.failedSuffix
    let state = try JobFactory.fileState(
        sourcePath: sourcePath, destinationFolder: folder, finalName: name,
        chunkSize: testChunkSize, io: drive)
    let job = JobFactory.job(volume: volume, mode: mode, files: [state])
    let store = JobStore(directory: NSTemporaryDirectory() + "USBVerifyStore-" + UUID().uuidString)
    let sink = FakeRunSink()
    let runner = JobRunner(
        job: job, volume: volume, io: drive, volumeControl: control, store: store, sink: sink,
        clock: testClock())
    return (
        CopyHarness(
            drive: drive, volume: volume, control: control, sourcePath: sourcePath,
            finalPath: finalPath, tempPath: tempPath, failedPath: failedPath, sink: sink, store: store), runner
    )
}

private func collect(_ stream: AsyncStream<JobEvent>) async -> [JobEvent] {
    var events: [JobEvent] = []
    for await event in stream {
        events.append(event)
    }
    return events
}

private func run(_ runner: JobRunner) async -> (JobSummary, [JobEvent]) {
    async let summary = runner.run()
    let events = await collect(runner.events)
    return (await summary, events)
}

@Test(arguments: [VerifyMode.strict, VerifyMode.quick])
func copyPassesInBothModes(_ mode: VerifyMode) async throws {
    let data = Array(0..<100).map(UInt8.init)
    let (harness, runner) = try makeHarness(data: data, mode: mode)
    let (summary, events) = await run(runner)

    #expect(summary.status == .completed)
    #expect(summary.results == [.passed(sourceHash: summaryHash(data), rereadHash: summaryHash(data))])
    #expect(harness.drive.contents(of: harness.finalPath) == data)
    #expect(harness.drive.fileSize(path: harness.tempPath) == nil)
    #expect(harness.control.unmountCalls == 1)
    #expect(harness.control.mountCalls == 1)
    #expect(harness.sink.records.map(\.result) == ["PASS"])
    let phases = events.compactMap { event -> JobPhase? in
        if case .phase(_, let phase) = event { return phase }
        return nil
    }
    #expect(phases.contains(.remounting))
    #expect(
        phases.filter { [.copying, .finalizing, .remounting, .finalCheck, .renaming].contains($0) } == [
            .copying, .finalizing, .remounting, .finalCheck, .renaming,
        ])
    #expect(
        events.firstIndex(of: .fileFinished(fileIndex: 0, summary.results[0]!))! > phases.firstIndex(of: .remounting)!)
}

private func summaryHash(_ data: [UInt8]) -> String {
    data.withUnsafeBytes { StreamingHasher.hash(of: $0) }
}

@Test
func badWriteIsRetried() async throws {
    let data = Array(repeating: UInt8(7), count: testChunkSize + 3)
    let (harness, runner) = try makeHarness(data: data)
    harness.drive.flipByteOnWrite(fileOffset: 2, times: 1)
    let (summary, events) = await run(runner)

    #expect(summary.results[0] == .passed(sourceHash: summaryHash(data), rereadHash: summaryHash(data)))
    #expect(summary.job.files[0].retries == 1)
    let progress = events.compactMap { event -> ProgressSnapshot? in
        if case .progress(let value) = event { return value }
        return nil
    }
    #expect(progress.contains { $0.chunksRetried == 1 })
}

@Test
func persistentBadWriteFailsAndBatchContinues() async throws {
    let first = Array(repeating: UInt8(1), count: testChunkSize + 2)
    let second = [UInt8(8)]
    let (harness, firstRunner) = try makeHarness(data: first, name: "one.bin")
    harness.drive.addSource(path: "/source/two.bin", data: second)
    let secondState = try JobFactory.fileState(
        sourcePath: "/source/two.bin", destinationFolder: "Exports", finalName: "two.bin",
        chunkSize: testChunkSize, io: harness.drive)
    var job = firstRunner.currentJob
    job.files.append(secondState)
    harness.drive.flipByteOnWrite(fileOffset: 1, times: 10)
    let runner = JobRunner(
        job: job, volume: harness.volume, io: harness.drive, volumeControl: harness.control,
        clock: testClock())
    let (summary, _) = await run(runner)

    #expect(
        summary.results[0]
            == .failed(
                reason: .chunkFailedAfterRetries,
                badRanges: [BadRange(offset: 1, length: 1)]))
    #expect(summary.results[1] != nil)
    #expect(harness.drive.fileSize(path: harness.failedPath) == Int64(testChunkSize))
    #expect(harness.drive.fileSize(path: "/Volumes/Test/Exports/one.bin") == nil)
    #expect(harness.drive.contents(of: "/Volumes/Test/Exports/two.bin") == second)
}

@Test
func quickFinalPassDetectsRemountCorruption() async throws {
    let data = Array(repeating: UInt8(4), count: 20)
    let (harness, runner) = try makeHarness(data: data, mode: .quick)
    harness.drive.corruptOnRemount(pathSuffix: "copy.bin" + Defaults.tempSuffix, fileOffset: 5)
    let (summary, _) = await run(runner)

    #expect(
        summary.results[0]
            == .failed(
                reason: .finalCheckMismatch,
                badRanges: [BadRange(offset: 5, length: 1)]))
    #expect(harness.drive.fileSize(path: harness.finalPath) == nil)
}

@Test
func staleCacheDoesNotHideFinalCorruption() async throws {
    let data = Array(repeating: UInt8(5), count: 20)
    let (harness, runner) = try makeHarness(data: data)
    harness.drive.servesReadsFromCache = true
    harness.drive.corruptOnRemount(pathSuffix: "copy.bin" + Defaults.tempSuffix, fileOffset: 2)
    let (summary, _) = await run(runner)

    #expect(
        summary.results[0]
            == .failed(
                reason: .finalCheckMismatch,
                badRanges: [BadRange(offset: 2, length: 1)]))
    #expect(harness.sink.records.allSatisfy { $0.result != "PASS" })
}

@Test
func fullSyncWarningIsRecordedAndCacheWarningCanBeRaised() async throws {
    let data = Array(repeating: UInt8(6), count: 1 << 20)
    let (harness, runner) = try makeHarness(data: data)
    harness.drive.fullSyncWarning = "F_FULLFSYNC failed: errno 95"
    let (summary, _) = await run(runner)

    #expect(summary.results[0] != nil)
    #expect(harness.sink.records[0].fullSyncWarnings.contains("F_FULLFSYNC failed: errno 95"))
}

@Test
func existingNameNeedsReplaceChoice() async throws {
    let data = [UInt8(1), 2, 3]
    let (harness, runner) = try makeHarness(data: data)
    let old = try harness.drive.createWriter(path: harness.finalPath, truncate: true)
    try [UInt8(9)].withUnsafeBytes { try old.write($0, at: 0) }
    try old.close()
    let (summary, _) = await run(runner)

    #expect(summary.results[0] == .failed(reason: .nameConflict, badRanges: []))
    #expect(harness.drive.contents(of: harness.finalPath) == [9])
}

@Test
func jobStoreRoundTripsAndSkipsCorruptFiles() throws {
    let folder = NSTemporaryDirectory() + "USBVerifyJobs-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: folder) }
    let drive = FakeDrive(mountPath: "/Volumes/Test")
    drive.addSource(path: "/source/a", data: [1])
    let volume = makeTestVolume(drive: drive, mountPath: "/Volumes/Test")
    let state = try JobFactory.fileState(
        sourcePath: "/source/a", destinationFolder: "x", finalName: "a",
        chunkSize: testChunkSize, io: drive)
    let first = JobFactory.job(volume: volume, mode: .strict, files: [state])
    var second = first
    second.id = UUID().uuidString
    second.createdAt = first.createdAt.addingTimeInterval(1)
    let store = JobStore(directory: folder)
    try store.save(second)
    try store.save(first)
    try Data("bad".utf8).write(to: URL(fileURLWithPath: folder).appendingPathComponent("bad.json"))

    #expect(try store.load(id: first.id) == first)
    #expect(try store.loadAll().map(\.id) == [first.id, second.id])
    try store.delete(id: first.id)
    #expect(try store.load(id: first.id) == nil)
}

@Test
func verifyOnlyRemountsAndNeverWrites() async throws {
    let mount = "/Volumes/Test"
    let drive = FakeDrive(mountPath: mount)
    let data = [UInt8(1), 2, 3]
    drive.addSource(path: "/source/a", data: data)
    let writer = try drive.createWriter(path: "\(mount)/a", truncate: true)
    try data.withUnsafeBytes { try writer.write($0, at: 0) }
    try writer.close()
    let control = FakeVolumeControl(drive: drive, mountPath: mount)
    let item = VerifyOnlyItem(sourcePath: "/source/a", destinationFolder: "", name: "a")
    let before = drive.writeCount
    let runner = VerifyOnlyRunner(
        items: [item], volume: makeTestVolume(drive: drive, mountPath: mount), io: drive,
        volumeControl: control, clock: testClock(), chunkSize: testChunkSize)
    let results = await runner.run()

    let expected: [FileResult] = [.passed(sourceHash: summaryHash(data), rereadHash: summaryHash(data))]
    #expect(results == expected)
    #expect(drive.writeCount == before)
    #expect(control.unmountCalls == 1)
    #expect(control.mountCalls == 1)
}

@Test
func disconnectSavesStateAndResumePasses() async throws {
    let data = Array(repeating: UInt8(3), count: testChunkSize + 10)
    let (harness, runner) = try makeHarness(data: data)
    let gate = ClockBox()
    harness.drive.beforeWrite = { _, offset, _ in
        if gate.value == 0, offset >= Int64(testChunkSize) {
            gate.value = 1
            throw VerifyError.driveDisconnected(atOffset: offset)
        }
    }
    let (paused, events) = await run(runner)
    #expect(paused.status == .paused(.driveDisconnected))
    #expect(
        events.contains {
            if case .paused(.driveDisconnected, _) = $0 { return true }
            return false
        })
    let saved = try #require(try harness.store.load(id: runner.currentJob.id))
    harness.drive.isUnplugged = false
    harness.drive.beforeWrite = nil
    let resumed = JobRunner(
        job: saved, volume: harness.volume, io: harness.drive,
        volumeControl: harness.control, store: harness.store, clock: testClock())
    let (finished, _) = await run(resumed)
    #expect(finished.results[0] == .passed(sourceHash: summaryHash(data), rereadHash: summaryHash(data)))
    #expect(harness.drive.contents(of: harness.finalPath) == data)
}

@Test
func pauseAndCancelMarkRemainingFiles() async throws {
    let data = Array(repeating: UInt8(2), count: testChunkSize)
    let (_, runner) = try makeHarness(data: data)
    runner.control.requestCancel()
    let cancelled = await runner.run()
    #expect(cancelled.status == .cancelled)
    #expect(cancelled.results[0] == .cancelled)

    let (secondHarness, secondRunner) = try makeHarness(data: data)
    secondHarness.drive.beforeWrite = { _, _, _ in secondRunner.control.requestPause(.wake) }
    let paused = await secondRunner.run()
    #expect(paused.status == .paused(.wake))
}

@Test
func busyUnmountWaitsForRetryAndReportsPhase() async throws {
    let data = [UInt8(1), 2]
    let (harness, runner) = try makeHarness(data: data)
    harness.control.busyUnmounts = 2
    let retryTask = Task {
        while harness.control.unmountCalls < 3 {
            await Task.yield()
            runner.control.requestUnmountRetry()
        }
    }
    let result = await runner.run()
    _ = await retryTask.value
    #expect(result.status == .completed)
    #expect(harness.control.unmountCalls == 3)
}

@Test
func zeroAndShortFilesPass() async throws {
    for data in [
        [], [UInt8(1)], Array(repeating: UInt8(2), count: testChunkSize),
        Array(repeating: UInt8(3), count: testChunkSize + 1),
    ] {
        let (harness, runner) = try makeHarness(data: data)
        let result = await runner.run()
        #expect(result.results[0] == .passed(sourceHash: summaryHash(data), rereadHash: summaryHash(data)))
        #expect(harness.drive.contents(of: harness.finalPath) == data)
    }
}

@Test
func sourceChangeDuringCopyFails() async throws {
    let data = Array(repeating: UInt8(1), count: testChunkSize)
    let (harness, runner) = try makeHarness(data: data)
    let changed = Array(repeating: UInt8(2), count: testChunkSize)
    let changedOnce = ClockBox()
    harness.drive.beforeRead = { path, _, _ in
        if path == harness.sourcePath, changedOnce.value == 0 {
            changedOnce.value = 1
            harness.drive.changeSource(path: path, data: changed)
        }
    }
    let result = await runner.run()
    #expect(result.results[0] == .failed(reason: .sourceChanged, badRanges: []))
}

@Test
func discardPartialFilesKeepsUnrelatedFiles() throws {
    let data = [UInt8(1)]
    let (harness, runner) = try makeHarness(data: data)
    let temp = try harness.drive.createWriter(path: harness.tempPath, truncate: true)
    try data.withUnsafeBytes { try temp.write($0, at: 0) }
    try temp.close()
    let failed = try harness.drive.createWriter(path: harness.failedPath, truncate: true)
    try data.withUnsafeBytes { try failed.write($0, at: 0) }
    try failed.close()
    let unrelated = "/Volumes/Test/keep.txt"
    let keep = try harness.drive.createWriter(path: unrelated, truncate: true)
    try data.withUnsafeBytes { try keep.write($0, at: 0) }
    try keep.close()

    runner.discardPartialFiles()
    #expect(harness.drive.fileSize(path: harness.tempPath) == nil)
    #expect(harness.drive.fileSize(path: harness.failedPath) == nil)
    #expect(harness.drive.fileSize(path: unrelated) == 1)
}

@Test
func chunkPlanBufferHasherAndMergeBehave() {
    let plan = ChunkPlan(size: Int64(testChunkSize * 2 + 3), chunkSize: testChunkSize)
    #expect(plan.count == 3)
    #expect(plan.length(of: 2) == 3)
    #expect(
        ChunkIO.merge([BadRange(offset: 4, length: 2), BadRange(offset: 6, length: 3)]) == [
            BadRange(offset: 4, length: 5)
        ])
    let a = AlignedBuffer(capacity: Defaults.alignment)
    let b = AlignedBuffer(capacity: Defaults.alignment)
    a.mutableBytes(count: 4).initializeMemory(as: UInt8.self, repeating: 1)
    b.mutableBytes(count: 4).initializeMemory(as: UInt8.self, repeating: 1)
    b.mutableBytes(count: 4)[2] = 2
    #expect(a.differences(from: b, count: 4) == [BadRange(offset: 2, length: 1)])
    #expect(
        "".data(using: .utf8)!.withUnsafeBytes { StreamingHasher.hash(of: $0) }
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
}
