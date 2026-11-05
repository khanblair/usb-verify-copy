/// A byte range in a file, used to report damage.
public struct BadRange: Codable, Equatable, Hashable, Sendable {
    public var offset: Int64
    public var length: Int64
    public init(offset: Int64, length: Int64) {
        self.offset = offset
        self.length = length
    }
    public var end: Int64 { offset + length }
}

/// Every error shows plain English first and technical detail second.
public protocol UserFacingError: Error {
    var plainMessage: String { get }
    var technicalDetail: String { get }
}

public enum VerifyError: Error, Equatable, Sendable {
    case driveDisconnected(atOffset: Int64)
    case noSpace(needed: Int64, available: Int64)
    case permissionDenied(path: String)
    case chunkFailed(offset: Int64)
    case sourceChanged
    case unmountBusy(blockers: [String])
    case unsupportedFilesystem(String)
    case readOnlyVolume
    case fileTooLargeForFAT32(name: String, size: Int64)
    case invalidFileName(name: String, reason: String)
    case sourceOnTargetDrive(path: String)
    case destinationOutsideVolume(path: String)
    case volumeNotFound(volumeID: String)
    case io(operation: String, code: Int32)
    case commandFailed(command: String, output: String)
    case formatRefused(reason: String)
    case cancelled
}

extension VerifyError: UserFacingError {
    public var plainMessage: String {
        switch self {
        case .driveDisconnected(let offset):
            return "The drive was disconnected at byte \(offset). Reconnect it to resume."
        case .noSpace:
            return "There is not enough free space on the drive."
        case .permissionDenied:
            return "macOS did not allow access to a file or folder."
        case .chunkFailed(let offset):
            return "The drive could not store the data correctly at byte \(offset), even after retries."
        case .sourceChanged:
            return "The source file changed while it was being copied."
        case .unmountBusy:
            return "The drive is in use, so it cannot be unmounted for the final check."
        case .unsupportedFilesystem(let name):
            return "This drive uses \(name). Only exFAT and FAT32 drives can be used."
        case .readOnlyVolume:
            return "The drive is read-only."
        case .fileTooLargeForFAT32(let name, _):
            return "\(name) is too large for a FAT32 drive (limit is 4 GiB)."
        case .invalidFileName(let name, _):
            return "The name \(name) cannot be used on this drive."
        case .sourceOnTargetDrive:
            return "The source file is on the destination drive."
        case .destinationOutsideVolume:
            return "The destination is not on the chosen drive."
        case .volumeNotFound:
            return "The drive is not connected."
        case .io:
            return "A read or write failed."
        case .commandFailed:
            return "A system command failed."
        case .formatRefused(let reason):
            return "Format was refused: \(reason)"
        case .cancelled:
            return "The job was cancelled."
        }
    }

    public var technicalDetail: String {
        switch self {
        case .driveDisconnected(let offset): return "driveDisconnected offset=\(offset)"
        case .noSpace(let needed, let available): return "noSpace needed=\(needed) available=\(available)"
        case .permissionDenied(let path): return "permissionDenied path=\(path)"
        case .chunkFailed(let offset): return "chunkFailed offset=\(offset)"
        case .sourceChanged: return "source size, modified time, or inode changed"
        case .unmountBusy(let blockers): return "unmountBusy blockers=\(blockers.joined(separator: ", "))"
        case .unsupportedFilesystem(let name): return "unsupportedFilesystem \(name)"
        case .readOnlyVolume: return "mount flags include read-only"
        case .fileTooLargeForFAT32(let name, let size): return "fileTooLargeForFAT32 \(name) size=\(size)"
        case .invalidFileName(let name, let reason): return "invalidFileName \(name): \(reason)"
        case .sourceOnTargetDrive(let path): return "sourceOnTargetDrive \(path)"
        case .destinationOutsideVolume(let path): return "destinationOutsideVolume \(path)"
        case .volumeNotFound(let id): return "volumeNotFound uuid=\(id)"
        case .io(let op, let code): return "io operation=\(op) errno=\(code)"
        case .commandFailed(let cmd, let out): return "commandFailed \(cmd)\n\(out)"
        case .formatRefused(let reason): return "formatRefused \(reason)"
        case .cancelled: return "cancelled"
        }
    }
}
