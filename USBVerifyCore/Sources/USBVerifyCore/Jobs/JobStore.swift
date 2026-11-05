import Foundation

/// Reads and writes job state files (spec section 10). Every save is atomic, so a crash never leaves half a file.
public struct JobStore: Sendable {
    public let directory: String

    public init(directory: String) {
        self.directory = directory
    }

    private func url(for id: String) -> URL {
        URL(fileURLWithPath: directory).appendingPathComponent("\(id).json")
    }

    public func save(_ job: PersistedJob) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(job).write(to: url(for: job.id), options: .atomic)
    }

    public func load(id: String) throws -> PersistedJob? {
        let target = url(for: id)
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        return try JSONDecoder().decode(PersistedJob.self, from: Data(contentsOf: target))
    }

    /// All readable jobs, oldest first. A corrupt file is skipped, not fatal.
    public func loadAll() throws -> [PersistedJob] {
        guard FileManager.default.fileExists(atPath: directory) else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory)
        var jobs: [PersistedJob] = []
        for name in names where name.hasSuffix(".json") {
            let file = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if let data = try? Data(contentsOf: file), let job = try? JSONDecoder().decode(PersistedJob.self, from: data) {
                jobs.append(job)
            }
        }
        return jobs.sorted { $0.createdAt < $1.createdAt }
    }

    public func delete(id: String) throws {
        let target = url(for: id)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
    }
}
