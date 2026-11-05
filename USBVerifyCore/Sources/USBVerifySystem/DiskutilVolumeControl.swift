import Foundation
import USBVerifyCore

public final class DiskutilVolumeControl: VolumeControl, @unchecked Sendable {
    private let runner: any CommandRunner
    private let lookup: @Sendable (VolumeID) async -> Volume?
    private let lock = NSLock()
    private var cache: [VolumeID: (bsdName: String, wholeDisk: String)] = [:]

    public init(
        runner: any CommandRunner = ProcessCommandRunner(), lookup: @escaping @Sendable (VolumeID) async -> Volume?
    ) {
        self.runner = runner
        self.lookup = lookup
    }

    public func unmount(volume: VolumeID) async throws {
        let info = try await volumeInfo(for: volume)
        let output = try await runDiskutil(["unmount", info.bsdName])
        if output.exitCode != 0 {
            if isUnmountBusy(output.stdout + output.stderr) {
                throw VerifyError.unmountBusy(blockers: parseUnmountBlockers(output.stdout + output.stderr))
            }
            if isDiskGone(output.stdout + output.stderr) {
                throw VerifyError.volumeNotFound(volumeID: volume.uuid)
            }
            throw commandError(["unmount", info.bsdName], output: output)
        }
    }

    public func mount(volume: VolumeID) async throws -> String {
        let info = try await volumeInfo(for: volume)
        let mounted = try await runDiskutil(["mount", info.bsdName])
        try checkSuccess(mounted, arguments: ["mount", info.bsdName], volume: volume)
        let details = try await runDiskutil(["info", "-plist", info.bsdName])
        try checkSuccess(details, arguments: ["info", "-plist", info.bsdName], volume: volume)
        guard let path = parseMountPoint(fromInfoPlist: Data(details.stdout.utf8)) else {
            throw VerifyError.volumeNotFound(volumeID: volume.uuid)
        }
        return path
    }

    public func mountPath(of volume: VolumeID) async -> String? {
        guard let info = cachedInfo(for: volume) else { return nil }
        guard let output = try? await runDiskutil(["info", "-plist", info.bsdName]), output.exitCode == 0 else {
            return nil
        }
        return parseMountPoint(fromInfoPlist: Data(output.stdout.utf8))
    }

    public func eject(volume: VolumeID) async throws {
        let info = try await volumeInfo(for: volume)
        let output = try await runDiskutil(["eject", info.wholeDisk])
        try checkSuccess(output, arguments: ["eject", info.wholeDisk], volume: volume)
    }

    public func eraseExFATWithMBR(wholeDisk: String, label: String, privilege: ErasePrivilege) async throws -> String {
        let arguments = try FormatPlan.arguments(wholeDisk: wholeDisk, label: label)
        try await requireSafeEraseTarget(wholeDisk)
        let output: CommandOutput
        let command: String
        switch privilege {
        case .user:
            command = (["/usr/sbin/diskutil"] + arguments).joined(separator: " ")
            output = try await runner.run("/usr/sbin/diskutil", arguments, timeout: 120)
        case .admin:
            let script = adminCommandScript(arguments: arguments)
            command = "/usr/bin/osascript -e \(script)"
            output = try await runner.run("/usr/bin/osascript", ["-e", script], timeout: 120)
        }
        guard output.exitCode == 0 else {
            throw VerifyError.commandFailed(command: command, output: outputText(output))
        }
        return outputText(output)
    }

    /// Last line of defence for Format: only a whole disk that macOS reports as not internal may be erased.
    private func requireSafeEraseTarget(_ wholeDisk: String) async throws {
        let output = try await runDiskutil(["info", "-plist", wholeDisk])
        guard output.exitCode == 0,
            let plist = try? PropertyListSerialization.propertyList(from: Data(output.stdout.utf8), format: nil)
                as? [String: Any]
        else {
            throw VerifyError.formatRefused(reason: "Could not read the disk information for \(wholeDisk).")
        }
        guard plist["WholeDisk"] as? Bool == true else {
            throw VerifyError.formatRefused(reason: "\(wholeDisk) is not a whole disk.")
        }
        guard plist["Internal"] as? Bool == false else {
            throw VerifyError.formatRefused(reason: "\(wholeDisk) is an internal disk or its type is unknown.")
        }
    }

    /// A fresh lookup wins, because the BSD name can change after a replug (disk9 can become disk10).
    /// The cache is only used while the volume is unmounted and so missing from the catalog.
    private func volumeInfo(for id: VolumeID) async throws -> (bsdName: String, wholeDisk: String) {
        if let volume = await lookup(id) {
            let info = (volume.bsdName, volume.wholeDiskBSDName)
            store(info: info, for: id)
            return info
        }
        if let cached = cachedInfo(for: id) { return cached }
        throw VerifyError.volumeNotFound(volumeID: id.uuid)
    }

    private func store(info: (bsdName: String, wholeDisk: String), for id: VolumeID) {
        lock.lock()
        cache[id] = info
        lock.unlock()
    }

    private func cachedInfo(for id: VolumeID) -> (bsdName: String, wholeDisk: String)? {
        lock.lock()
        defer { lock.unlock() }
        return cache[id]
    }

    private func runDiskutil(_ arguments: [String]) async throws -> CommandOutput {
        try await runner.run("/usr/sbin/diskutil", arguments, timeout: 120)
    }

    private func checkSuccess(_ output: CommandOutput, arguments: [String], volume: VolumeID) throws {
        guard output.exitCode != 0 else { return }
        let text = output.stdout + output.stderr
        if isDiskGone(text) { throw VerifyError.volumeNotFound(volumeID: volume.uuid) }
        throw commandError(arguments, output: output)
    }

    private func commandError(_ arguments: [String], output: CommandOutput) -> VerifyError {
        VerifyError.commandFailed(
            command: (["/usr/sbin/diskutil"] + arguments).joined(separator: " "), output: outputText(output))
    }
}

public func adminCommandScript(arguments: [String]) -> String {
    let command = (["/usr/sbin/diskutil"] + arguments).map(FormatPlan.shellQuoted).joined(separator: " ")
    let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    return "do shell script \"\(escaped)\" with administrator privileges"
}

private func outputText(_ output: CommandOutput) -> String {
    [output.stdout, output.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
}
