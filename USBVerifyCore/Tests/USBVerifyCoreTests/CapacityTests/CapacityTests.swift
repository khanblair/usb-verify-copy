import Foundation
import Testing

@testable import USBVerifyCore

private final class CapacityFakeVolumeControl: VolumeControl, @unchecked Sendable {
    let drive: FakeDrive
    var busyUnmounts = 0
    var unmountCount = 0
    var mountCount = 0

    init(drive: FakeDrive) {
        self.drive = drive
    }

    func unmount(volume: VolumeID) async throws {
        unmountCount += 1
        if drive.isUnplugged {
            throw VerifyError.volumeNotFound(volumeID: volume.uuid)
        }
        if busyUnmounts > 0 {
            busyUnmounts -= 1
            throw VerifyError.unmountBusy(blockers: ["test"])
        }
    }

    func mount(volume: VolumeID) async throws -> String {
        mountCount += 1
        if drive.isUnplugged {
            throw VerifyError.volumeNotFound(volumeID: volume.uuid)
        }
        drive.dropCaches()
        return "/Volumes/Capacity"
    }

    func mountPath(of volume: VolumeID) async -> String? {
        drive.isUnplugged ? nil : "/Volumes/Capacity"
    }

    func eject(volume: VolumeID) async throws {}

    func eraseExFATWithMBR(
        wholeDisk: String, label: String,
        privilege: ErasePrivilege
    ) async throws -> String {
        ""
    }
}

private actor CapacityRunSink: RunSink {
    private(set) var records: [RunRecord] = []

    func record(_ run: RunRecord) async {
        records.append(run)
    }
}

private final class LockedPaths: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
}

private func capacityVolume() -> Volume {
    Volume(
        id: VolumeID("capacity-test"), name: "Capacity", mountPath: "/Volumes/Capacity",
        bsdName: "disk9s1", wholeDiskBSDName: "disk9", protocolName: "Fake",
        filesystem: .exfat, totalBytes: 10 * 1024 * 1024, freeBytes: 10 * 1024 * 1024)
}

private func capacityConfig(seed: UInt64 = 7) -> CapacityConfig {
    CapacityConfig(testFileSize: 1024 * 1024, reserveBytes: 1024 * 1024, seed: seed)
}

private func makeDrive(physicalCapacityBytes: Int64? = nil) -> FakeDrive {
    FakeDrive(
        mountPath: "/Volumes/Capacity", capacityBytes: 10 * 1024 * 1024,
        physicalCapacityBytes: physicalCapacityBytes)
}

private func makeRunner(
    drive: FakeDrive,
    config: CapacityConfig = capacityConfig(),
    control: CapacityFakeVolumeControl? = nil,
    manifestPath: String? = nil,
    sink: (any RunSink)? = nil,
    clock: EngineClock = EngineClock(now: { 0 }, sleep: { _ in })
) -> CapacityRunner {
    CapacityRunner(
        volume: capacityVolume(), config: config, io: drive,
        volumeControl: control ?? CapacityFakeVolumeControl(drive: drive),
        manifestPath: manifestPath, sink: sink, clock: clock)
}

private func writeFile(_ path: String, data: [UInt8], on drive: FakeDrive) throws {
    let writer = try drive.createWriter(path: path, truncate: true)
    defer { try? writer.close() }
    try data.withUnsafeBytes { bytes in
        try writer.write(bytes, at: 0)
    }
}

