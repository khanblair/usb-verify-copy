import Foundation
import USBVerifyCore

struct VerifyOnlyRequest: Sendable {
    var volume: Volume
    var sourcePaths: [String]
    var destinationFolder: String
}

struct VerifyOnlyMatch: Equatable, Sendable {
    var sourcePath: String
    var name: String
    var destinationFolder: String
    var isMatched: Bool
}

enum VerifyOnlyPlanner {
    static func matches(
        sourcePaths: [String],
        destinationFolder: String,
        driveNames: Set<String>
    ) -> [VerifyOnlyMatch] {
        sourcePaths.map { path in
            let name = URL(fileURLWithPath: path).lastPathComponent
            return VerifyOnlyMatch(
                sourcePath: path,
                name: name,
                destinationFolder: destinationFolder,
                isMatched: driveNames.contains(name))
        }
    }
}

struct FormatRequest: Sendable {
    var volume: Volume
    var label = ""
    var confirmation = ""
}

struct CapacityRequest: Sendable {
    enum Mode: String, CaseIterable, Sendable {
        case freeSpaceOnly
        case wholeDrive
    }

    var volume: Volume
    var mode: Mode = .freeSpaceOnly
    var config = CapacityConfig()
}

struct CleanupConfirmation: Equatable, Sendable {
    var root: String
    var paths: [String]
}

enum FormatRetryPolicy {
    static func isPermissionFailure(_ error: VerifyError) -> Bool {
        guard case .commandFailed(_, let output) = error else { return false }
        let text = output.lowercased()
        return text.contains("permission") || text.contains("privilege") || text.contains("operation not permitted")
    }
}

struct FormatCoordinator: Sendable {
    let volumeControl: any VolumeControl

    func erase(
        confirmed: Volume,
        fresh: Volume?,
        busyVolumes: Set<VolumeID>,
        label: String,
        useAdminAfterPermissionFailure: Bool
    ) async throws -> String {
        try FormatPlan.checkBeforeErase(confirmed: confirmed, fresh: fresh, busyVolumes: busyVolumes)
        _ = try FormatPlan.arguments(wholeDisk: confirmed.wholeDiskBSDName, label: label)
        do {
            return try await volumeControl.eraseExFATWithMBR(
                wholeDisk: confirmed.wholeDiskBSDName,
                label: label,
                privilege: .user)
        } catch let error as VerifyError
            where FormatRetryPolicy.isPermissionFailure(error) && useAdminAfterPermissionFailure
        {
            return try await volumeControl.eraseExFATWithMBR(
                wholeDisk: confirmed.wholeDiskBSDName,
                label: label,
                privilege: .admin)
        }
    }
}
