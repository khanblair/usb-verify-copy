import Foundation
import USBVerifyCore

public enum Console {
    public static func progressLine(_ snapshot: ProgressSnapshot) -> String {
        let percent =
            snapshot.fileBytesTotal == 0
            ? 100 : Int(Double(snapshot.fileBytesDone) * 100 / Double(snapshot.fileBytesTotal))
        let speed =
            snapshot.bytesPerSecond > 0
            ? String(format: "%.1f MB/s", snapshot.bytesPerSecond / 1_000_000) : "unknown MB/s"
        let left = snapshot.secondsRemaining.map { "\(Int(max(0, $0)))s left" } ?? "time left unknown"
        return
            "\(snapshot.phase.rawValue) \(percent)% \(speed), \(left), chunks \(snapshot.chunksVerified) verified, \(snapshot.chunksRetried) retried, file \(snapshot.fileIndex + 1) of \(snapshot.fileCount)"
    }

    /// What to tell the person when a job pauses. The reason decides the wording.
    public static func pausedText(reason: PauseReason, offset: Int64) -> String {
        switch reason {
        case .driveDisconnected:
            return "Drive disconnected at byte \(offset). Reconnect it, then resume."
        case .appQuit:
            return "Stopped at byte \(offset). Progress is saved."
        case .wake:
            return "The Mac woke from sleep at byte \(offset). Stopped in case the drive lost power."
        }
    }

    public static func resultText(name: String, result: FileResult) -> String {
        switch result {
        case .passed(let source, let reread):
            return
                "PASS \(name)\nsource hash: \(source)\nre-read hash: \(reread)\nThe file on the drive matches the source."
        case .failed(let reason, let ranges):
            let values = ranges.map { "offset 0x\(String($0.offset, radix: 16)) (\($0.offset)), length \($0.length)" }
                .joined(separator: "; ")
            return
                "FAIL \(name): \(reason.rawValue)\(values.isEmpty ? "" : " [\(values)]")\nThe file on the drive does NOT match the source."
        case .skipped(let reason): return "SKIPPED \(name): \(reason)"
        case .cancelled: return "PAUSED \(name)"
        }
    }

    public static func route(_ route: Route?) -> String {
        guard let route else { return "protocol unknown, connection unknown, speed unknown" }
        let connection = route.hubInPath.map { $0 ? "via hub or adapter" : "direct" } ?? "connection unknown"
        let speed = route.speedMbps.map { "\($0) Mbps" } ?? "unknown"
        return "\(route.protocolName), \(connection), speed \(speed)"
    }
}
