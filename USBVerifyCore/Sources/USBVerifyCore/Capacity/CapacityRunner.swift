import Foundation

public struct CapacityConfig: Sendable {
    public var folder: String
    public var testFileSize: Int64
    public var reserveBytes: Int64
    public var seed: UInt64

    public init(
        folder: String = "", testFileSize: Int64 = 1 * 1024 * 1024 * 1024,
        reserveBytes: Int64 = 16 * 1024 * 1024, seed: UInt64 = 0x5EED_C0DE
    ) {
        self.folder = folder
        self.testFileSize = testFileSize
        self.reserveBytes = reserveBytes
        self.seed = seed
    }
}

public enum CapacityVerdict: String, Codable, Equatable, Sendable {
    case genuine
    case fakeCapacitySuspected
    case failing
    case inconclusive
}

public struct CapacityBadFile: Codable, Equatable, Sendable {
    public var name: String
    public var badRanges: [BadRange]

    public init(name: String, badRanges: [BadRange]) {
        self.name = name
        self.badRanges = badRanges
    }
}

public struct CapacityReport: Codable, Equatable, Sendable {
    public var testedBytes: Int64
    public var goodFiles: Int
    public var badFiles: [CapacityBadFile]
    public var freeBytesAtStart: Int64
    public var verdict: CapacityVerdict
    public var notes: [String]

    public init(
        testedBytes: Int64, goodFiles: Int, badFiles: [CapacityBadFile],
        freeBytesAtStart: Int64, verdict: CapacityVerdict, notes: [String]
    ) {
        self.testedBytes = testedBytes
        self.goodFiles = goodFiles
        self.badFiles = badFiles
        self.freeBytesAtStart = freeBytesAtStart
        self.verdict = verdict
        self.notes = notes
    }
}

public enum CapacityPattern {
    public static func fill(
        _ buffer: UnsafeMutableRawBufferPointer, seed: UInt64,
        fileIndex: Int, offset: Int64
    ) {
        precondition(offset >= 0 && offset.isMultiple(of: 8), "offset must be 8-byte aligned")
        let firstBlock = UInt64(offset / 8)
        let fileBits = UInt64(bitPattern: Int64(fileIndex))
        for index in 0..<buffer.count {
            let block = firstBlock + UInt64(index / 8)
            var value = seed &+ fileBits &* 0x9E37_79B9_7F4A_7C15 &+ block &* 0xD1B5_4A32_D192_ED03
            value = splitMix64(&value)
            let shift = (index % 8) * 8
            buffer[index] = UInt8(truncatingIfNeeded: value >> UInt64(shift))
        }
    }

    private static func splitMix64(_ value: inout UInt64) -> UInt64 {
        value &+= 0x9E37_79B9_7F4A_7C15
        var result = value
        result = (result ^ (result >> 30)) &* 0xBF58_476D_1CE4_E5B9
        result = (result ^ (result >> 27)) &* 0x94D0_49BB_1331_11EB
        return result ^ (result >> 31)
    }
}

public final class CapacityRunner: @unchecked Sendable {
    public let control = JobControl()
    public let events: AsyncStream<JobEvent>

    private struct Manifest: Codable {
        var names: [String]
        var sizes: [Int64]
        var seed: UInt64
        var volumeID: String
    }

    private enum Stop: Error {
        case cancelled
        case paused(PauseReason, Int64)
    }

    private var volume: Volume
    private let config: CapacityConfig
    private let io: any DriveIO
    private let volumeControl: any VolumeControl
    private let manifestPath: String?
    private let sink: (any RunSink)?
    private let environment: RunEnvironment
    private let clock: EngineClock
    private let continuation: AsyncStream<JobEvent>.Continuation
    private var manifest: Manifest
    private var notes: [String] = []
    private var testedBytes: Int64 = 0
    private var totalBytes: Int64 = 1
    private var currentFileIndex = 0
    private var currentFileName = ""
    private var currentFileBytes: Int64 = 0
    private var currentPhase: JobPhase = .copying

