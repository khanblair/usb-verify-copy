import Foundation

public enum VerifyMode: String, Codable, Sendable, CaseIterable {
    case strict, quick
}

public enum JobKind: String, Codable, Sendable {
    case copy, verifyOnly, capacityTest, format
}

public enum PauseReason: String, Codable, Sendable {
    case driveDisconnected, wake, appQuit
}

public enum JobPhase: String, Codable, Sendable {
    case queued, preflight, copying, finalizing, waitingUnmount, remounting, finalCheck, renaming
    case paused, passed, failed, cancelled
}

/// Identity of the source file when the job starts. A change before the end means FAIL (spec section 8).
public struct FileIdentity: Codable, Equatable, Sendable {
    public var size: Int64
    /// Modified time in nanoseconds since 1970.
    public var modifiedTimeNs: Int64
    public var inode: UInt64
    public init(size: Int64, modifiedTimeNs: Int64, inode: UInt64) {
        self.size = size
        self.modifiedTimeNs = modifiedTimeNs
        self.inode = inode
    }
}

public enum FailureReason: String, Codable, Sendable {
    case chunkFailedAfterRetries, finalCheckMismatch, sourceChanged, wholeFileHashMismatch, ioError, nameConflict
}

/// Result of one file. `passed` carries both whole-file hashes; they are equal.
public enum FileResult: Codable, Equatable, Sendable {
    case passed(sourceHash: String, rereadHash: String)
    case failed(reason: FailureReason, badRanges: [BadRange])
    case skipped(reason: String)
    case cancelled
}

/// Persisted per-file state, written after each verified chunk (spec section 10).
public struct FileJobState: Codable, Equatable, Sendable {
    public var sourcePath: String
    /// Folder on the volume, relative to the volume root. Never an absolute path: the mount path can change.
    public var destinationFolder: String
    public var finalName: String
    public var tempName: String
    public var chunkSize: Int
    public var sourceIdentity: FileIdentity
    /// SHA-256 (hex) of each source chunk already written, in order.
    public var chunkHashes: [String]
    /// Chunks whose read-back or final check failed, only filled in "keep scanning" mode.
    public var badRanges: [BadRange]
    public var retries: Int
    public var warnings: [String]
    public var phase: JobPhase
    public var result: FileResult?
    /// Replace an existing file with the final name (the user chose "replace").
    public var replaceExisting: Bool
    /// "Keep scanning" mode: a failed chunk is recorded and the copy goes on.
    public var keepScanning: Bool
    /// Index of the chunk that failed after retries, when the file stopped there.
    public var failedChunkIndex: Int?
    /// Text of an I/O error that ended the file, if any.
    public var errorDetail: String?

    public init(sourcePath: String, destinationFolder: String, finalName: String, tempName: String,
                chunkSize: Int, sourceIdentity: FileIdentity, chunkHashes: [String] = [],
                badRanges: [BadRange] = [], retries: Int = 0, warnings: [String] = [],
                phase: JobPhase = .queued, result: FileResult? = nil, replaceExisting: Bool = false,
                keepScanning: Bool = false, failedChunkIndex: Int? = nil, errorDetail: String? = nil) {
        self.sourcePath = sourcePath
        self.destinationFolder = destinationFolder
        self.finalName = finalName
        self.tempName = tempName
        self.chunkSize = chunkSize
        self.sourceIdentity = sourceIdentity
        self.chunkHashes = chunkHashes
        self.badRanges = badRanges
        self.retries = retries
        self.warnings = warnings
        self.phase = phase
        self.result = result
        self.replaceExisting = replaceExisting
        self.keepScanning = keepScanning
        self.failedChunkIndex = failedChunkIndex
        self.errorDetail = errorDetail
    }

    /// Offset after the last chunk written. Zero when nothing is written.
    public var writtenBytes: Int64 {
        min(Int64(chunkHashes.count) * Int64(chunkSize), sourceIdentity.size)
    }
}

