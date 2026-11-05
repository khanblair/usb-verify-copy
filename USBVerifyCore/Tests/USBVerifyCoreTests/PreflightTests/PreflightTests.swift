import Testing
@testable import USBVerifyCore

private let gib: Int64 = 1024 * 1024 * 1024

private func makeVolume(
    filesystem: FilesystemKind = .exfat,
    isReadOnly: Bool = false,
    freeBytes: Int64 = 100 * gib,
    mountPath: String = "/Volumes/Khan"
) -> Volume {
    Volume(
        id: VolumeID("AAAA-1111"),
        name: "Khan",
        mountPath: mountPath,
        bsdName: "disk9s1",
        wholeDiskBSDName: "disk9",
        protocolName: "USB",
        filesystem: filesystem,
        totalBytes: 128 * gib,
        freeBytes: freeBytes,
        isReadOnly: isReadOnly
    )
}

private func file(_ name: String, size: Int64 = 1024, source: String = "/Users/blair/Movies") -> PreflightFile {
    PreflightFile(sourcePath: "\(source)/\(name)", size: size, destinationName: name)
}

@Test func validExFATVolumeWithValidFilesIsOK() {
    let report = Preflight.check(volume: makeVolume(), files: [file("game.pkg", size: 5 * gib), file("notes.txt")])
    #expect(report.isOK)
    #expect(report.issues.isEmpty)
    #expect(report.firstError == nil)
}

@Test func emptyBatchOnGoodVolumeIsOK() {
    #expect(Preflight.check(volume: makeVolume(), files: []).isOK)
}

@Test func unsupportedFilesystemIsBatchIssue() {
    let report = Preflight.check(volume: makeVolume(filesystem: .apfs), files: [file("a.txt")])
    #expect(report.issues == [PreflightIssue(fileName: nil, error: .unsupportedFilesystem("APFS"))])
}

@Test func ntfsIsNamedReadOnlyOnMac() {
    let report = Preflight.check(volume: makeVolume(filesystem: .ntfs), files: [])
    #expect(report.firstError == .unsupportedFilesystem("NTFS (read-only on macOS)"))
}

@Test func otherFilesystemUsesGenericName() {
    let report = Preflight.check(volume: makeVolume(filesystem: .other), files: [])
    #expect(report.firstError == .unsupportedFilesystem("an unsupported filesystem"))
}

@Test func fat32IsAcceptedAsCopyTarget() {
    let report = Preflight.check(volume: makeVolume(filesystem: .fat32), files: [file("a.txt")])
    #expect(report.isOK)
}

@Test func readOnlyVolumeIsBatchIssue() {
    let report = Preflight.check(volume: makeVolume(isReadOnly: true), files: [file("a.txt")])
    #expect(report.issues == [PreflightIssue(fileName: nil, error: .readOnlyVolume)])
}

@Test func fat32AtExactLimitIsAllowed() {
    let report = Preflight.check(volume: makeVolume(filesystem: .fat32),
                                 files: [file("max.bin", size: Defaults.fat32MaxFileSize)])
    #expect(report.isOK)
}

@Test func fat32OneByteOverLimitIsRefused() {
    let report = Preflight.check(volume: makeVolume(filesystem: .fat32),
                                 files: [file("big.bin", size: Defaults.fat32MaxFileSize + 1)])
    #expect(report.issues == [PreflightIssue(
        fileName: "big.bin",
        error: .fileTooLargeForFAT32(name: "big.bin", size: Defaults.fat32MaxFileSize + 1))])
}

@Test func largeFileIsFineOnExFAT() {
    let report = Preflight.check(volume: makeVolume(filesystem: .exfat),
                                 files: [file("big.bin", size: 30 * gib)])
    #expect(report.isOK)
}

@Test func invalidFileNameIsRefusedWithReason() {
    let report = Preflight.check(volume: makeVolume(), files: [file("bad:name.txt")])
    #expect(report.issues.count == 1)
    #expect(report.issues.first?.fileName == "bad:name.txt")
    if case .invalidFileName(let name, let reason) = report.firstError {
        #expect(name == "bad:name.txt")
        #expect(reason.contains(":"))
    } else {
        Issue.record("expected invalidFileName, got \(String(describing: report.firstError))")
    }
}

@Test func sourceOnTargetDriveIsRefused() {
    let files = [PreflightFile(sourcePath: "/Volumes/Khan/Games/a.pkg", size: 10, destinationName: "a.pkg")]
    let report = Preflight.check(volume: makeVolume(), files: files)
    #expect(report.issues == [PreflightIssue(
        fileName: "a.pkg",
        error: .sourceOnTargetDrive(path: "/Volumes/Khan/Games/a.pkg"))])
}

@Test func mountPathItselfCountsAsOnTargetDrive() {
    let files = [PreflightFile(sourcePath: "/Volumes/Khan", size: 10, destinationName: "Khan")]
    #expect(Preflight.check(volume: makeVolume(), files: files).firstError == .sourceOnTargetDrive(path: "/Volumes/Khan"))
}