    public init(
        volume: Volume, config: CapacityConfig = CapacityConfig(), io: any DriveIO,
        volumeControl: any VolumeControl, manifestPath: String? = nil,
        sink: (any RunSink)? = nil, environment: RunEnvironment = RunEnvironment(),
        clock: EngineClock = .system
    ) {
        self.volume = volume
        self.config = config
        self.io = io
        self.volumeControl = volumeControl
        self.manifestPath = manifestPath
        self.sink = sink
        self.environment = environment
        self.clock = clock
        self.manifest = Manifest(names: [], sizes: [], seed: config.seed, volumeID: volume.id.uuid)
        let stream = AsyncStream<JobEvent>.makeStream(of: JobEvent.self)
        self.events = stream.stream
        self.continuation = stream.continuation
    }

    public func run() async -> CapacityReport {
        let started = Date()
        var freeAtStart: Int64 = 0
        var endedBecauseFull = false
        var disconnected = false
        do {
            freeAtStart = try io.freeSpace(path: volume.mountPath)
            totalBytes = max(freeAtStart - max(config.reserveBytes, 0), 1)
            currentPhase = .copying
            continuation.yield(.phase(fileIndex: 0, .copying))
            endedBecauseFull = try await writeFiles()
            guard !manifest.names.isEmpty else {
                notes.append("The drive had no space available above the reserve.")
                throw Stop.cancelled
            }
            try await remount()
            currentPhase = .finalCheck
            continuation.yield(.phase(fileIndex: 0, .finalCheck))
            let badFiles = try readFiles()
            let verdict = verdict(badFiles: badFiles, endedBecauseFull: endedBecauseFull)
            await cleanupKeepingManifestOnDisconnect(false)
            let report = makeReport(freeAtStart: freeAtStart, badFiles: badFiles, verdict: verdict)
            await finishRecord(report, started: started)
            continuation.yield(.finished)
            continuation.finish()
            return report
        } catch Stop.cancelled {
            notes.append("The capacity test was cancelled.")
        } catch Stop.paused(let reason, let offset) {
            disconnected = reason == .driveDisconnected
            notes.append("The test stopped because the drive was disconnected.")
            continuation.yield(.paused(reason, atOffset: offset))
        } catch VerifyError.driveDisconnected {
            disconnected = true
            notes.append("The drive was disconnected during the capacity test.")
        } catch VerifyError.volumeNotFound {
            disconnected = true
            notes.append("The volume was not found during the capacity test.")
        } catch let error as VerifyError {
            notes.append(error.plainMessage)
            notes.append(error.technicalDetail)
        } catch {
            notes.append("The capacity test failed: \(error)")
        }
        await cleanupKeepingManifestOnDisconnect(disconnected)
        let report = makeReport(freeAtStart: freeAtStart, badFiles: [], verdict: .inconclusive)
        await finishRecord(report, started: started)
        continuation.yield(.finished)
        continuation.finish()
        return report
    }

    public func cleanup() async {
        if let saved = loadManifest() { manifest = saved }
        await cleanupKeepingManifestOnDisconnect(false)
    }

    private func writeFiles() async throws -> Bool {
        guard config.testFileSize > 0 else { throw VerifyError.io(operation: "capacity size", code: EINVAL) }
        while true {
            try checkControl(currentFileBytes)
            let free = try io.freeSpace(path: volume.mountPath)
            if free <= max(config.reserveBytes, 0) { return true }
            let length = min(config.testFileSize, free - max(config.reserveBytes, 0))
            guard length > 0 else { return true }
            currentFileIndex = manifest.names.count
            var nameIndex = currentFileIndex
            repeat {
                currentFileName = String(format: "%@%04d.bin", Defaults.capacityTestPrefix, nameIndex)
                nameIndex += 1
            } while io.fileSize(path: (try? filePath(currentFileName)) ?? "") != nil
            currentFileBytes = 0
            do {
                try writeFile(name: currentFileName, length: length, fileIndex: currentFileIndex)
            } catch VerifyError.noSpace {
                try? removeFile(name: currentFileName)
                return true
            }
            manifest.names.append(currentFileName)
            manifest.sizes.append(length)
            testedBytes += length
            saveManifest()
            emitProgress()
            if length < config.testFileSize { return true }
        }
    }

