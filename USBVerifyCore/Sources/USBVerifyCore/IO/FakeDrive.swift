import Darwin
import Foundation

public final class FakeDrive: DriveIO, @unchecked Sendable {
    private struct File {
        var device: [UInt8]
        var cache: [UInt8]
    }
    private struct Source {
        var data: [UInt8]
        var modifiedTimeNs: Int64
        var inode: UInt64
    }
    private let lock = NSLock()
    private let mountPath: String
    private let capacityBytes: Int64
    private let physicalCapacityBytes: Int64?
    private var files: [String: File] = [:]
    private var creationOrder: [String] = []
    private var damagedOverflowBytes: Int64 = 0
    private var sources: [String: Source] = [:]
    private var writeFlips: [(offset: Int64, remaining: Int)] = []
    private var remountCorruption: [(suffix: String, offset: Int64)] = []
    private var _servesReadsFromCache = false
    private var _fullSyncWarning: String?
    private var _beforeWrite: (@Sendable (String, Int64, Int) throws -> Void)?
    private var _beforeRead: (@Sendable (String, Int64, Int) throws -> Void)?
    private var _isUnplugged = false
    private var _writeCount = 0
    private var _readCount = 0

    public init(
        mountPath: String, capacityBytes: Int64 = Int64.max,
        physicalCapacityBytes: Int64? = nil
    ) {
        self.mountPath = mountPath.hasSuffix("/") ? String(mountPath.dropLast()) : mountPath
        self.capacityBytes = capacityBytes
        self.physicalCapacityBytes = physicalCapacityBytes
    }
    public func addSource(path: String, data: [UInt8], modifiedTimeNs: Int64 = 1, inode: UInt64 = 1) {
        lock.withLock { sources[path] = Source(data: data, modifiedTimeNs: modifiedTimeNs, inode: inode) }
    }
    public func changeSource(path: String, data: [UInt8]) {
        lock.withLock {
            guard var source = sources[path] else { return }
            source.data = data
            source.modifiedTimeNs += 1
            sources[path] = source
        }
    }
    public func contents(of path: String) -> [UInt8]? { lock.withLock { files[path]?.device } }
    public func listFiles() -> [String] { lock.withLock { files.keys.sorted() } }
    public func dropCaches() {
        lock.withLock {
            for key in files.keys { files[key]?.cache.removeAll(keepingCapacity: false) }
            for fault in remountCorruption {
                for key in files.keys where key.hasSuffix(fault.suffix) {
                    guard var file = files[key], fault.offset >= 0, fault.offset < Int64(file.device.count) else {
                        continue
                    }
                    file.device[Int(fault.offset)] ^= 1
                    files[key] = file
                }
            }
        }
    }
    public func flipByteOnWrite(fileOffset: Int64, times: Int) {
        lock.withLock { if times > 0 { writeFlips.append((fileOffset, times)) } }
    }
    public func corruptOnRemount(pathSuffix: String, fileOffset: Int64) {
        lock.withLock { remountCorruption.append((pathSuffix, fileOffset)) }
    }

    public var servesReadsFromCache: Bool {
        get { lock.withLock { _servesReadsFromCache } }
        set { lock.withLock { _servesReadsFromCache = newValue } }
    }
    public var fullSyncWarning: String? {
        get { lock.withLock { _fullSyncWarning } }
        set { lock.withLock { _fullSyncWarning = newValue } }
    }
    public var beforeWrite: (@Sendable (String, Int64, Int) throws -> Void)? {
        get { lock.withLock { _beforeWrite } }
        set { lock.withLock { _beforeWrite = newValue } }
    }
    public var beforeRead: (@Sendable (String, Int64, Int) throws -> Void)? {
        get { lock.withLock { _beforeRead } }
        set { lock.withLock { _beforeRead = newValue } }
    }
    public var isUnplugged: Bool {
        get { lock.withLock { _isUnplugged } }
        set { lock.withLock { _isUnplugged = newValue } }
    }
    public var writeCount: Int { lock.withLock { _writeCount } }
    public var readCount: Int { lock.withLock { _readCount } }

