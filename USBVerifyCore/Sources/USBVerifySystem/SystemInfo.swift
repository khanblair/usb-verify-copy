import Foundation
import USBVerifyCore

public enum SystemInfo {
    public static var macOSVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    public static func filesystemDriver(forMountPath path: String, runner: any CommandRunner) async -> String? {
        guard let output = try? await runner.run("/sbin/mount", [], timeout: 10), output.exitCode == 0 else {
            return nil
        }
        return parseFilesystemDriver(output.stdout, mountPath: path)
    }
}

public func parseFilesystemDriver(_ output: String, mountPath: String) -> String? {
    output.split(separator: "\n").compactMap { line -> String? in
        guard let range = line.range(of: " on \(mountPath) ("), line.hasSuffix(")") else { return nil }
        let options = line[range.upperBound..<line.index(before: line.endIndex)]
        return options.split(separator: ",").contains { part in
            part.trimmingCharacters(in: .whitespacesAndNewlines) == "fskit"
        } ? "fskit" : "kernel"
    }.first
}