    private func writeFile(name: String, length: Int64, fileIndex: Int) throws {
        let path = try filePath(name)
        let writer = try io.createWriter(path: path, truncate: true)
        defer { try? writer.close() }
        let capacity = max(Defaults.alignment, min(Defaults.ioSliceSize, Int(length)))
        let buffer = AlignedBuffer(capacity: capacity)
        var offset: Int64 = 0
        while offset < length {
            try checkControl(offset)
            let count = min(Int64(buffer.capacity), length - offset)
            CapacityPattern.fill(
                buffer.mutableBytes(count: Int(count)), seed: config.seed,
                fileIndex: fileIndex, offset: offset)
            try writer.write(buffer.bytes(count: Int(count)), at: offset)
            offset += count
            currentFileBytes = offset
            emitProgress()
        }
        _ = try writer.flush()
    }

    private func remount() async throws {
        currentPhase = .remounting
        continuation.yield(.phase(fileIndex: currentFileIndex, .remounting))
        while true {
            try checkControl(testedBytes)
            do {
                try await volumeControl.unmount(volume: volume.id)
                break
            } catch VerifyError.unmountBusy(let blockers) {
                currentPhase = .waitingUnmount
                continuation.yield(.phase(fileIndex: currentFileIndex, .waitingUnmount))
                continuation.yield(.waitingForUnmount(blockers: blockers))
                while !control.takeRetry() {
                    try checkControl(testedBytes)
                    await clock.sleep(0.25)
                }
            } catch VerifyError.volumeNotFound {
                throw VerifyError.driveDisconnected(atOffset: testedBytes)
            }
        }
        do {
            volume.mountPath = try await volumeControl.mount(volume: volume.id)
        } catch VerifyError.volumeNotFound {
            throw VerifyError.driveDisconnected(atOffset: testedBytes)
        }
    }

    private func readFiles() throws -> [CapacityBadFile] {
        var badFiles: [CapacityBadFile] = []
        var done: Int64 = 0
        for index in manifest.names.indices {
            currentFileIndex = index
            currentFileName = manifest.names[index]
            currentFileBytes = 0
            let name = manifest.names[index]
            let expectedSize = manifest.sizes[index]
            let reader = try io.openReader(path: try filePath(name))
            defer { reader.close() }
            let capacity = max(Defaults.alignment, min(Defaults.ioSliceSize, Int(max(expectedSize, 1))))
            let actual = AlignedBuffer(capacity: capacity)
            let expected = AlignedBuffer(capacity: capacity)
            var ranges: [BadRange] = []
            var offset: Int64 = 0
            while offset < expectedSize {
                try checkControl(done)
                let count = min(Int64(actual.capacity), expectedSize - offset)
                let got = try reader.read(into: actual.mutableBytes(count: Int(count)), at: offset)
                CapacityPattern.fill(
                    expected.mutableBytes(count: Int(count)), seed: manifest.seed,
                    fileIndex: index, offset: offset)
                if got < Int(count) {
                    ranges.append(BadRange(offset: offset + Int64(got), length: count - Int64(got)))
                }
                if got > 0 {
                    ranges.append(
                        contentsOf: actual.differences(from: expected, count: got)
                            .map { BadRange(offset: offset + $0.offset, length: $0.length) })
                }
                offset += count
                done += count
                currentFileBytes = offset
                emitProgress(done: done, total: testedBytes)
            }
            if reader.size > expectedSize {
                ranges.append(BadRange(offset: expectedSize, length: reader.size - expectedSize))
            }
            let merged = merge(ranges)
            if merged.isEmpty {
                continue
            }
            badFiles.append(CapacityBadFile(name: name, badRanges: merged))
        }
        return badFiles
    }

    private func verdict(badFiles: [CapacityBadFile], endedBecauseFull: Bool) -> CapacityVerdict {
        guard !manifest.names.isEmpty, endedBecauseFull else { return .inconclusive }
        guard !badFiles.isEmpty else { return .genuine }
        let last = manifest.names.last
        return badFiles.contains { $0.name != last } ? .fakeCapacitySuspected : .failing
    }