    public func openSource(path: String) throws -> any SourceFile {
        lock.lock()
        defer { lock.unlock() }
        if _isUnplugged { throw disconnected(0) }
        guard let source = sources[path] else { throw io(ENOENT, "open") }
        return FakeSource(
            drive: self, path: path,
            identity: FileIdentity(
                size: Int64(source.data.count), modifiedTimeNs: source.modifiedTimeNs, inode: source.inode))
    }
    public func createWriter(path: String, truncate: Bool) throws -> any DestinationWriter {
        try checkPath(path)
        try checkConnected(0)
        lock.lock()
        if truncate || files[path] == nil {
            if files[path] == nil { creationOrder.append(path) }
            files[path] = File(device: [], cache: [])
        }
        lock.unlock()
        return FakeWriter(drive: self, path: path)
    }
    public func openReader(path: String) throws -> any DestinationReader {
        try checkPath(path)
        try checkConnected(0)
        lock.lock()
        guard let file = files[path] else {
            lock.unlock()
            throw io(ENOENT, "open")
        }
        let size = Int64(file.device.count)
        lock.unlock()
        return FakeReader(drive: self, path: path, size: size)
    }
    public func fileSize(path: String) -> Int64? { lock.withLock { files[path].map { Int64($0.device.count) } } }
    public func rename(from: String, to: String) throws {
        try checkPath(from)
        try checkPath(to)
        try checkConnected(0)
        lock.withLock {
            if let file = files.removeValue(forKey: from) {
                files[to] = file
                if let index = creationOrder.firstIndex(of: from) { creationOrder[index] = to }
            }
        }
    }
    public func removeFile(path: String) throws {
        try checkPath(path)
        try checkConnected(0)
        lock.lock()
        defer { lock.unlock() }
        guard files.removeValue(forKey: path) != nil else { throw io(ENOENT, "unlink") }
    }
    public func freeSpace(path: String) throws -> Int64 {
        try checkPath(path)
        try checkConnected(0)
        return lock.withLock {
            let used = files.values.reduce(Int64(0)) { $0 + Int64($1.device.count) }
            return capacityBytes >= used ? capacityBytes - used : 0
        }
    }

    private func checkPath(_ path: String) throws {
        guard path.hasPrefix(mountPath + "/") else { throw VerifyError.destinationOutsideVolume(path: path) }
    }
    private func checkConnected(_ offset: Int64) throws {
        if lock.withLock({ _isUnplugged }) { throw disconnected(offset) }
    }
    private func disconnected(_ offset: Int64) -> VerifyError { .driveDisconnected(atOffset: offset) }
    private func io(_ code: Int32, _ operation: String) -> VerifyError { .io(operation: operation, code: code) }
    private func hookRead(path: String, offset: Int64, length: Int) throws {
        let hook = beforeRead
        try checkConnected(offset)
        try hook?(path, offset, length)
    }
    private func hookWrite(path: String, offset: Int64, length: Int) throws {
        let hook = beforeWrite
        try checkConnected(offset)
        try hook?(path, offset, length)
    }

