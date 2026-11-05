import Darwin
import Foundation
import Testing
import USBVerifySystem

@testable import USBVerifyCore

@Suite("RAM disk integration", .serialized)
struct RamDiskIntegrationTests {
    @Test("strict copy uses the real exFAT volume")
    func strictCopyPasses() async throws {
        guard let fixture = try await RAMDiskFixture.openOrSkip() else { return }
        defer { fixture.remove() }
        let source = try fixture.makeSource()
        let run = try await fixture.copy(source: source, mode: .strict)

        #expect(run.summary.status == .completed)
        #expect(run.summary.results == [.passed(sourceHash: run.sourceHash, rereadHash: run.sourceHash)])
        #expect(run.sink.records.last?.result == "PASS")
        #expect(FileManager.default.fileExists(atPath: run.tempPath) == false)
        #expect(try SHA256File.hash(path: run.finalPath) == run.sourceHash)
    }

    @Test("quick copy passes and removes its part file")
    func quickCopyPasses() async throws {
        guard let fixture = try await RAMDiskFixture.openOrSkip() else { return }
        defer { fixture.remove() }
        let source = try fixture.makeSource()
        let run = try await fixture.copy(source: source, mode: .quick)

        #expect(run.summary.status == .completed)
        #expect(run.summary.results == [.passed(sourceHash: run.sourceHash, rereadHash: run.sourceHash)])
        #expect(run.sink.records.last?.result == "PASS")
        #expect(FileManager.default.fileExists(atPath: run.tempPath) == false)
    }

    @Test("raw-device damage is found after remount")
    func rawDeviceDamageFailsVerifyOnly() async throws {
        guard let fixture = try await RAMDiskFixture.openOrSkip() else { return }
        defer { fixture.remove() }
        let source = try fixture.makeSource()
        let run = try await fixture.copy(source: source, mode: .quick)
        let damage = try fixture.flipUniquePatternByte(source: source)
        let clock = ContinuousClock()
        let started = clock.now
        let result = try await fixture.verify(source: source, destinationName: run.name)
        let elapsed = started.duration(to: clock.now)
        let seconds =
            elapsed.components.attoseconds == 0
            ? Double(elapsed.components.seconds)
            : Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let speed = Double(fixture.sourceSize) / max(seconds, 0.000_001) / 1_000_000
        print("RAM disk F_NOCACHE verify speed: \(speed) MB/s")

        guard case .failed(let reason, let ranges) = result else {
            Issue.record("Expected VerifyOnlyRunner to fail after raw-device damage")
            return
        }
        #expect(reason == .finalCheckMismatch)
        #expect(ranges == [BadRange(offset: damage.fileOffset, length: 1)])
    }

    @Test("remount makes raw damage visible to F_NOCACHE reads")
    func remountDropsThePlainReadCache() async throws {
        guard let fixture = try await RAMDiskFixture.openOrSkip() else { return }
        defer { fixture.remove() }
        let source = try fixture.makeSource()
        let run = try await fixture.copy(source: source, mode: .quick)
        let before = try Data(contentsOf: URL(fileURLWithPath: run.finalPath))
        let damage = try fixture.flipUniquePatternByte(source: source)
        let plainAfterDamage = try Data(contentsOf: URL(fileURLWithPath: run.finalPath))
        try await fixture.control.unmount(volume: fixture.volume.id)
        let mountedPath = try await fixture.control.mount(volume: fixture.volume.id)
        fixture.volume.mountPath = mountedPath
        let reader = try fixture.io.openReader(path: run.finalPath)
        defer { reader.close() }
        let afterRemount = try reader.readExactly(at: damage.destinationOffset, count: 1)

        let fileOffset = Int(damage.fileOffset)
        print(
            "RAM disk plain read before damage byte: \(before[fileOffset]); after damage before remount: \(plainAfterDamage[fileOffset]); after remount F_NOCACHE: \(afterRemount[0])"
        )
        #expect(afterRemount[0] != before[fileOffset])
    }

    @Test("mount returns the real path after remount")
    func remountReturnsMountPath() async throws {
        guard let fixture = try await RAMDiskFixture.openOrSkip() else { return }
        defer { fixture.remove() }
        let oldPath = fixture.volume.mountPath
        try await fixture.control.unmount(volume: fixture.volume.id)
        let newPath = try await fixture.control.mount(volume: fixture.volume.id)

        #expect(newPath == fixture.volume.mountPath || newPath.hasPrefix("/Volumes/"))
        print("RAM disk mount path before remount: \(oldPath); after remount: \(newPath)")
    }