/// A batch of files for one volume. This is the unit written to the job state file.
public struct PersistedJob: Codable, Equatable, Sendable {
    public var id: String
    public var kind: JobKind
    public var mode: VerifyMode
    public var volumeID: VolumeID
    public var files: [FileJobState]
    public var currentIndex: Int
    public var pausedReason: PauseReason?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, kind: JobKind = .copy, mode: VerifyMode,
                volumeID: VolumeID, files: [FileJobState], currentIndex: Int = 0,
                pausedReason: PauseReason? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.mode = mode
        self.volumeID = volumeID
        self.files = files
        self.currentIndex = currentIndex
        self.pausedReason = pausedReason
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ProgressSnapshot: Equatable, Sendable {
    public var fileIndex: Int
    public var fileCount: Int
    public var fileName: String
    public var phase: JobPhase
    public var fileBytesDone: Int64
    public var fileBytesTotal: Int64
    public var chunksVerified: Int
    public var chunksRetried: Int
    public var bytesPerSecond: Double
    public var secondsRemaining: Double?
    public var batchBytesDone: Int64
    public var batchBytesTotal: Int64

    public init(fileIndex: Int, fileCount: Int, fileName: String, phase: JobPhase,
                fileBytesDone: Int64, fileBytesTotal: Int64, chunksVerified: Int, chunksRetried: Int,
                bytesPerSecond: Double, secondsRemaining: Double?, batchBytesDone: Int64, batchBytesTotal: Int64) {
        self.fileIndex = fileIndex
        self.fileCount = fileCount
        self.fileName = fileName
        self.phase = phase
        self.fileBytesDone = fileBytesDone
        self.fileBytesTotal = fileBytesTotal
        self.chunksVerified = chunksVerified
        self.chunksRetried = chunksRetried
        self.bytesPerSecond = bytesPerSecond
        self.secondsRemaining = secondsRemaining
        self.batchBytesDone = batchBytesDone
        self.batchBytesTotal = batchBytesTotal
    }
}

/// Events the engine sends to the UI.
public enum JobEvent: Equatable, Sendable {
    case phase(fileIndex: Int, JobPhase)
    case progress(ProgressSnapshot)
    case warning(String)
    case waitingForUnmount(blockers: [String])
    case fileFinished(fileIndex: Int, FileResult)
    case paused(PauseReason, atOffset: Int64)
    case finished
}

/// One line of run history (spec section 17). Used by the History view and the text log.
public struct RunRecord: Codable, Equatable, Sendable {
    public var runID: String
    public var startedAt: Date
    public var endedAt: Date
    public var kind: JobKind
    public var mode: VerifyMode?
    public var driveName: String
    public var volumeUUID: String
    public var model: String?
    public var filesystem: String
    public var filesystemDriver: String?
    public var macOSVersion: String
    public var route: Route?
    public var sourcePath: String?
    public var destinationPath: String?
    public var sizeBytes: Int64
    public var chunkSize: Int
    public var retries: Int
    public var badRanges: [BadRange]
    public var fullSyncWarnings: [String]
    public var sourceHash: String?
    public var rereadHash: String?
    /// "PASS", "FAIL", "PAUSED", "CANCELLED", or "SKIPPED".
    public var result: String
    public var notes: [String]

    public init(runID: String = UUID().uuidString, startedAt: Date, endedAt: Date, kind: JobKind,
                mode: VerifyMode?, driveName: String, volumeUUID: String, model: String? = nil,
                filesystem: String, filesystemDriver: String? = nil, macOSVersion: String,
                route: Route? = nil, sourcePath: String? = nil, destinationPath: String? = nil,
                sizeBytes: Int64, chunkSize: Int, retries: Int, badRanges: [BadRange] = [],
                fullSyncWarnings: [String] = [], sourceHash: String? = nil, rereadHash: String? = nil,
                result: String, notes: [String] = []) {
        self.runID = runID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.kind = kind
        self.mode = mode
        self.driveName = driveName
        self.volumeUUID = volumeUUID
        self.model = model
        self.filesystem = filesystem
        self.filesystemDriver = filesystemDriver
        self.macOSVersion = macOSVersion
        self.route = route
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.sizeBytes = sizeBytes
        self.chunkSize = chunkSize
        self.retries = retries
        self.badRanges = badRanges
        self.fullSyncWarnings = fullSyncWarnings
        self.sourceHash = sourceHash
        self.rereadHash = rereadHash
        self.result = result
        self.notes = notes
    }
}