    private func makeReport(
        freeAtStart: Int64, badFiles: [CapacityBadFile],
        verdict: CapacityVerdict
    ) -> CapacityReport {
        CapacityReport(
            testedBytes: testedBytes, goodFiles: manifest.names.count - badFiles.count,
            badFiles: badFiles, freeBytesAtStart: freeAtStart,
            verdict: verdict, notes: notes)
    }

    private func finishRecord(_ report: CapacityReport, started: Date) async {
        guard let sink else { return }
        let ranges = report.badFiles.flatMap(\.badRanges)
        await sink.record(
            RunRecord(
                startedAt: started, endedAt: Date(), kind: .capacityTest, mode: nil,
                driveName: volume.name, volumeUUID: volume.id.uuid, model: volume.model,
                filesystem: volume.filesystem.displayName,
                filesystemDriver: environment.filesystemDriver,
                macOSVersion: environment.macOSVersion, route: volume.route ?? environment.route,
                destinationPath: volume.mountPath, sizeBytes: report.testedBytes,
                chunkSize: Defaults.chunkSize, retries: 0, badRanges: ranges,
                result: report.verdict.rawValue, notes: report.notes))
    }

    private func cleanupKeepingManifestOnDisconnect(_ keepManifest: Bool) async {
        for name in manifest.names where isSafeTestName(name) {
            do {
                try io.removeFile(path: try filePath(name))
            } catch VerifyError.driveDisconnected {
                notes.append("Cleanup could not remove \(name) because the drive is disconnected.")
            } catch {
                notes.append("Cleanup could not remove \(name): \(error).")
            }
        }
        guard !keepManifest else { return }
        if manifest.names.allSatisfy({ io.fileSize(path: (try? filePath($0)) ?? "") == nil }) {
            removeManifest()
        }
    }

    private func filePath(_ name: String) throws -> String {
        try DestinationGuard(volume: volume).path(folder: config.folder, name: name)
    }

    private func removeFile(name: String) throws {
        try io.removeFile(path: filePath(name))
    }

    private func saveManifest() {
        guard let manifestPath else { return }
        do {
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: URL(fileURLWithPath: manifestPath), options: .atomic)
        } catch {
            notes.append("Could not save the capacity manifest: \(error).")
        }
    }

    private func loadManifest() -> Manifest? {
        guard let manifestPath else { return manifest }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: manifestPath)),
            let value = try? JSONDecoder().decode(Manifest.self, from: data),
            value.volumeID == volume.id.uuid
        else {
            return nil
        }
        return value
    }

    private func removeManifest() {
        guard let manifestPath else { return }
        try? FileManager.default.removeItem(atPath: manifestPath)
    }

    private func isSafeTestName(_ name: String) -> Bool {
        name.hasPrefix(Defaults.capacityTestPrefix) && name.hasSuffix(".bin") && !name.contains("/")
            && !name.contains("\\") && !name.contains("..")
    }

    private func checkControl(_ offset: Int64) throws {
        if control.isCancelled { throw Stop.cancelled }
        if let reason = control.pendingPause { throw Stop.paused(reason, offset) }
    }

    private func emitProgress(done: Int64? = nil, total: Int64? = nil) {
        let completed = done ?? testedBytes + currentFileBytes
        let overall = max(total ?? totalBytes, 1)
        continuation.yield(
            .progress(
                ProgressSnapshot(
                    fileIndex: currentFileIndex, fileCount: max(manifest.names.count + 1, 1), fileName: currentFileName,
                    phase: currentPhase, fileBytesDone: completed, fileBytesTotal: overall,
                    chunksVerified: 0, chunksRetried: 0, bytesPerSecond: 0, secondsRemaining: nil,
                    batchBytesDone: completed, batchBytesTotal: overall)))
    }

    private func merge(_ ranges: [BadRange]) -> [BadRange] {
        let sorted = ranges.sorted { $0.offset < $1.offset }
        var merged: [BadRange] = []
        for range in sorted {
            guard range.length > 0 else { continue }
            if let last = merged.last, range.offset <= last.end {
                merged[merged.count - 1].length = max(last.end, range.end) - last.offset
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