    @Test("pause and resume finishes the real copy")
    func pauseAndResumePasses() async throws {
        guard let fixture = try await RAMDiskFixture.openOrSkip() else { return }
        defer { fixture.remove() }
        let source = try fixture.makeSource()
        var job = try fixture.makeJob(source: source, mode: .strict)
        let store = JobStore(directory: fixture.temporaryDirectory.appendingPathComponent("jobs").path)
        let first = JobRunner(
            job: job, volume: fixture.volume, io: fixture.io, volumeControl: fixture.control, store: store)
        let firstTask = Task { await first.run() }
        for await event in first.events {
            if case .progress(let progress) = event, progress.chunksVerified >= 3 {
                first.control.requestPause(.appQuit)
                break
            }
        }
        let paused = await firstTask.value
        #expect(paused.status == .paused(.appQuit))

        job = paused.job
        let resumed = JobRunner(
            job: job, volume: fixture.volume, io: fixture.io, volumeControl: fixture.control, store: store)
        let summary = await resumed.run()
        #expect(summary.status == .completed)
        #expect(
            summary.results.allSatisfy {
                if case .passed = $0 { return true }
                return false
            })
    }

    @Test("preflight refuses a file larger than available space")
    func diskFullIsRefusedBeforeWriting() async throws {
        guard let fixture = try await RAMDiskFixture.openOrSkip() else { return }
        defer { fixture.remove() }
        let source = try fixture.makeSource(size: 8192)
        let file = PreflightFile(
            sourcePath: source.path, size: fixture.volume.freeBytes + 1, destinationName: "too-large.bin")
        let report = Preflight.check(volume: fixture.volume, files: [file])

        #expect(
            report.issues.contains {
                if case .noSpace = $0.error { return true }
                return false
            })
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.volume.mountPath)
        #expect(!names.contains("too-large.bin"))
        #expect(!names.contains("too-large.bin" + Defaults.tempSuffix))
    }

    @Test("capacity runner reports genuine and cleans its files")
    func capacityTestPassesAndCleansUp() async throws {
        guard let fixture = try await RAMDiskFixture.openOrSkip() else { return }
        defer { fixture.remove() }
        let userPath = URL(fileURLWithPath: fixture.volume.mountPath).appendingPathComponent("user.bin").path
        try Data([1, 2, 3]).write(to: URL(fileURLWithPath: userPath))
        let runner = CapacityRunner(
            volume: fixture.volume,
            config: CapacityConfig(folder: "", testFileSize: 8 * 1024 * 1024, reserveBytes: 32 * 1024 * 1024),
            io: fixture.io,
            volumeControl: fixture.control)
        let report = await runner.run()

        #expect(report.verdict == .genuine)
        #expect(report.badFiles.isEmpty)
        #expect(try Data(contentsOf: URL(fileURLWithPath: userPath)) == Data([1, 2, 3]))
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.volume.mountPath)
        #expect(names.allSatisfy { !$0.hasPrefix(Defaults.capacityTestPrefix) })
    }

    @Test("busy unmount reports blockers and succeeds after close")
    func busyUnmountIsTyped() async throws {
        guard let fixture = try await RAMDiskFixture.openOrSkip() else { return }
        defer { fixture.remove() }
        let path = URL(fileURLWithPath: fixture.volume.mountPath).appendingPathComponent("busy.bin").path
        FileManager.default.createFile(atPath: path, contents: Data([7]))
        var fd = Darwin.open(path, O_RDONLY)
        #expect(fd >= 0)
        guard fd >= 0 else { return }
        defer {
            if fd >= 0 {
                _ = Darwin.close(fd)
            }
        }

        do {
            try await fixture.control.unmount(volume: fixture.volume.id)
            Issue.record("Unmount unexpectedly succeeded while a file descriptor was open")
        } catch let error as VerifyError {
            guard case .unmountBusy(let blockers) = error else {
                Issue.record("Expected unmountBusy, got \(error)")
                return
            }
            print("RAM disk unmount blockers: \(blockers)")
        }
        _ = Darwin.close(fd)
        fd = -1
        try await fixture.control.unmount(volume: fixture.volume.id)
        _ = try await fixture.control.mount(volume: fixture.volume.id)
    }
}

private final class RAMDiskFixture: @unchecked Sendable {
    let temporaryDirectory: URL
    let io = PosixDriveIO()
    let control: DiskutilVolumeControl
    var volume: Volume
    let device: String
    let sourceSize: Int64 = 24 * 1024 * 1024
    private var created = true

