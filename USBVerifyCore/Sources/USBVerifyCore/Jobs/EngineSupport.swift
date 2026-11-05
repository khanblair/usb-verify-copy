import Foundation

/// Facts about this run that go into the history record.
public struct RunEnvironment: Sendable {
    public var macOSVersion: String
    public var filesystemDriver: String?
    public var route: Route?
    public init(macOSVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
                filesystemDriver: String? = nil, route: Route? = nil) {
        self.macOSVersion = macOSVersion
        self.filesystemDriver = filesystemDriver
        self.route = route
    }
}

/// Time hooks, so tests run without waiting and can fake slow or fast drives.
public struct EngineClock: Sendable {
    public var now: @Sendable () -> Double
    public var sleep: @Sendable (Double) async -> Void
    public init(now: @escaping @Sendable () -> Double, sleep: @escaping @Sendable (Double) async -> Void) {
        self.now = now
        self.sleep = sleep
    }
    public static let system = EngineClock(
        now: { ProcessInfo.processInfo.systemUptime },
        sleep: { seconds in try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000)) }
    )
}

public enum JobFactory {
    /// Builds the per-file state for a copy. Reads the source identity now; a later change means FAIL.
    public static func fileState(sourcePath: String, destinationFolder: String, finalName: String,
                                 chunkSize: Int = Defaults.chunkSize, replaceExisting: Bool = false,
                                 io: any DriveIO) throws -> FileJobState {
        let source = try io.openSource(path: sourcePath)
        defer { source.close() }
        return FileJobState(sourcePath: sourcePath, destinationFolder: destinationFolder, finalName: finalName,
                            tempName: finalName + Defaults.tempSuffix, chunkSize: chunkSize,
                            sourceIdentity: source.identity, replaceExisting: replaceExisting)
    }

    public static func job(volume: Volume, mode: VerifyMode, files: [FileJobState]) -> PersistedJob {
        PersistedJob(kind: .copy, mode: mode, volumeID: volume.id, files: files)
    }
}

enum FileRunOutcome: Equatable {
    case finished(FileResult)
    case paused(PauseReason, atOffset: Int64)
}

enum Interrupt: Error {
    case pause(PauseReason, atOffset: Int64)
    case cancel
}
