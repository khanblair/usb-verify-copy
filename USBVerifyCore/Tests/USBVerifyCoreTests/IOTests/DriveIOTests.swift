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
