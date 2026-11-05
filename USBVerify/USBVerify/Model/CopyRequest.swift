import Foundation
import USBVerifyCore

struct CopyRequest: Sendable {
    var volume: Volume
    var destinationFolder: String
    var sourcePaths: [String]
    var mode: VerifyMode = .strict
    var conflicts: [String: ConflictChoice] = [:]
    var removeDotFilesAfter = false
}

enum ConflictChoice: String, CaseIterable, Sendable {
    case replace
    case skip
    case keepBoth
}

struct PlannedJob: Sendable {
    let job: PersistedJob
    let report: PreflightReport
}

enum CopyPlanner {
    static func plan(request: CopyRequest, io: any DriveIO) throws -> PlannedJob {
        var files: [PreflightFile] = []
        var states: [FileJobState] = []
        for path in request.sourcePaths {
            let source = try io.openSource(path: path)
            defer { source.close() }
            let original = URL(fileURLWithPath: path).lastPathComponent
            let choice = request.conflicts[original]
            let name = destinationName(
                original: original, choice: choice, io: io, volume: request.volume,
                folder: request.destinationFolder)
            files.append(PreflightFile(sourcePath: path, size: source.identity.size, destinationName: name))
            states.append(
                FileJobState(
                    sourcePath: path, destinationFolder: request.destinationFolder, finalName: name,
                    tempName: name + Defaults.tempSuffix, chunkSize: Defaults.chunkSize,
                    sourceIdentity: source.identity, phase: .queued,
                    result: choice == .skip ? .skipped(reason: "Already present") : nil,
                    replaceExisting: choice == .replace))
        }
        let report = Preflight.check(volume: request.volume, files: files)
        return PlannedJob(
            job: PersistedJob(mode: request.mode, volumeID: request.volume.id, files: states), report: report)
    }

    private static func destinationName(
        original: String, choice: ConflictChoice?, io: any DriveIO,
        volume: Volume, folder: String
    ) -> String {
        guard choice == .keepBoth else { return original }
        let guardrail = DestinationGuard(volume: volume)
        var index = 2
        while let path = try? guardrail.path(folder: folder, name: numberedName(original, index)),
            io.fileSize(path: path) != nil
        {
            index += 1
        }
        return numberedName(original, index)
    }

    private static func numberedName(_ name: String, _ index: Int) -> String {
        let url = URL(fileURLWithPath: name)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let suffix = " (index)"
        return ext.isEmpty ? stem + suffix : stem + suffix + "." + ext
    }
}
