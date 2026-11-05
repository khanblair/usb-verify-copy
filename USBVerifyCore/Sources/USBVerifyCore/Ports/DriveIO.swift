/// File I/O seen by the engine. `PosixDriveIO` is the real one, `FakeDrive` is the test one.
/// All paths are full paths. A "drive path" is a path under the volume mount point.

public protocol SourceFile: AnyObject, Sendable {
    var identity: FileIdentity { get }
    /// Reads up to `buffer.count` bytes at `offset`. Returns the bytes read. Fewer than asked only at end of file.
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: Int64) throws -> Int
    func close()
}

public protocol DestinationWriter: AnyObject, Sendable {
    func write(_ buffer: UnsafeRawBufferPointer, at offset: Int64) throws
    /// `fsync`, then `F_FULLFSYNC`. A failed `F_FULLFSYNC` is returned as a warning text, not thrown.
    func flush() throws -> String?
    func close() throws
}

public protocol DestinationReader: AnyObject, Sendable {
    var size: Int64 { get }
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: Int64) throws -> Int
    func close()
}

public protocol DriveIO: Sendable {
    func openSource(path: String) throws -> any SourceFile
    /// Creates the file. When `truncate` is false and the file exists, it is opened for writing without changing its size.
    /// The real implementation sets `F_NOCACHE` right after open, before any write.
    func createWriter(path: String, truncate: Bool) throws -> any DestinationWriter
    /// Opens a separate read descriptor with `F_NOCACHE` set.
    func openReader(path: String) throws -> any DestinationReader
    /// nil when the file does not exist.
    func fileSize(path: String) -> Int64?
    func rename(from: String, to: String) throws
    func removeFile(path: String) throws
    func freeSpace(path: String) throws -> Int64
}
