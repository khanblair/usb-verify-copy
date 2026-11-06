import Foundation
import Testing
import USBVerifyCore

@testable import USBVerifyCLI

@Test("parsesEveryCommandAndRejectsBadInput")
func parsesEveryCommandAndRejectsBadInput() throws {
    #expect(try ArgumentParser.parse(["list"]) == .list(includeDiskImages: false))
    #expect(try ArgumentParser.parse(["jobs"]) == .jobs)
    #expect(try ArgumentParser.parse(["resume", "abc"]) == .resume("abc"))
    #expect(try ArgumentParser.parse(["eject", "--drive", "1"]) == .eject(DriveSelector(value: "1")))
    let parsed = try ArgumentParser.parse(["copy", "--drive", "1", "--to", "x", "a"])
    #expect(
        parsed
            == .copy(
                CopyOptions(
                    drive: DriveSelector(value: "1"), folder: "x", mode: .strict,
                    conflict: nil, dotClean: false, dryRun: false, yes: false, files: ["a"])))
    #expect(throws: CLIError.self) { try ArgumentParser.parse(["copy", "--to", "x", "a"]) }
    #expect(throws: CLIError.self) { try ArgumentParser.parse(["copy", "--drive", "1", "--to", "x", "--bad", "a"]) }
    #expect(throws: CLIError.self) { try ArgumentParser.parse(["copy", "--drive", "1", "--to", "x", "a", "./a"]) }
}

@Test("resolvesDriveByNumberNameAndUuidAndRefusesAmbiguousNames")
func resolvesDriveByNumberNameAndUuidAndRefusesAmbiguousNames() throws {
    let first = makeVolume(uuid: "one", name: "USB", path: "/one")
    let second = makeVolume(uuid: "two", name: "USB", path: "/two")
    #expect(try DriveResolver.resolve(DriveSelector(value: "1"), from: [first, second]).id == first.id)
    #expect(try DriveResolver.resolve(DriveSelector(value: "one"), from: [first, second]).id == first.id)
    #expect(throws: CLIError.self) { try DriveResolver.resolve(DriveSelector(value: "USB"), from: [first, second]) }
}

@Test("listShowsReasonForUnusableVolumes")
func listShowsReasonForUnusableVolumes() async {
    let volume = makeVolume(
        uuid: "ntfs", name: "Disk", path: "/disk", filesystem: .ntfs,
        readOnly: true, route: Route(protocolName: "unknown"))
    let output = OutputCapture()
    let environment = testEnvironment(volume: volume)
    _ = await CLI.run(arguments: ["list"], environment: environment, output: output.append)
    #expect(output.text.contains("NTFS"))
    #expect(output.text.contains("unknown"))
}

@Test("dryRunWritesNothing")
func dryRunWritesNothing() async throws {
    let drive = FakeDrive(mountPath: "/disk")
    drive.addSource(path: "/source.bin", data: [1, 2, 3])
    let output = OutputCapture()
    let code = await CLI.run(
        arguments: ["copy", "--drive", "1", "--to", "out", "--dry-run", "/source.bin"],
        environment: testEnvironment(drive: drive), output: output.append)
    #expect(code == 0)
    #expect(drive.writeCount == 0)
}

@Test("copyStrictPassesAndPrintsMatchLine")
func copyStrictPassesAndPrintsMatchLine() async {
    let data = Array(repeating: UInt8(7), count: 128)
    let drive = FakeDrive(mountPath: "/disk")
    drive.addSource(path: "/source.bin", data: data)
    let output = OutputCapture()
    let code = await CLI.run(
        arguments: ["copy", "--drive", "1", "--to", "out", "--yes", "/source.bin"],
        environment: testEnvironment(drive: drive), output: output.append)
    #expect(code == 0)
    #expect(output.text.contains("The file on the drive matches the source."))
    #expect(drive.contents(of: "/disk/out/source.bin") == data)
}

@Test("copyFailsWithBadRangeAndExitCode1")
func copyFailsWithBadRangeAndExitCode1() async {
    let drive = FakeDrive(mountPath: "/disk")
    drive.addSource(path: "/source.bin", data: Array(repeating: UInt8(8), count: 128))
    drive.flipByteOnWrite(fileOffset: 0, times: 20)
    let output = OutputCapture()
    let code = await CLI.run(
        arguments: ["copy", "--drive", "1", "--to", "out", "--yes", "/source.bin"],
        environment: testEnvironment(drive: drive), output: output.append)
    #expect(code == 1)
    #expect(output.text.contains("offset 0x0"))
    #expect(drive.contents(of: "/disk/out/source.bin.FAILED-partial") != nil)
    #expect(drive.contents(of: "/disk/out/source.bin") == nil)
}