    fileprivate func read(path: String, into buffer: UnsafeMutableRawBufferPointer, at offset: Int64) throws -> Int {
        try hookRead(path: path, offset: offset, length: buffer.count)
        guard offset >= 0 else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        guard let file = files[path], offset < Int64(file.device.count) else { return 0 }
        _readCount += 1
        let source =
            _servesReadsFromCache && offset + Int64(buffer.count) <= Int64(file.cache.count) ? file.cache : file.device
        let count = min(buffer.count, source.count - Int(offset))
        buffer.copyBytes(from: source[Int(offset)..<(Int(offset) + count)])
        return count
    }
    fileprivate func sourceRead(path: String, into buffer: UnsafeMutableRawBufferPointer, at offset: Int64) throws
        -> Int
    {
        try hookRead(path: path, offset: offset, length: buffer.count)
        lock.lock()
        defer { lock.unlock() }
        guard let source = sources[path], offset >= 0, offset < Int64(source.data.count) else { return 0 }
        let count = min(buffer.count, source.data.count - Int(offset))
        buffer.copyBytes(from: source.data[Int(offset)..<(Int(offset) + count)])
        _readCount += 1
        return count
    }
    fileprivate func write(path: String, buffer: UnsafeRawBufferPointer, at offset: Int64) throws {
        try hookWrite(path: path, offset: offset, length: buffer.count)
        guard offset >= 0 else { throw io(EINVAL, "pwrite") }
        lock.lock()
        defer { lock.unlock() }
        guard var file = files[path] else { throw io(ENOENT, "pwrite") }
        let end = offset + Int64(buffer.count)
        let oldSize = Int64(file.device.count)
        let added = max(0, end - oldSize)
        let used = files.values.reduce(Int64(0)) { $0 + Int64($1.device.count) }
        if added > 0 && used + added > capacityBytes {
            throw VerifyError.noSpace(needed: added, available: max(0, capacityBytes - used))
        }
        if end > oldSize {
            file.device.append(contentsOf: repeatElement(0, count: Int(end - oldSize)))
            file.cache.append(contentsOf: repeatElement(0, count: Int(end - oldSize)))
        }
        let bytes = Array(buffer)
        file.cache.replaceSubrange(Int(offset)..<Int(end), with: bytes)
        var stored = bytes
        for index in writeFlips.indices
        where writeFlips[index].remaining > 0 && offset <= writeFlips[index].offset && writeFlips[index].offset < end {
            stored[Int(writeFlips[index].offset - offset)] ^= 1
            writeFlips[index].remaining -= 1
        }
        file.device.replaceSubrange(Int(offset)..<Int(end), with: stored)
        writeFlips.removeAll { $0.remaining == 0 }
        files[path] = file
        damageWrapAroundIfNeeded(writing: path)
        _writeCount += 1
    }
    private func damageWrapAroundIfNeeded(writing path: String) {
        guard let physicalCapacityBytes else { return }
        let used = files.values.reduce(Int64(0)) { $0 + Int64($1.device.count) }
        guard used > physicalCapacityBytes else { return }
        let overflow = used - physicalCapacityBytes
        guard let targetPath = creationOrder.first(where: { $0 != path }), var target = files[targetPath] else {
            return
        }
        let newOverflow = max(0, overflow - damagedOverflowBytes)
        damagedOverflowBytes = max(damagedOverflowBytes, overflow)
        let steps = (newOverflow + 4095) / 4096
        for step in 0..<steps {
            let offset = step * 4096
            guard offset < Int64(target.device.count) else { break }
            target.device[Int(offset)] ^= 1
        }
        files[targetPath] = target
    }
    fileprivate func warning() -> String? { fullSyncWarning }
}

extension NSLock {
    fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
private final class FakeSource: SourceFile, @unchecked Sendable {
    weak var drive: FakeDrive?
    let path: String
    let identity: FileIdentity
    init(drive: FakeDrive, path: String, identity: FileIdentity) {
        self.drive = drive
        self.path = path
        self.identity = identity
    }
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: Int64) throws -> Int {
        try drive?.sourceRead(path: path, into: buffer, at: offset) ?? 0
    }
    func close() {}
}
private final class FakeWriter: DestinationWriter, @unchecked Sendable {
    weak var drive: FakeDrive?
    let path: String
    init(drive: FakeDrive, path: String) {
        self.drive = drive
        self.path = path
    }
    func write(_ buffer: UnsafeRawBufferPointer, at offset: Int64) throws {
        try drive?.write(path: path, buffer: buffer, at: offset)
    }
    func flush() throws -> String? { drive?.warning() }
    func close() throws {}
}
private final class FakeReader: DestinationReader, @unchecked Sendable {
    weak var drive: FakeDrive?
    let path: String
    let size: Int64
    init(drive: FakeDrive, path: String, size: Int64) {
        self.drive = drive
        self.path = path
        self.size = size
    }
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: Int64) throws -> Int {
        try drive?.read(path: path, into: buffer, at: offset) ?? 0
    }
    func close() {}
}
