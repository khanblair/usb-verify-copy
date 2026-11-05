import Foundation
import Testing

@testable import USBVerifyCore

@Suite struct DotCleanerTests {
    private func makeTempDir() throws -> String {
        let unique = "USBVerifyTest-Cleanup-\(UUID().uuidString)"
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent(unique)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @Test func scanMissingRootReturnsEmpty() {
        let missing = (NSTemporaryDirectory() as NSString).appendingPathComponent("missing-\(UUID().uuidString)")
        let result = DotCleaner.scan(root: missing)
        #expect(result.isEmpty)
    }

    @Test func scanFindsDotFilesAcrossNestedFolders() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let sub1 = (root as NSString).appendingPathComponent("folder1")
        let sub2 = (sub1 as NSString).appendingPathComponent("folder2")
        try FileManager.default.createDirectory(atPath: sub2, withIntermediateDirectories: true)

        let dotRoot = (root as NSString).appendingPathComponent("._file1.txt")
        let normalRoot = (root as NSString).appendingPathComponent("file1.txt")
        let dotSub1 = (sub1 as NSString).appendingPathComponent("._file2.pkg")
        let dotSub2 = (sub2 as NSString).appendingPathComponent("._file3.bin")
        let normalSub2 = (sub2 as NSString).appendingPathComponent("file3.bin")

        try "data".write(toFile: dotRoot, atomically: true, encoding: .utf8)
        try "data".write(toFile: normalRoot, atomically: true, encoding: .utf8)
        try "data".write(toFile: dotSub1, atomically: true, encoding: .utf8)
        try "data".write(toFile: dotSub2, atomically: true, encoding: .utf8)
        try "data".write(toFile: normalSub2, atomically: true, encoding: .utf8)

        let scanned = DotCleaner.scan(root: root)
        #expect(scanned.count == 3)
        #expect(scanned == [dotRoot, dotSub1, dotSub2].sorted())
    }

    @Test func scanIgnoresSymlinkPointingOutside() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let outsideDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: outsideDir) }

        let outsideTarget = (outsideDir as NSString).appendingPathComponent("target.txt")
        try "outside data".write(toFile: outsideTarget, atomically: true, encoding: .utf8)

        // Symlink inside root named ._symlink pointing outside
        let symlinkPath = (root as NSString).appendingPathComponent("._symlink")
        try FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: outsideTarget)

        // Regular dot file
        let regularDot = (root as NSString).appendingPathComponent("._valid.txt")
        try "data".write(toFile: regularDot, atomically: true, encoding: .utf8)

        let scanned = DotCleaner.scan(root: root)
        #expect(scanned == [regularDot])
        #expect(!scanned.contains(symlinkPath))
    }

    @Test func scanIgnoresDirectoryNamedDotUnderscore() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }

        // Directory named ._dir
        let dirPath = (root as NSString).appendingPathComponent("._dir")
        try FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)

        // Regular dot file inside ._dir
        let innerDotFile = (dirPath as NSString).appendingPathComponent("._inner.txt")
        try "inner".write(toFile: innerDotFile, atomically: true, encoding: .utf8)

        let scanned = DotCleaner.scan(root: root)
        #expect(!scanned.contains(dirPath))
        #expect(scanned == [innerDotFile])
    }

    @Test func deleteRemovesOnlyValidFilesAndSkipsInvalid() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let outsideDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: outsideDir) }

        // 1. Valid dot file to delete
        let validFile = (root as NSString).appendingPathComponent("._to_delete.txt")
        try "payload".write(toFile: validFile, atomically: true, encoding: .utf8)

        // 2. Normal file (does not start with ._)
        let normalFile = (root as NSString).appendingPathComponent("keep_me.txt")
        try "keep".write(toFile: normalFile, atomically: true, encoding: .utf8)

        // 3. Directory named ._dir (must not be deleted)
        let dirPath = (root as NSString).appendingPathComponent("._dir")
        try FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)

        // 4. Symlink named ._symlink pointing to outside target (must not be deleted)
        let outsideTarget = (outsideDir as NSString).appendingPathComponent("target.txt")
        try "outside content".write(toFile: outsideTarget, atomically: true, encoding: .utf8)
        let symlinkPath = (root as NSString).appendingPathComponent("._symlink")
        try FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: outsideTarget)

        // 5. File outside root
        let outsideDot = (outsideDir as NSString).appendingPathComponent("._outside.txt")
        try "secret".write(toFile: outsideDot, atomically: true, encoding: .utf8)

        let paths = [validFile, normalFile, dirPath, symlinkPath, outsideDot]
        let result = DotCleaner.delete(paths, within: root)

        // Check deleted
        #expect(result.deleted == [validFile])
        #expect(!FileManager.default.fileExists(atPath: validFile))

        // Check skipped
        #expect(result.skipped[normalFile] != nil)
        #expect(FileManager.default.fileExists(atPath: normalFile))

        #expect(result.skipped[dirPath] != nil)
        #expect(FileManager.default.fileExists(atPath: dirPath))

        #expect(result.skipped[symlinkPath] != nil)
        #expect(FileManager.default.fileExists(atPath: symlinkPath))
        #expect(FileManager.default.fileExists(atPath: outsideTarget))

        #expect(result.skipped[outsideDot] != nil)
        #expect(FileManager.default.fileExists(atPath: outsideDot))
    }

    @Test func deleteRejectsPathsOutsideRootUsingParentTraversal() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let outsideDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: outsideDir) }

        let outsideDot = (outsideDir as NSString).appendingPathComponent("._traversal.txt")
        try "sensitive".write(toFile: outsideDot, atomically: true, encoding: .utf8)

        // Construct path escaping root via ..
        let escapedPath = "\(root)/../\( (outsideDir as NSString).lastPathComponent )/._traversal.txt"

        let result = DotCleaner.delete([escapedPath], within: root)
        #expect(result.deleted.isEmpty)
        #expect(result.skipped[escapedPath] != nil)
        #expect(FileManager.default.fileExists(atPath: outsideDot))
    }
}

@Test func deleteRefusesPathThroughSymlinkedFolder() throws {
    let base = NSTemporaryDirectory() + "dotcleaner-symlink-\(UUID().uuidString)"
    let root = base + "/root"
    let outside = base + "/outside"
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: base) }
    try "x".write(toFile: outside + "/._secret", atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(atPath: root + "/linkdir", withDestinationPath: outside)

    let result = DotCleaner.delete([root + "/linkdir/._secret"], within: root)

    #expect(result.deleted.isEmpty)
    #expect(FileManager.default.fileExists(atPath: outside + "/._secret"))
}
