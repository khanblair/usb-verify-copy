/// Checks a copy batch before any byte is written (spec section 7).
public enum Preflight {
    /// Checks everything before any byte is written.
    /// `reclaimedBytes` is the size of existing files that the user chose to replace (they free space).
    public static func check(volume: Volume, files: [PreflightFile], reclaimedBytes: Int64 = 0) -> PreflightReport {
        var issues: [PreflightIssue] = []

        if !volume.filesystem.isCopyTarget {
            let name = volume.filesystem == .ntfs ? "NTFS (read-only on macOS)" : volume.filesystem.displayName
            issues.append(PreflightIssue(fileName: nil, error: .unsupportedFilesystem(name)))
        }
        if volume.isReadOnly {
            issues.append(PreflightIssue(fileName: nil, error: .readOnlyVolume))
        }

        let mountPath = trimmedTrailingSlashes(volume.mountPath)
        var seenNames: Set<String> = []

        for file in files {
            let name = file.destinationName

            if volume.filesystem == .fat32 && file.size > Defaults.fat32MaxFileSize {
                issues.append(PreflightIssue(fileName: name,
                                             error: .fileTooLargeForFAT32(name: name, size: file.size)))
            }

            if let reason = FileNameRules.problem(with: name) {
                issues.append(PreflightIssue(fileName: name,
                                             error: .invalidFileName(name: name, reason: reason)))
            }

            if isOnVolume(trimmedTrailingSlashes(file.sourcePath), mountPath: mountPath) {
                issues.append(PreflightIssue(fileName: name, error: .sourceOnTargetDrive(path: file.sourcePath)))
            }

            if !seenNames.insert(name.lowercased()).inserted {
                issues.append(PreflightIssue(fileName: name,
                                             error: .invalidFileName(name: name,
                                                                     reason: "Two files in this batch have the same name")))
            }
        }

        let total = sum(files.map(\.size))
        let needed = max(0, total - max(0, reclaimedBytes))
        if needed > volume.freeBytes {
            issues.append(PreflightIssue(fileName: nil,
                                         error: .noSpace(needed: needed, available: volume.freeBytes)))
        }

        return PreflightReport(issues: issues)
    }

    /// Removes trailing slashes. The root path "/" becomes "".
    private static func trimmedTrailingSlashes(_ path: String) -> String {
        var result = path
        while result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    /// True when the path is the mount path or inside it. An empty mount path matches nothing.
    private static func isOnVolume(_ path: String, mountPath: String) -> Bool {
        guard !mountPath.isEmpty else { return false }
        return path == mountPath || path.hasPrefix(mountPath + "/")
    }

    /// Adds sizes and stops at Int64.max instead of overflowing.
    private static func sum(_ sizes: [Int64]) -> Int64 {
        var total: Int64 = 0
        for size in sizes {
            let (next, overflow) = total.addingReportingOverflow(size)
            if overflow { return Int64.max }
            total = next
        }
        return total
    }
}