    private init(device: String, volume: Volume, temporaryDirectory: URL) {
        self.device = device
        self.volume = volume
        self.temporaryDirectory = temporaryDirectory
        self.control = DiskutilVolumeControl(lookup: { _ in volume })
    }

    static func openOrSkip() async throws -> RAMDiskFixture? {
        guard ProcessInfo.processInfo.environment["USBVERIFY_RUN_RAMDISK_TESTS"] == "1" else {
            print("RAM disk tests skipped. Set USBVERIFY_RUN_RAMDISK_TESTS=1 to run them.")
            return nil
        }
        let script = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("../Scripts/ramdisk-exfat.sh").standardizedFileURL
        let result = run("/bin/zsh", [script.path, "create", "128", "USBVTEST"])
        guard result.status == 0 else {
            if result.output.contains("state file already exists") {
                print("RAM disk tests skipped: the RAM disk state file already exists.")
            } else {
                print("RAM disk tests skipped: could not create the RAM disk.\n\(result.output)")
            }
            return nil
        }
        guard
            let device = result.output.split(separator: "\n").first(where: { $0.hasPrefix("DEVICE=") })
                .map({ String($0.dropFirst("DEVICE=".count)) })
        else {
            runRemove(script: script)
            print("RAM disk tests skipped: create returned no device.")
            return nil
        }
        do {
            let volume = try readVolume(device: device)
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("USBVerifyRAM-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return RAMDiskFixture(device: device, volume: volume, temporaryDirectory: directory)
        } catch {
            runRemove(script: script)
            throw error
        }
    }

    func remove() {
        guard created else { return }
        created = false
        let script = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("../Scripts/ramdisk-exfat.sh").standardizedFileURL
        Self.runRemove(script: script)
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func makeSource(size: Int64? = nil) throws -> SourceFixture {
        let count = Int(size ?? sourceSize)
        let path = temporaryDirectory.appendingPathComponent("source-" + UUID().uuidString + ".bin")
        var data = Data(repeating: 0, count: count)
        for index in data.indices {
            data[index] = UInt8(truncatingIfNeeded: index &* 31 &+ 17)
        }
        let patternOffset = min(8 * 1024 * 1024, max(0, count - 4096))
        for index in 0..<4096 {
            data[patternOffset + index] = UInt8(truncatingIfNeeded: 0xA5 &+ index &* 13)
        }
        try data.write(to: path)
        return SourceFixture(path: path.path, data: data, patternOffset: Int64(patternOffset))
    }

    func makeJob(source: SourceFixture, mode: VerifyMode) throws -> PersistedJob {
        let state = try JobFactory.fileState(
            sourcePath: source.path, destinationFolder: "", finalName: "copy.bin", chunkSize: 4 * 1024 * 1024, io: io)
        return JobFactory.job(volume: volume, mode: mode, files: [state])
    }

    func copy(source: SourceFixture, mode: VerifyMode) async throws -> CopyResult {
        let job = try makeJob(source: source, mode: mode)
        let sink = FakeRunSink()
        let runner = JobRunner(job: job, volume: volume, io: io, volumeControl: control, sink: sink)
        let summary = await runner.run()
        let name = job.files[0].finalName
        return CopyResult(
            summary: summary,
            sink: sink,
            sourceHash: try SHA256File.hash(path: source.path),
            name: name,
            finalPath: volume.mountPath + "/" + name,
            tempPath: volume.mountPath + "/" + name + Defaults.tempSuffix)
    }

    func verify(source: SourceFixture, destinationName: String) async throws -> FileResult {
        let item = VerifyOnlyItem(sourcePath: source.path, destinationFolder: "", name: destinationName)
        let runner = VerifyOnlyRunner(
            items: [item], volume: volume, io: io, volumeControl: control, chunkSize: 4 * 1024 * 1024)
        return try #require(await runner.run().first)
    }

    func flipUniquePatternByte(source: SourceFixture) throws -> Damage {
        // Safety: only ever write to the raw device of a virtual disk image (the RAM disk), never to real hardware.
        let info = try Self.diskutilInfo(path: device)
        guard info["VirtualOrPhysical"] as? String == "Virtual", info["BusProtocol"] as? String == "Disk Image",
            info["Internal"] as? Bool == false
        else { throw VerifyError.permissionDenied(path: device) }
        let rawPath = "/dev/r" + device.dropFirst(5)
        let fd = Darwin.open(rawPath, O_RDWR)
        guard fd >= 0 else { throw VerifyError.permissionDenied(path: rawPath) }
        defer { _ = Darwin.close(fd) }
        var expected = [UInt8](repeating: 0, count: 4096)
        for index in expected.indices {
            expected[index] = UInt8(truncatingIfNeeded: 0xA5 &+ index &* 13)
        }
        var offset: off_t = 0
        let end = off_t(volume.totalBytes)
        while offset + off_t(expected.count) <= end {
            var actual = [UInt8](repeating: 0, count: expected.count)
            let count = actual.withUnsafeMutableBytes { bytes in
                pread(fd, bytes.baseAddress, bytes.count, offset)
            }
            if count == expected.count {
                let matches = actual == expected
                if matches {
                    // A raw device only accepts whole, aligned sectors, so rewrite the 4096 bytes we just read.
                    var damaged = actual
                    damaged[0] ^= 0x01
                    let written = damaged.withUnsafeBytes { bytes in
                        pwrite(fd, bytes.baseAddress, bytes.count, offset)
                    }
                    guard written == damaged.count else {
                        throw VerifyError.io(operation: "pwrite", code: errno)
                    }
                    return Damage(fileOffset: source.patternOffset, destinationOffset: Int64(source.patternOffset))
                }
            }
            offset += 4096
        }
        throw VerifyError.io(operation: "scan raw device", code: ENOENT)
    }

    private static func readVolume(device: String) throws -> Volume {
        // The script formats the RAM disk without a partition map, so the volume is on the whole disk.
        let identifier = device.replacingOccurrences(of: "/dev/", with: "")
        let plist = try diskutilInfo(path: "/dev/" + identifier)
        guard let uuid = plist["VolumeUUID"] as? String,
            let name = plist["VolumeName"] as? String,
            let mountPath = plist["MountPoint"] as? String,
            let bsd = plist["DeviceIdentifier"] as? String,
            let whole = plist["ParentWholeDisk"] as? String,
            let filesystem = plist["FilesystemName"] as? String,
            let total = int64Value(plist["TotalSize"]),
            let free = int64Value(plist["FreeSpace"])
        else { throw VerifyError.io(operation: "parse RAM disk info", code: EINVAL) }
        #expect(filesystem.lowercased().contains("exfat"))
        return Volume(
            id: VolumeID(uuid), name: name, mountPath: mountPath, bsdName: bsd, wholeDiskBSDName: whole,
            model: plist["MediaName"] as? String, protocolName: plist["BusProtocol"] as? String ?? "Disk Image",
            filesystem: .exfat, totalBytes: total, freeBytes: free)
    }

    private static func diskutilInfo(path: String) throws -> [String: Any] {
        let result = run("/usr/sbin/diskutil", ["info", "-plist", path])
        guard result.status == 0 else {
            throw VerifyError.commandFailed(command: "diskutil info -plist \(path)", output: result.output)
        }
        guard
            let plist = try PropertyListSerialization.propertyList(from: Data(result.output.utf8), format: nil)
                as? [String: Any]
        else { throw VerifyError.io(operation: "parse diskutil plist", code: EINVAL) }
        return plist
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        return nil
    }

    private static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (1, error.localizedDescription) }
        // Read first, then wait: waiting first can deadlock when the output fills the pipe.
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    private static func runRemove(script: URL) {
        _ = run("/bin/zsh", [script.path, "remove"])
    }
}

private struct SourceFixture: Sendable {
    let path: String
    let data: Data
    let patternOffset: Int64
}

private struct Damage: Sendable {
    let fileOffset: Int64
    let destinationOffset: Int64
}

private struct CopyResult: Sendable {
    let summary: JobSummary
    let sink: FakeRunSink
    let sourceHash: String
    let name: String
    let finalPath: String
    let tempPath: String
}

private enum SHA256File {
    static func hash(path: String) throws -> String {
        let source = try PosixDriveIO().openSource(path: path)
        defer { source.close() }
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 4 * 1024 * 1024, alignment: Defaults.alignment)
        defer { buffer.deallocate() }
        var hasher = StreamingHasher()
        var offset: Int64 = 0
        while offset < source.identity.size {
            let count = try source.read(into: buffer, at: offset)
            guard count > 0 else { break }
            let bytes = UnsafeRawBufferPointer(start: buffer.baseAddress, count: count)
            hasher.update(bytes)
            offset += Int64(count)
        }
        return hasher.finalize()
    }
}

extension DestinationReader {
    fileprivate func readExactly(at offset: Int64, count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let read = try bytes.withUnsafeMutableBytes { buffer in
            try read(into: buffer, at: offset)
        }
        guard read == count else { throw VerifyError.io(operation: "read", code: EIO) }
        return bytes
    }
}
