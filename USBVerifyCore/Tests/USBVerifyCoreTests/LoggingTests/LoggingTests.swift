import Foundation
import Testing

@testable import USBVerifyCore

@Suite struct LoggingTests {
    private func makeTempDir() throws -> String {
        let unique = "USBVerifyTest-Logging-\(UUID().uuidString)"
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent(unique)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func makeRecord(
        runID: String = UUID().uuidString,
        result: String = "PASS",
        route: Route? = Route(
            protocolName: "USB", hubInPath: true, hubDepth: 1, speedMbps: 480, portLocation: "Port 1"),
        badRanges: [BadRange] = []
    ) -> RunRecord {
        RunRecord(
            runID: runID,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_060),
            kind: .copy,
            mode: .strict,
            driveName: "Khan",
            volumeUUID: "1234-5678",
            model: "Samsung T7",
            filesystem: "exFAT",
            filesystemDriver: "fskit",
            macOSVersion: "27.2",
            route: route,
            sourcePath: "/Users/blair/game.pkg",
            destinationPath: "/Volumes/Khan/game.pkg",
            sizeBytes: 1_048_576,
            chunkSize: 67_108_864,
            retries: 1,
            badRanges: badRanges,
            fullSyncWarnings: [],
            sourceHash: "abc123def456",
            rereadHash: "abc123def456",
            result: result,
            notes: ["First run", "Clean test"]
        )
    }

    @Test func historyStoreRoundTrip() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let historyPath = (tempDir as NSString).appendingPathComponent("history.jsonl")
        let store = HistoryStore(path: historyPath)

        let initial = try await store.loadAll()
        #expect(initial.isEmpty)

        let record1 = makeRecord(runID: "run-1", result: "PASS")
        let record2 = makeRecord(runID: "run-2", result: "FAIL", badRanges: [BadRange(offset: 4096, length: 16384)])

        await store.record(record1)
        await store.record(record2)

