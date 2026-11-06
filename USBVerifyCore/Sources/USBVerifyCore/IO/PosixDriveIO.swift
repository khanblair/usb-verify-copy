import Darwin
import Foundation

public final class PosixDriveIO: DriveIO, @unchecked Sendable {
    public init() {}

    public func openSource(path: String) throws -> any SourceFile {
        let fd = try openDescriptor(path: path, flags: O_RDONLY)
        do {
            let identity = try identity(of: fd, path: path)
            if Darwin.fcntl(fd, F_NOCACHE, 1) == -1 {
                let code = errno
                throw mapError(operation: "fcntl", code: code, path: path, offset: 0)
            }
            return PosixSourceFile(fd: fd, identity: identity)
        } catch {
            _ = Darwin.close(fd)
            throw error
        }
    }

    public func createWriter(path: String, truncate: Bool) throws -> any DestinationWriter {
        var flags = O_WRONLY | O_CREAT
        if truncate { flags |= O_TRUNC }
        let fd = try openDescriptor(path: path, flags: flags, mode: 0o644)
        if Darwin.fcntl(fd, F_NOCACHE, 1) == -1 {
            let code = errno
            _ = Darwin.close(fd)
            throw mapError(operation: "fcntl", code: code, path: path, offset: 0)
        }
        return PosixWriter(fd: fd, path: path)
    }

    public func openReader(path: String) throws -> any DestinationReader {
        let fd = try openDescriptor(path: path, flags: O_RDONLY)
        do {
            let size = try identity(of: fd, path: path).size
            if Darwin.fcntl(fd, F_NOCACHE, 1) == -1 {
                let code = errno
                throw mapError(operation: "fcntl", code: code, path: path, offset: 0)
            }
            return PosixReader(fd: fd, path: path, size: size)
        } catch {
            _ = Darwin.close(fd)
            throw error
        }
    }

    public func fileSize(path: String) -> Int64? {
        let fd = path.withCString { Darwin.open($0, O_RDONLY) }
        guard fd >= 0 else { return nil }
        var info = stat()
        let result = Darwin.fstat(fd, &info)
        _ = Darwin.close(fd)
        return result == 0 ? Int64(info.st_size) : nil
    }

    public func rename(from: String, to: String) throws {
        if from.withCString({ fromPointer in to.withCString { toPointer in Darwin.rename(fromPointer, toPointer) } })
            != 0
        {
            throw mapError(operation: "rename", code: errno, path: to, offset: 0)
        }
    }

    public func removeFile(path: String) throws {
        if path.withCString({ Darwin.unlink($0) }) != 0 {
            throw mapError(operation: "unlink", code: errno, path: path, offset: 0)
        }
    }

    public func createDirectory(path: String) throws {
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        } catch {
            let code = (error as NSError).code == NSFileWriteNoPermissionError ? EACCES : EIO
            throw mapError(operation: "mkdir", code: code, path: path, offset: 0)
        }
    }

    public func freeSpace(path: String) throws -> Int64 {
        var info = statfs()
        if path.withCString({ pointer in statfs(pointer, &info) }) != 0 {
            throw mapError(operation: "statfs", code: errno, path: path, offset: 0)
        }
        let available = UInt64(info.f_bavail) * UInt64(info.f_bsize)
        return available > UInt64(Int64.max) ? Int64.max : Int64(available)
    }

    internal func descriptorHasNoCache(_ descriptor: Int32) -> Bool {
        Darwin.fcntl(descriptor, F_NOCACHE, 0) > 0
    }

    internal func sourceHasNoCache(path: String) throws -> Bool {
        let source = try openSource(path: path)
        let result = (source as? PosixSourceFile)?.hasNoCache ?? false
        source.close()
        return result
    }

    internal func writerHasNoCache(path: String) throws -> Bool {
        let writer = try createWriter(path: path, truncate: false)
        let result = (writer as? PosixWriter)?.hasNoCache ?? false
        try writer.close()
        return result
    }

    internal func readerHasNoCache(path: String) throws -> Bool {
        let reader = try openReader(path: path)
        let result = (reader as? PosixReader)?.hasNoCache ?? false
        reader.close()
        return result
    }

    internal func mapError(operation: String, code: Int32, path: String, offset: Int64) -> VerifyError {
        switch code {
        case ENOSPC, EDQUOT: return .noSpace(needed: 0, available: 0)
        case EACCES, EPERM, EROFS: return .permissionDenied(path: path)
        case EIO, ENXIO, ENODEV, ENOTCONN, ESTALE, EBADF: return .driveDisconnected(atOffset: offset)
        default: return .io(operation: operation, code: code)
        }
    }

    private func openDescriptor(path: String, flags: Int32, mode: mode_t = 0) throws -> Int32 {
        let fd = path.withCString { Darwin.open($0, flags, mode) }
        guard fd >= 0 else { throw mapError(operation: "open", code: errno, path: path, offset: 0) }
        return fd
    }

    private func identity(of fd: Int32, path: String) throws -> FileIdentity {
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0 else {
            throw mapError(operation: "fstat", code: errno, path: path, offset: 0)
        }
        return FileIdentity(
            size: Int64(info.st_size),
            modifiedTimeNs: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
            inode: UInt64(info.st_ino))
    }
}

