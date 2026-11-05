import Darwin
import Foundation

public actor RunLog: RunSink {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    public func record(_ run: RunRecord) async {
        let block = Self.format(run)
        Self.append(text: block, to: path)
    }

    static func format(_ run: RunRecord) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]

        var lines: [String] = []
        lines.append("=== Run \(run.runID) ===")
        lines.append("Start time: \(formatter.string(from: run.startedAt))")
        lines.append("End time: \(formatter.string(from: run.endedAt))")
        lines.append("Result: \(run.result)")
        lines.append("Drive name: \(run.driveName)")

        if let driver = run.filesystemDriver {
            lines.append("Filesystem and driver: \(run.filesystem) (\(driver))")
        } else {
            lines.append("Filesystem and driver: \(run.filesystem)")
        }

        lines.append("macOS version: \(run.macOSVersion)")
        lines.append("Route key: \(run.route?.key ?? "unknown")")
        lines.append("Source path: \(run.sourcePath ?? "none")")
        lines.append("Destination path: \(run.destinationPath ?? "none")")
        lines.append("Size: \(run.sizeBytes) bytes")
        lines.append("Chunk size: \(run.chunkSize) bytes")
        lines.append("Retries: \(run.retries)")

        if run.badRanges.isEmpty {
            lines.append("Bad ranges: none")
        } else {
            let formattedRanges = run.badRanges.map { range in
                let offHex = String(range.offset, radix: 16)
                let lenHex = String(range.length, radix: 16)
                return "offset 0x\(offHex) (\(range.offset)), length 0x\(lenHex) (\(range.length))"
            }.joined(separator: "; ")
            lines.append("Bad ranges: \(formattedRanges)")
        }

        lines.append("Source hash: \(run.sourceHash ?? "none")")
        lines.append("Re-read hash: \(run.rereadHash ?? "none")")

        if run.notes.isEmpty {
            lines.append("Notes: none")
        } else {
            lines.append("Notes: \(run.notes.joined(separator: "; "))")
        }
        lines.append("")

        return lines.joined(separator: "\n") + "\n"
    }

    private static func append(text: String, to path: String) {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        guard let data = text.data(using: .utf8) else { return }
        let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }

        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let n = Darwin.write(fd, base.advanced(by: written), rawBuffer.count - written)
                if n <= 0 { break }
                written += n
            }
        }
    }
}