@Test func trailingSlashOnMountPathIsIgnored() {
    let files = [PreflightFile(sourcePath: "/Volumes/Khan/a.pkg", size: 10, destinationName: "a.pkg")]
    let report = Preflight.check(volume: makeVolume(mountPath: "/Volumes/Khan//"), files: files)
    #expect(report.firstError == .sourceOnTargetDrive(path: "/Volumes/Khan/a.pkg"))
}

@Test func similarPrefixIsNotOnTargetDrive() {
    let files = [PreflightFile(sourcePath: "/Volumes/Khan 2/a.pkg", size: 10, destinationName: "a.pkg")]
    #expect(Preflight.check(volume: makeVolume(), files: files).isOK)
}

@Test func rootMountPathMatchesNothing() {
    let files = [PreflightFile(sourcePath: "/Users/blair/a.pkg", size: 10, destinationName: "a.pkg")]
    #expect(Preflight.check(volume: makeVolume(mountPath: "/"), files: files).isOK)
}

@Test func noSpaceIsBatchIssueWithNeededAndAvailable() {
    let report = Preflight.check(volume: makeVolume(freeBytes: 10 * gib),
                                 files: [file("a.pkg", size: 6 * gib), file("b.pkg", size: 6 * gib)])
    #expect(report.issues == [PreflightIssue(fileName: nil, error: .noSpace(needed: 12 * gib, available: 10 * gib))])
}

@Test func exactFitIsAllowed() {
    let report = Preflight.check(volume: makeVolume(freeBytes: 10 * gib),
                                 files: [file("a.pkg", size: 10 * gib)])
    #expect(report.isOK)
}

@Test func reclaimedBytesCountTowardFreeSpace() {
    let volume = makeVolume(freeBytes: 10 * gib)
    let files = [file("a.pkg", size: 12 * gib)]
    #expect(!Preflight.check(volume: volume, files: files).isOK)
    #expect(Preflight.check(volume: volume, files: files, reclaimedBytes: 2 * gib).isOK)
}

@Test func reclaimedBytesDoNotGoBelowZero() {
    let volume = makeVolume(freeBytes: 0)
    #expect(Preflight.check(volume: volume, files: [], reclaimedBytes: 5 * gib).isOK)
}

@Test func reclaimedBytesLargerThanBatchStillPasses() {
    let volume = makeVolume(freeBytes: 1 * gib)
    #expect(Preflight.check(volume: volume, files: [file("a.pkg", size: gib)], reclaimedBytes: 50 * gib).isOK)
}

@Test func duplicateNameIsFlaggedOnSecondFileOnly() {
    let report = Preflight.check(volume: makeVolume(), files: [
        file("Game.pkg", source: "/Users/blair/one"),
        file("Game.pkg", source: "/Users/blair/two"),
    ])
    #expect(report.issues == [PreflightIssue(
        fileName: "Game.pkg",
        error: .invalidFileName(name: "Game.pkg", reason: "Two files in this batch have the same name"))])
}

@Test func duplicateNameIgnoresCase() {
    let report = Preflight.check(volume: makeVolume(), files: [
        file("Game.pkg", source: "/Users/blair/one"),
        file("GAME.PKG", source: "/Users/blair/two"),
    ])
    #expect(report.issues.count == 1)
    #expect(report.issues.first?.fileName == "GAME.PKG")
}

@Test func threeWayDuplicateGivesTwoIssues() {
    let report = Preflight.check(volume: makeVolume(), files: [
        file("x.bin", source: "/a"), file("x.bin", source: "/b"), file("X.bin", source: "/c"),
    ])
    #expect(report.issues.count == 2)
}

@Test func severalViolationsAreAllReported() {
    let volume = makeVolume(filesystem: .fat32, freeBytes: 1024)
    let files = [
        PreflightFile(sourcePath: "/Volumes/Khan/x", size: Defaults.fat32MaxFileSize + 1, destinationName: "a*b.pkg"),
    ]
    let report = Preflight.check(volume: volume, files: files)
    #expect(report.issues.count == 4)
    #expect(report.issues.contains { $0.error == .fileTooLargeForFAT32(name: "a*b.pkg", size: Defaults.fat32MaxFileSize + 1) })
    #expect(report.issues.contains { $0.error == .sourceOnTargetDrive(path: "/Volumes/Khan/x") })
    #expect(report.issues.contains { if case .invalidFileName = $0.error { true } else { false } })
    #expect(report.issues.contains { if case .noSpace = $0.error { true } else { false } })
    #expect(report.firstError == .fileTooLargeForFAT32(name: "a*b.pkg", size: Defaults.fat32MaxFileSize + 1))
}

@Test func batchIssuesComeBeforeFileIssues() {
    let report = Preflight.check(volume: makeVolume(filesystem: .ntfs, isReadOnly: true), files: [file("a.txt")])
    #expect(report.issues.count == 2)
    #expect(report.issues.allSatisfy { $0.fileName == nil })
    #expect(report.firstError == .unsupportedFilesystem("NTFS (read-only on macOS)"))
}
