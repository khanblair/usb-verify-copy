import Foundation
import Testing
import USBVerifyCore

@testable import USBVerify

@Test
func routeTextShowsKnownAndUnknownValuesWithoutInventingFacts() {
    #expect(DrivePresentation.routeText(nil) == "unknown")
    #expect(
        DrivePresentation.routeText(Route(protocolName: "USB", hubInPath: false, speedMbps: 5_000))
            == "USB, direct, USB 3 (5 Gbps)")
    #expect(
        DrivePresentation.routeText(Route(protocolName: "USB", hubInPath: true, speedMbps: 480))
            == "USB, via hub, USB 2 (480 Mbps)")
    #expect(
        DrivePresentation.routeText(Route(protocolName: "", hubInPath: nil, speedMbps: nil))
            == "unknown, unknown, unknown")
}

@Test
func verifyOnlyMatchesByNameAndReportsUnmatchedFiles() {
    let matches = VerifyOnlyPlanner.matches(
        sourcePaths: ["/tmp/alpha.txt", "/tmp/missing.txt"],
        destinationFolder: "checks",
        driveNames: ["alpha.txt"])

    #expect(matches.map(\.isMatched) == [true, false])
    #expect(matches[0].name == "alpha.txt")
    #expect(matches[1].name == "missing.txt")
}

@Test
func historyFilteringAndRouteComparisonUsePlainText() {
    let route = Route(protocolName: "USB", hubInPath: true, speedMbps: 480)
    let passed = RunRecord(
        startedAt: Date(), endedAt: Date(), kind: .copy, mode: .strict, driveName: "Khan",
        volumeUUID: "one", filesystem: "exFAT", macOSVersion: "27", route: route,
        sizeBytes: 1, chunkSize: 1, retries: 0, result: "PASS")
    let failed = RunRecord(
        startedAt: Date(), endedAt: Date(), kind: .copy, mode: .strict, driveName: "Other",
        volumeUUID: "two", filesystem: "exFAT", macOSVersion: "27", route: route,
        sizeBytes: 1, chunkSize: 1, retries: 2, result: "FAIL")
    let filtered = HistoryPresentation.filtered([passed, failed], result: "PASS", driveName: "Khan")
    #expect(filtered.map(\.runID) == [passed.runID])

    let summary = RouteSummary(routeKey: route.key, route: route, total: 5, passed: 2, failed: 3)
    #expect(DrivePresentation.routeComparison(summary) == "via hub: 3 of 5 failed")
}

@Test
func menuBarStatusNamesEveryImportantState() {
    let snapshot = ProgressSnapshot(
        fileIndex: 0, fileCount: 1, fileName: "file", phase: .copying,
        fileBytesDone: 50, fileBytesTotal: 100, chunksVerified: 1, chunksRetried: 0,
        bytesPerSecond: 1, secondsRemaining: nil, batchBytesDone: 50, batchBytesTotal: 100)
    #expect(MenuBarPresentation.status(snapshot: nil, phase: nil, mostRecentResult: nil) == "Idle")
    #expect(MenuBarPresentation.status(snapshot: snapshot, phase: .copying, mostRecentResult: nil) == "Copying 50%")
    #expect(MenuBarPresentation.status(snapshot: snapshot, phase: .finalCheck, mostRecentResult: nil) == "Verifying")
    #expect(MenuBarPresentation.status(snapshot: nil, phase: .paused, mostRecentResult: nil) == "Paused")
    #expect(MenuBarPresentation.status(snapshot: nil, phase: nil, mostRecentResult: "PASS") == "PASS")
}

@Test
func cleanupConfirmationDoesNotDeleteUntilConfirmed() throws {
    let root = (NSTemporaryDirectory() as NSString).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: root) }
    let dotFile = (root as NSString).appendingPathComponent("._file")
    try Data([1]).write(to: URL(fileURLWithPath: dotFile))
    let confirmation = CleanupConfirmation(root: root, paths: [dotFile])

    #expect(FileManager.default.fileExists(atPath: dotFile))
    _ = DotCleaner.delete([], within: confirmation.root)
    #expect(FileManager.default.fileExists(atPath: dotFile))
    _ = DotCleaner.delete(confirmation.paths, within: confirmation.root)
    #expect(!FileManager.default.fileExists(atPath: dotFile))
}