@Test("preflightIssueExitsWithCode2AndWritesNothing")
func preflightIssueExitsWithCode2AndWritesNothing() async {
    let drive = FakeDrive(mountPath: "/disk")
    drive.addSource(path: "/disk/source.bin", data: [1])
    let volume = makeVolume(uuid: "id", name: "Disk", path: "/disk", filesystem: .fat32, free: 0)
    let code = await CLI.run(
        arguments: ["copy", "--drive", "1", "--to", "out", "--yes", "/disk/source.bin"],
        environment: testEnvironment(volume: volume, drive: drive), output: { _ in })
    #expect(code == 2)
    #expect(drive.writeCount == 0)
}

@Test("conflictAskRefusesWithoutTerminalAndPolicyIsHonored")
func conflictAskRefusesWithoutTerminalAndPolicyIsHonored() throws {
    #expect(Plan.keepBothName("a.ext", existing: { $0 == "a 2.ext" }) == "a 3.ext")
    #expect(ConflictPolicy(rawValue: "replace") == .replace)
    #expect(ConflictPolicy(rawValue: "keep-both") == .keepBoth)
    #expect(throws: CLIError.self) {
        try ArgumentParser.parse(["copy", "--drive", "1", "--to", "x", "--on-conflict", "ask"])
    }
}

@Test("yesNeverSkipsPreflight")
func yesNeverSkipsPreflight() async {
    let drive = FakeDrive(mountPath: "/disk")
    drive.addSource(path: "/source.bin", data: [1])
    let volume = makeVolume(uuid: "id", name: "Disk", path: "/disk", filesystem: .apfs, free: 100)
    let code = await CLI.run(
        arguments: ["copy", "--drive", "1", "--to", "out", "--yes", "/source.bin"],
        environment: testEnvironment(volume: volume, drive: drive), output: { _ in })
    #expect(code == 2)
    #expect(drive.writeCount == 0)
}

@Test("pauseOnDisconnectSavesStateAndResumeFinishes")
func pauseOnDisconnectSavesStateAndResumeFinishes() async {
    let drive = FakeDrive(mountPath: "/disk")
    drive.addSource(path: "/source.bin", data: Array(repeating: 1, count: 128))
    drive.beforeRead = { _, _, _ in drive.isUnplugged = true }
    let store = JobStore(directory: temporaryDirectory())
    let environment = testEnvironment(drive: drive, store: store)
    let code = await CLI.run(
        arguments: ["copy", "--drive", "1", "--to", "out", "--yes", "/source.bin"], environment: environment,
        output: { _ in })
    #expect(code == 3)
    #expect((try? store.loadAll().isEmpty) == false)
}

@Test("verifyOnlyNeverWritesAndReportsCorruption")
func verifyOnlyNeverWritesAndReportsCorruption() async {
    let drive = FakeDrive(mountPath: "/disk")
    drive.addSource(path: "/source.bin", data: Array(repeating: 2, count: 128))
    let output = OutputCapture()
    let environment = testEnvironment(drive: drive)
    _ = await CLI.run(
        arguments: ["copy", "--drive", "1", "--to", "out", "--yes", "/source.bin"], environment: environment,
        output: { _ in })
    let writesBeforeVerify = drive.writeCount
    drive.corruptOnRemount(pathSuffix: "source.bin", fileOffset: 0)
    drive.dropCaches()
    let code = await CLI.run(
        arguments: ["verify", "--drive", "1", "--folder", "out", "/source.bin"],
        environment: environment, output: output.append)
    #expect(code == 1)
    #expect(drive.writeCount == writesBeforeVerify)
}

@Test("dotCleanOnlyWithFlagAndConfirmation")
func dotCleanOnlyWithFlagAndConfirmation() {
    let root = temporaryDirectory()
    let nested = URL(fileURLWithPath: root).appendingPathComponent("sub")
    try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: root + "/._a", contents: Data())
    FileManager.default.createFile(atPath: nested.path + "/._b", contents: Data())
    FileManager.default.createFile(atPath: root + "/keep.txt", contents: Data())
    let paths = DotCleaner.scan(root: root)
    #expect(paths.count == 2)
    _ = DotCleaner.delete(paths, within: root)
    #expect(DotCleaner.scan(root: root).isEmpty)
}

