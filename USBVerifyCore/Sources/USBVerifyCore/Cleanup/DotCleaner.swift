import Darwin
import Foundation

public enum DotCleaner {
    /// Regular files named "._*" in `root` and all subfolders. Does not follow symlinks. Sorted by path. Returns [] if root is missing.
    public static func scan(root: String) -> [String] {
        var results: [String] = []
        var st = stat()
        guard lstat(root, &st) == 0 else {
            return []
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else {
            return []
        }
        scanDirectory(path: root, results: &results)
        return results.sorted()
    }

    private static func scanDirectory(path: String, results: inout [String]) {
        guard let dir = opendir(path) else { return }
        defer { closedir(dir) }

        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
            }
            if name == "." || name == ".." || name.isEmpty {
                continue
            }

            let fullPath = path.hasSuffix("/") ? "\(path)\(name)" : "\(path)/\(name)"
            var st = stat()
            guard lstat(fullPath, &st) == 0 else {
                continue
            }

            let fileType = st.st_mode & S_IFMT
            if fileType == S_IFLNK {
                continue
            } else if fileType == S_IFDIR {
                scanDirectory(path: fullPath, results: &results)
            } else if fileType == S_IFREG {
                if name.hasPrefix("._") {
                    results.append(fullPath)
                }
            }
        }
    }

    public struct DeleteResult: Equatable, Sendable {
        public var deleted: [String]
        public var skipped: [String: String]

        public init(deleted: [String] = [], skipped: [String: String] = [:]) {
            self.deleted = deleted
            self.skipped = skipped
        }
    }

    /// Deletes only the given paths. Skips (never deletes) a path that is outside `root`, whose file name does not start with "._", that is not a regular file, or that is a symlink. Does not delete directories.
    public static func delete(_ paths: [String], within root: String) -> DeleteResult {
        var deleted: [String] = []
        var skipped: [String: String] = [:]

        for path in paths {
            if !isInside(path: path, root: root) {
                skipped[path] = "Path is outside root."
                continue
            }

            let fileName = (path as NSString).lastPathComponent
            if !fileName.hasPrefix("._") {
                skipped[path] = "File name does not start with ._"
                continue
            }

            var st = stat()
            if lstat(path, &st) != 0 {
                skipped[path] = "File does not exist."
                continue
            }

            let fileType = st.st_mode & S_IFMT
            if fileType == S_IFLNK {
                skipped[path] = "Path is a symlink."
                continue
            }
            if fileType == S_IFDIR {
                skipped[path] = "Path is a directory."
                continue
            }
            if fileType != S_IFREG {
                skipped[path] = "Path is not a regular file."
                continue
            }

            if Darwin.unlink(path) == 0 {
                deleted.append(path)
            } else {
                let err = errno
                skipped[path] = "Deletion failed (errno \(err))."
            }
        }

        return DeleteResult(deleted: deleted, skipped: skipped)
    }

    /// True when the real location of `path` is inside the real location of `root`.
    /// The parent folder is resolved first, so a symlinked folder inside the root cannot lead outside it.
    private static func isInside(path: String, root: String) -> Bool {
        let realRoot = ((root as NSString).standardizingPath as NSString).resolvingSymlinksInPath
        let rootWithSlash = realRoot.hasSuffix("/") ? realRoot : realRoot + "/"
        let cleanPath = (path as NSString).standardizingPath
        let parent = (cleanPath as NSString).deletingLastPathComponent
        let fileName = (cleanPath as NSString).lastPathComponent
        let realParent = (parent as NSString).resolvingSymlinksInPath
        let resolved = (realParent as NSString).appendingPathComponent(fileName)
        return resolved.hasPrefix(rootWithSlash)
    }
}
