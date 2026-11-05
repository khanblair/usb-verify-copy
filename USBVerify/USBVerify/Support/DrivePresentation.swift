import Foundation
import USBVerifyCore

enum DrivePresentation {
    static func routeText(_ route: Route?) -> String {
        guard let route else { return "unknown" }
        let protocolName = route.protocolName.isEmpty ? "unknown" : route.protocolName
        let path: String
        if let hub = route.hubInPath {
            path = hub ? "via hub" : "direct"
        } else {
            path = "unknown"
        }
        let speed: String
        if let speedMbps = route.speedMbps {
            speed =
                speedMbps >= 5_000
                ? "USB 3 (\(speedMbps / 1_000) Gbps)"
                : "USB 2 (\(speedMbps) Mbps)"
        } else {
            speed = "unknown"
        }
        return "\(protocolName), \(path), \(speed)"
    }

    static func volumeProblem(_ volume: Volume) -> String? {
        if volume.isReadOnly { return "This drive is read-only." }
        if !volume.filesystem.isCopyTarget {
            return "This drive uses \(volume.filesystem.displayName). Only exFAT and FAT32 drives can be used."
        }
        return nil
    }

    static func capacityVerdict(_ verdict: CapacityVerdict) -> String {
        switch verdict {
        case .genuine: return "Genuine capacity"
        case .fakeCapacitySuspected: return "Fake capacity suspected"
        case .failing: return "Drive is failing"
        case .inconclusive: return "Test inconclusive"
        }
    }

    static func routeComparison(_ summary: RouteSummary) -> String {
        let route = summary.route?.hubInPath == true ? "via hub" : "direct"
        return "\(route): \(summary.failed) of \(summary.total) failed"
    }
}

enum MenuBarPresentation {
    static func status(
        snapshot: ProgressSnapshot?,
        phase: JobPhase?,
        mostRecentResult: String?
    ) -> String {
        if let snapshot {
            if phase == .finalCheck || phase == .remounting {
                return "Verifying"
            }
            guard snapshot.fileBytesTotal > 0 else { return "Copying" }
            let percent = Int(snapshot.fileBytesDone * 100 / snapshot.fileBytesTotal)
            return "Copying \(percent)%"
        }
        if phase == .paused { return "Paused" }
        if let mostRecentResult { return mostRecentResult }
        return "Idle"
    }

    static func symbol(phase: JobPhase?, hasActiveSnapshot: Bool) -> String {
        if phase == .paused { return "pause.circle" }
        if hasActiveSnapshot { return "arrow.triangle.2.circlepath" }
        return "externaldrive"
    }
}

enum HistoryPresentation {
    static func filtered(
        _ records: [RunRecord],
        result: String?,
        driveName: String?
    ) -> [RunRecord] {
        records.filter { record in
            let resultMatches = result == nil || record.result == result
            let driveMatches = driveName == nil || record.driveName == driveName
            return resultMatches && driveMatches
        }
    }

    static func badRangeText(_ range: BadRange) -> String {
        "Offset \(Formatting.hex(range.offset)), length \(Formatting.hex(range.length)) (\(range.length) bytes)"
    }
}