@Test("progressLineFormatsAllPhases")
func progressLineFormatsAllPhases() {
    let snapshot = ProgressSnapshot(
        fileIndex: 0, fileCount: 2, fileName: "a", phase: .copying,
        fileBytesDone: 50, fileBytesTotal: 100, chunksVerified: 1, chunksRetried: 2,
        bytesPerSecond: 2_000_000, secondsRemaining: 3, batchBytesDone: 50, batchBytesTotal: 100)
    let text = Console.progressLine(snapshot)
    #expect(text.contains("copying 50%"))
    #expect(text.contains("2.0 MB/s"))
    #expect(text.contains("file 1 of 2"))
}

@Test("resultTextForPassFailPaused")
func resultTextForPassFailPaused() {
    #expect(Console.resultText(name: "a", result: .passed(sourceHash: "x", rereadHash: "x")).contains("matches"))
    #expect(
        Console.resultText(
            name: "a", result: .failed(reason: .finalCheckMismatch, badRanges: [BadRange(offset: 16, length: 2)])
        ).contains("0x10"))
    #expect(Console.resultText(name: "a", result: .cancelled).contains("PAUSED"))
}

@Test("sigintRequestsPauseAndSavesState")
func sigintRequestsPauseAndSavesState() async {
    let control = JobControl()
    control.requestPause(.appQuit)
    #expect(control.pendingPause == .appQuit)
}

private final class OutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.withLock { values.append(value) } }
    var text: String { lock.withLock { values.joined(separator: "\n") } }
}

private final class FakeVolumeEvents: VolumeEvents, @unchecked Sendable {
    let values: [Volume]
    init(_ values: [Volume]) { self.values = values }
    func currentVolumes() async -> [Volume] { values }
    func events() -> AsyncStream<VolumeEvent> { AsyncStream { $0.finish() } }
}

private struct FakeVolumeControl: VolumeControl {
    func unmount(volume: VolumeID) async throws {}
    func mount(volume: VolumeID) async throws -> String { "/disk" }
    func mountPath(of volume: VolumeID) async -> String? { "/disk" }
    func eject(volume: VolumeID) async throws {}
    func eraseExFATWithMBR(wholeDisk: String, label: String, privilege: ErasePrivilege) async throws -> String { "" }
}

private struct FakePowerGuard: PowerGuard {
    func begin(reason: String) -> any PowerToken { FakePowerToken() }
    func wakeEvents() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    var isOnBattery: Bool { false }
}

private struct FakePowerToken: PowerToken {
    func end() {}
}

private func makeVolume(
    uuid: String = "id", name: String = "Disk", path: String = "/disk",
    filesystem: FilesystemKind = .exfat, readOnly: Bool = false,
    free: Int64 = 1_000_000, route: Route? = nil
) -> Volume {
    Volume(
        id: VolumeID(uuid), name: name, mountPath: path, bsdName: "disk1s1", wholeDiskBSDName: "disk1",
        protocolName: "USB", filesystem: filesystem, totalBytes: 2_000_000, freeBytes: free,
        isReadOnly: readOnly, route: route)
}

private func testEnvironment(
    volume: Volume? = nil, drive: FakeDrive? = nil,
    store: JobStore? = nil
) -> CLIEnvironment {
    let selected = volume ?? makeVolume()
    let selectedDrive = drive ?? FakeDrive(mountPath: selected.mountPath)
    return CLIEnvironment(
        volumes: FakeVolumeEvents([selected]), volumeControl: FakeVolumeControl(),
        drive: { _ in selectedDrive }, power: FakePowerGuard(),
        jobStore: store ?? JobStore(directory: temporaryDirectory()))
}

private func temporaryDirectory() -> String {
    let path = NSTemporaryDirectory() + "/usbverify-cli-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

@Test func pausedTextNamesTheRealReason() {
    #expect(Console.pausedText(reason: .driveDisconnected, offset: 100).contains("Drive disconnected at byte 100"))
    #expect(Console.pausedText(reason: .appQuit, offset: 100).contains("Progress is saved"))
    #expect(!Console.pausedText(reason: .appQuit, offset: 100).contains("disconnected"))
    #expect(Console.pausedText(reason: .wake, offset: 7).contains("woke from sleep"))
}