        let loaded = try await store.loadAll()
        #expect(loaded.count == 2)
        #expect(loaded[0].runID == "run-1")
        #expect(loaded[0].result == "PASS")
        #expect(loaded[1].runID == "run-2")
        #expect(loaded[1].result == "FAIL")
        #expect(loaded[1].badRanges == [BadRange(offset: 4096, length: 16384)])
    }

    @Test func historyStoreCorruptJSONLine() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let historyPath = (tempDir as NSString).appendingPathComponent("history.jsonl")
        let store = HistoryStore(path: historyPath)

        let record1 = makeRecord(runID: "run-1", result: "PASS")
        let record2 = makeRecord(runID: "run-2", result: "PASS")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let json1 = try String(decoding: encoder.encode(record1), as: UTF8.self)
        let json2 = try String(decoding: encoder.encode(record2), as: UTF8.self)

        let content = "\(json1)\n\n{ corrupt json line !!\n   \n\(json2)\n"
        try content.write(toFile: historyPath, atomically: true, encoding: .utf8)

        let loaded = try await store.loadAll()
        #expect(loaded.count == 2)
        #expect(loaded[0].runID == "run-1")
        #expect(loaded[1].runID == "run-2")
    }

    @Test func historyStoreConcurrentAppends() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let historyPath = (tempDir as NSString).appendingPathComponent("history.jsonl")
        let store = HistoryStore(path: historyPath)

        let count = 25
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                group.addTask {
                    let record = self.makeRecord(runID: "run-\(i)", result: i % 2 == 0 ? "PASS" : "FAIL")
                    await store.record(record)
                }
            }
        }

        let loaded = try await store.loadAll()
        #expect(loaded.count == count)
        let ids = Set(loaded.map(\.runID))
        #expect(ids.count == count)
    }

    @Test func historyStoreDoesNotCorruptEarlierUnterminatedLine() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let historyPath = (tempDir as NSString).appendingPathComponent("history.jsonl")
        let store = HistoryStore(path: historyPath)

        // Write an incomplete line without trailing newline
        try "partial-line".write(toFile: historyPath, atomically: true, encoding: .utf8)

        let record = makeRecord(runID: "run-proper")
        await store.record(record)

        let fileData = try Data(contentsOf: URL(fileURLWithPath: historyPath))
        let fileText = String(decoding: fileData, as: UTF8.self)
        let lines = fileText.components(separatedBy: "\n").filter { !$0.isEmpty }

        #expect(lines.count == 2)
        #expect(lines[0] == "partial-line")
        let loaded = try await store.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded[0].runID == "run-proper")
    }

    @Test func runLogAppendsHumanReadableBlock() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        // Test creation of nested parent folders
        let logPath = "\(tempDir)/nested/usb-verify.log"
        let log = RunLog(path: logPath)

        let record = makeRecord(
            runID: "test-run-123",
            result: "FAIL",
            badRanges: [BadRange(offset: 4096, length: 16384)]
        )

        await log.record(record)

        let text = try String(contentsOfFile: logPath, encoding: .utf8)
        #expect(text.contains("=== Run test-run-123 ==="))
        #expect(text.contains("Start time: 2023-11-14T22:13:20Z"))
        #expect(text.contains("End time: 2023-11-14T22:14:20Z"))
        #expect(text.contains("Result: FAIL"))
        #expect(text.contains("Drive name: Khan"))
        #expect(text.contains("Filesystem and driver: exFAT (fskit)"))
        #expect(text.contains("macOS version: 27.2"))
        #expect(text.contains("Route key: USB|hub|480Mbps|Port 1"))
        #expect(text.contains("Source path: /Users/blair/game.pkg"))
        #expect(text.contains("Destination path: /Volumes/Khan/game.pkg"))
        #expect(text.contains("Size: 1048576 bytes"))
        #expect(text.contains("Chunk size: 67108864 bytes"))
        #expect(text.contains("Retries: 1"))
        #expect(text.contains("Bad ranges: offset 0x1000 (4096), length 0x4000 (16384)"))
        #expect(text.contains("Source hash: abc123def456"))
        #expect(text.contains("Re-read hash: abc123def456"))
        #expect(text.contains("Notes: First run; Clean test"))
    }

    @Test func runLogConcurrentAppends() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let logPath = (tempDir as NSString).appendingPathComponent("concurrent.log")
        let log = RunLog(path: logPath)

        let count = 20
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                group.addTask {
                    let record = self.makeRecord(runID: "concurrent-\(i)")
                    await log.record(record)
                }
            }
        }

        let text = try String(contentsOfFile: logPath, encoding: .utf8)
        for i in 0..<count {
            #expect(text.contains("=== Run concurrent-\(i) ==="))
        }
    }

    @Test func routeHistoryGroupingAndSortOrder() {
        let routeDirect = Route(protocolName: "USB", hubInPath: false, speedMbps: 5000, portLocation: "Port 1")
        let routeHub = Route(protocolName: "USB", hubInPath: true, speedMbps: 480, portLocation: "Port 2")

        let runs: [RunRecord] = [
            // Hub: 2 runs, 1 fail, 1 pass -> total 2, failed 1, passed 1
            makeRecord(runID: "1", result: "FAIL", route: routeHub),
            makeRecord(runID: "2", result: "PASS", route: routeHub),

            // Direct: 3 runs, 0 fail, 2 pass, 1 paused -> total 3, failed 0, passed 2
            makeRecord(runID: "3", result: "PASS", route: routeDirect),
            makeRecord(runID: "4", result: "PASS", route: routeDirect),
            makeRecord(runID: "5", result: "PAUSED", route: routeDirect),

            // Unknown route: 2 runs, 2 fail -> total 2, failed 2, passed 0
            makeRecord(runID: "6", result: "FAIL", route: nil),
            makeRecord(runID: "7", result: "FAIL", route: nil),
        ]

        let summaries = RouteHistory.summaries(from: runs)
        #expect(summaries.count == 3)

        // Sorted by failed desc, total desc, routeKey asc
        // 1. unknown has 2 fails
        #expect(summaries[0].routeKey == "unknown")
        #expect(summaries[0].failed == 2)
        #expect(summaries[0].total == 2)
        #expect(summaries[0].passed == 0)

        // 2. hub has 1 fail
        #expect(summaries[1].routeKey == routeHub.key)
        #expect(summaries[1].failed == 1)
        #expect(summaries[1].total == 2)
        #expect(summaries[1].passed == 1)

        // 3. direct has 0 fails
        #expect(summaries[2].routeKey == routeDirect.key)
        #expect(summaries[2].failed == 0)
        #expect(summaries[2].total == 3)
        #expect(summaries[2].passed == 2)
    }

    @Test func compositeRunSinkForwardsInOrder() async throws {
        actor TestSink: RunSink {
            var received: [String] = []
            func record(_ run: RunRecord) async {
                received.append(run.runID)
            }
        }

        let sink1 = TestSink()
        let sink2 = TestSink()
        let composite = CompositeRunSink([sink1, sink2])

        let record = makeRecord(runID: "run-composite")
        await composite.record(record)

        let rec1 = await sink1.received
        let rec2 = await sink2.received
        #expect(rec1 == ["run-composite"])
        #expect(rec2 == ["run-composite"])
    }
}
