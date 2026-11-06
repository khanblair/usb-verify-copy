import Foundation
import Testing

@testable import USBVerifyCore

private func temporaryFolder() throws -> String {
    let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("USBVerifyCore-\(UUID().uuidString)")
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

@Test func fakeDriveRoundTripAndFaults() throws {
    let drive = FakeDrive(mountPath: "/Volumes/Test", capacityBytes: 32)
    let path = "/Volumes/Test/file.bin"
    let writer = try drive.createWriter(path: path, truncate: true)
    let input: [UInt8] = [1, 2, 3, 4]
    try input.withUnsafeBytes { try writer.write($0, at: 0) }
    #expect(drive.contents(of: path) == input)
    drive.flipByteOnWrite(fileOffset: 1, times: 1)
    try [UInt8(9), 8].withUnsafeBytes { try writer.write($0, at: 1) }
    #expect(drive.contents(of: path) == [1, 8, 8, 4])
    drive.dropCaches()
    #expect(drive.readCount == 0)
    try writer.close()
}

@Test func fakeDriveCapacityRenameAndUnplug() throws {
    let drive = FakeDrive(mountPath: "/Volumes/Test", capacityBytes: 3)
    let source = "/Volumes/Test/a"
    let writer = try drive.createWriter(path: source, truncate: true)
    try [UInt8(1), 2, 3].withUnsafeBytes { try writer.write($0, at: 0) }
    #expect(throws: VerifyError.noSpace(needed: 1, available: 0)) {
        try [UInt8(4)].withUnsafeBytes { try writer.write($0, at: 3) }
    }
    try drive.rename(from: source, to: "/Volumes/Test/b")
    #expect(drive.contents(of: "/Volumes/Test/b") == [1, 2, 3])
    drive.isUnplugged = true
    #expect(throws: VerifyError.driveDisconnected(atOffset: 0)) { try drive.freeSpace(path: "/Volumes/Test/b") }
}

@Test func posixDriveRoundTripAndFileOperations() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(atPath: folder) }
    let path = (folder as NSString).appendingPathComponent("a.bin")
    let renamed = (folder as NSString).appendingPathComponent("b.bin")
    let drive = PosixDriveIO()
    let writer = try drive.createWriter(path: path, truncate: true)
    try [UInt8(10), 20, 30].withUnsafeBytes { try writer.write($0, at: 0) }
    _ = try writer.flush()
    try writer.close()
    #expect(drive.fileSize(path: path) == 3)
    let reader = try drive.openReader(path: path)
    var bytes = [UInt8](repeating: 0, count: 5)
    let count = try bytes.withUnsafeMutableBytes { try reader.read(into: $0, at: 0) }
    #expect(count == 3)
    #expect(Array(bytes.prefix(3)) == [10, 20, 30])
    reader.close()
    try drive.rename(from: path, to: renamed)
    #expect(drive.fileSize(path: path) == nil)
    try drive.removeFile(path: renamed)
    #expect(drive.fileSize(path: renamed) == nil)
    #expect(try drive.freeSpace(path: folder) > 0)
}

@Test
func posixDescriptorsUseNoCacheAndReadsStopAtEnd() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(atPath: folder) }
    let path = (folder as NSString).appendingPathComponent("data.bin")
    let drive = PosixDriveIO()
    let writer = try drive.createWriter(path: path, truncate: true)
    try [UInt8(1), 2, 3].withUnsafeBytes { try writer.write($0, at: 0) }
    try writer.close()

    #expect(try drive.sourceHasNoCache(path: path))
    #expect(try drive.writerHasNoCache(path: path))
    #expect(try drive.readerHasNoCache(path: path))
    let source = try drive.openSource(path: path)
    var bytes = [UInt8](repeating: 0, count: 5)
    let short = try bytes.withUnsafeMutableBytes { try source.read(into: $0, at: 0) }
    let past = try bytes.withUnsafeMutableBytes { try source.read(into: $0, at: 3) }
    source.close()
    #expect(short == 3)
    #expect(past == 0)
}

@Test
func truncateFalseKeepsContentAndRenameReplacesExisting() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(atPath: folder) }
    let first = (folder as NSString).appendingPathComponent("first.bin")
    let second = (folder as NSString).appendingPathComponent("second.bin")
    let drive = PosixDriveIO()
    let writer = try drive.createWriter(path: first, truncate: true)
    try [UInt8(1), 2, 3].withUnsafeBytes { try writer.write($0, at: 0) }
    try writer.close()
    let appendWriter = try drive.createWriter(path: first, truncate: false)
    try [UInt8(9)].withUnsafeBytes { try appendWriter.write($0, at: 3) }
    try appendWriter.close()
    let existing = try drive.createWriter(path: second, truncate: true)
    try [UInt8(8)].withUnsafeBytes { try existing.write($0, at: 0) }
    try existing.close()

    try drive.rename(from: first, to: second)
    #expect(drive.fileSize(path: first) == nil)
    #expect(drive.fileSize(path: second) == 4)
}

@Test
func posixErrorMappingCoversKnownAndUnknownErrors() {
    let drive = PosixDriveIO()
    #expect(drive.mapError(operation: "write", code: ENOSPC, path: "x", offset: 0) == .noSpace(needed: 0, available: 0))
    #expect(drive.mapError(operation: "open", code: EACCES, path: "x", offset: 0) == .permissionDenied(path: "x"))
    #expect(drive.mapError(operation: "read", code: EIO, path: "x", offset: 4) == .driveDisconnected(atOffset: 4))
    #expect(drive.mapError(operation: "read", code: 12345, path: "x", offset: 4) == .io(operation: "read", code: 12345))
}

@Test func posixCreateDirectoryMakesNestedFoldersAndIsRepeatable() throws {
    let base = NSTemporaryDirectory() + "mkdir-test-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: base) }
    let io = PosixDriveIO()
    let nested = base + "/a/b/c"
    try io.createDirectory(path: nested)
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: nested, isDirectory: &isDirectory) && isDirectory.boolValue)
    // A second call on an existing folder must succeed.
    try io.createDirectory(path: nested)
    // A copy into a folder that did not exist before now works end to end.
    let writer = try io.createWriter(path: nested + "/file.bin", truncate: true)
    try writer.close()
    #expect(io.fileSize(path: nested + "/file.bin") == 0)
}
