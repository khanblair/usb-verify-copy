import Darwin
import Foundation

public actor HistoryStore: RunSink {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    public func record(_ run: RunRecord) async {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(run) else { return }

        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let fd = Darwin.open(path, O_RDWR | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }

        let fileSize = Darwin.lseek(fd, 0, SEEK_END)
        var prefixNewline = false
        if fileSize > 0 {
            var lastByte: UInt8 = 0
            if Darwin.pread(fd, &lastByte, 1, fileSize - 1) == 1 && lastByte != 10 {
                prefixNewline = true
            }
        }

        var lineData = Data()
        if prefixNewline {
            lineData.append(10)
        }
        lineData.append(data)
        lineData.append(10)

        lineData.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let n = Darwin.write(fd, base.advanced(by: written), rawBuffer.count - written)
                if n <= 0 { break }
                written += n
            }
        }
    }

    public func loadAll() throws -> [RunRecord] {
        guard FileManager.default.fileExists(atPath: path) else {
            return []
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let content = String(data: data, encoding: .utf8) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var records: [RunRecord] = []
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let lineData = trimmed.data(using: .utf8) else { continue }
            if let record = try? decoder.decode(RunRecord.self, from: lineData) {
                records.append(record)
            }
        }
        return records
    }
}