private func uniqueTemporaryPath() throws -> String {
    let path = (NSTemporaryDirectory() as NSString).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

@Test func capacityPatternIsDeterministicAndVariesBySeedFileAndOffset() {
    let first = AlignedBuffer(capacity: 32)
    let same = AlignedBuffer(capacity: 32)
    let differentSeed = AlignedBuffer(capacity: 32)
    let differentFile = AlignedBuffer(capacity: 32)
    let differentOffset = AlignedBuffer(capacity: 32)
    CapacityPattern.fill(first.mutableBytes, seed: 7, fileIndex: 0, offset: 0)
    CapacityPattern.fill(same.mutableBytes, seed: 7, fileIndex: 0, offset: 0)
    CapacityPattern.fill(differentSeed.mutableBytes, seed: 8, fileIndex: 0, offset: 0)
    CapacityPattern.fill(differentFile.mutableBytes, seed: 7, fileIndex: 1, offset: 0)
    CapacityPattern.fill(differentOffset.mutableBytes, seed: 7, fileIndex: 0, offset: 8)
    #expect(first.equals(same, count: 32))
    #expect(!first.equals(differentSeed, count: 32))
    #expect(!first.equals(differentFile, count: 32))
    #expect(!first.equals(differentOffset, count: 32))
}

@Test func genuineDriveCleansFilesPreservesUsersAndRemountsOnce() async throws {
    let drive = makeDrive()
    let userPath = "/Volumes/Capacity/user.bin"
    let userData = Array(repeating: UInt8(0xA5), count: 128)
    try writeFile(userPath, data: userData, on: drive)
    let control = CapacityFakeVolumeControl(drive: drive)
    let report = await makeRunner(drive: drive, control: control).run()
    #expect(report.verdict == .genuine)
    #expect(report.goodFiles == 9)
    #expect(drive.contents(of: userPath) == userData)
    #expect(drive.listFiles() == [userPath])
    #expect(control.unmountCount == 1)
    #expect(control.mountCount == 1)
}

@Test func busyUnmountEmitsWaitingEventAndRetries() async {
    let drive = makeDrive()
    let control = CapacityFakeVolumeControl(drive: drive)
    control.busyUnmounts = 2
    let runner = makeRunner(drive: drive, control: control)
    let observer = Task {
        for await event in runner.events {
            if case .waitingForUnmount = event {
                runner.control.requestUnmountRetry()
            }
        }
    }
    let report = await runner.run()
    observer.cancel()
    #expect(report.verdict == .genuine)
    #expect(control.unmountCount == 3)
}

@Test func wrapAroundReportsExactDamagedAreaInAnEarlyFile() async {
    let drive = makeDrive(physicalCapacityBytes: 3 * 1024 * 1024)
    drive.servesReadsFromCache = true
    let report = await makeRunner(drive: drive).run()
    let first = report.badFiles.first
    #expect(report.verdict == .fakeCapacitySuspected)
    #expect(first?.name == "usbverify-test-0000.bin")
    #expect(first?.badRanges.count == 256)
    #expect(first?.badRanges.allSatisfy { $0.length == 1 && $0.offset.isMultiple(of: 4096) } == true)
    #expect(drive.listFiles().isEmpty)
}

@Test func writeFaultInLastFileIsFailing() async {
    let drive = makeDrive()
    drive.beforeWrite = { path, _, _ in
        if path.hasSuffix("usbverify-test-0008.bin") {
            drive.flipByteOnWrite(fileOffset: 0, times: 1)
        }
    }
    let report = await makeRunner(drive: drive).run()
    #expect(report.verdict == .failing)
    #expect(report.badFiles.last?.name == "usbverify-test-0008.bin")
}

@Test func cancelDuringWritingIsInconclusiveAndCleansFiles() async {
    let drive = makeDrive()
    let runner = makeRunner(drive: drive)
    drive.beforeWrite = { _, _, _ in
        runner.control.requestCancel()
    }
    let report = await runner.run()
    #expect(report.verdict == .inconclusive)
    #expect(drive.listFiles().isEmpty)
}

@Test func disconnectKeepsManifestAndFilesUntilCleanup() async throws {
    let drive = makeDrive()
    let tempPath = try uniqueTemporaryPath()
    defer { try? FileManager.default.removeItem(atPath: tempPath) }
    let manifestPath = (tempPath as NSString).appendingPathComponent("manifest.json")
    let runner = makeRunner(drive: drive, manifestPath: manifestPath)
    drive.beforeWrite = { _, _, _ in
        drive.isUnplugged = true
    }
    let report = await runner.run()
    #expect(report.verdict == .inconclusive)
    #expect(FileManager.default.fileExists(atPath: manifestPath))
    #expect(!drive.listFiles().isEmpty)
    drive.isUnplugged = false
    await runner.cleanup()
    #expect(drive.listFiles().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: manifestPath))
}

@Test func cleanupOnlyDeletesSafeManifestNames() async throws {
    let drive = makeDrive()
    let tempPath = try uniqueTemporaryPath()
    defer { try? FileManager.default.removeItem(atPath: tempPath) }
    let manifestPath = (tempPath as NSString).appendingPathComponent("manifest.json")
    try writeFile("/Volumes/Capacity/important.txt", data: [1], on: drive)
    try writeFile("/Volumes/Capacity/usbverify-test-0001.txt", data: [2], on: drive)
    let json =
        "{\"names\":[\"important.txt\",\"usbverify-test-0001.txt\"],\"sizes\":[1,1],\"seed\":7,\"volumeID\":\"capacity-test\"}"
    try Data(json.utf8).write(to: URL(fileURLWithPath: manifestPath))
    await makeRunner(drive: drive, manifestPath: manifestPath).cleanup()
    #expect(drive.contents(of: "/Volumes/Capacity/important.txt") == [1])
    #expect(drive.contents(of: "/Volumes/Capacity/usbverify-test-0001.txt") == [2])
}

@Test func insufficientReserveWritesNothing() async {
    let drive = FakeDrive(mountPath: "/Volumes/Capacity", capacityBytes: 512 * 1024)
    let report = await makeRunner(drive: drive).run()
    #expect(report.verdict == .inconclusive)
    #expect(drive.listFiles().isEmpty)
}

@Test func capacityRunReachesSinkWithResultText() async {
    let drive = makeDrive()
    let sink = CapacityRunSink()
    let report = await makeRunner(drive: drive, sink: sink).run()
    let records = await sink.records
    #expect(records.count == 1)
    #expect(records.first?.kind == .capacityTest)
    #expect(records.first?.result == report.verdict.rawValue)
    #expect(!(records.first?.result.isEmpty ?? true))
}

@Test func capacityNeverReadsExistingUserFiles() async throws {
    let drive = makeDrive()
    let userPath = "/Volumes/Capacity/user.bin"
    try writeFile(userPath, data: [1, 2, 3], on: drive)
    let paths = LockedPaths()
    drive.beforeRead = { path, _, _ in
        paths.append(path)
    }
    let report = await makeRunner(drive: drive).run()
    #expect(report.verdict == .genuine)
    #expect(!paths.values.contains(userPath))
}