private final class PosixSourceFile: SourceFile, @unchecked Sendable {
    private let fd: Int32
    let identity: FileIdentity
    let hasNoCache = true
    private var closed = false
    init(fd: Int32, identity: FileIdentity) {
        self.fd = fd
        self.identity = identity
    }
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: Int64) throws -> Int {
        guard !closed, buffer.count > 0 else { return 0 }
        var total = 0
        while total < buffer.count {
            let result = pread(fd, buffer.baseAddress!.advanced(by: total), buffer.count - total, offset + Int64(total))
            if result > 0 {
                total += result
                continue
            }
            if result == 0 { break }
            if errno == EINTR { continue }
            throw PosixDriveIO().mapError(
                operation: "pread", code: errno, path: "source", offset: offset + Int64(total))
        }
        return total
    }
    func close() {
        if !closed {
            closed = true
            _ = Darwin.close(fd)
        }
    }
    deinit { close() }
}

private final class PosixWriter: DestinationWriter, @unchecked Sendable {
    private let fd: Int32
    private let path: String
    private var closed = false
    let hasNoCache = true
    init(fd: Int32, path: String) {
        self.fd = fd
        self.path = path
    }
    func write(_ buffer: UnsafeRawBufferPointer, at offset: Int64) throws {
        guard !closed, buffer.count > 0 else { return }
        var total = 0
        while total < buffer.count {
            let result = pwrite(
                fd, buffer.baseAddress!.advanced(by: total), buffer.count - total, offset + Int64(total))
            if result > 0 {
                total += result
                continue
            }
            if result < 0, errno == EINTR { continue }
            throw PosixDriveIO().mapError(operation: "pwrite", code: errno, path: path, offset: offset + Int64(total))
        }
    }
    func flush() throws -> String? {
        guard !closed else { return nil }
        if fsync(fd) != 0 { throw PosixDriveIO().mapError(operation: "fsync", code: errno, path: path, offset: 0) }
        if Darwin.fcntl(fd, F_FULLFSYNC) != 0 { return "F_FULLFSYNC failed: errno \(errno)" }
        return nil
    }
    func close() throws {
        guard !closed else { return }
        closed = true
        if Darwin.close(fd) != 0 {
            throw PosixDriveIO().mapError(operation: "close", code: errno, path: path, offset: 0)
        }
    }
    deinit { if !closed { _ = Darwin.close(fd) } }
}

private final class PosixReader: DestinationReader, @unchecked Sendable {
    private let fd: Int32
    private let path: String
    let size: Int64
    private var closed = false
    let hasNoCache = true
    init(fd: Int32, path: String, size: Int64) {
        self.fd = fd
        self.path = path
        self.size = size
    }
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: Int64) throws -> Int {
        guard !closed, buffer.count > 0 else { return 0 }
        var total = 0
        while total < buffer.count {
            let result = pread(fd, buffer.baseAddress!.advanced(by: total), buffer.count - total, offset + Int64(total))
            if result > 0 {
                total += result
                continue
            }
            if result == 0 { break }
            if errno == EINTR { continue }
            throw PosixDriveIO().mapError(operation: "pread", code: errno, path: path, offset: offset + Int64(total))
        }
        return total
    }
    func close() {
        if !closed {
            closed = true
            _ = Darwin.close(fd)
        }
    }
    deinit { close() }
}
