import Foundation
import USBVerifyCore
import USBVerifySystem

struct AppDependencies: Sendable {
    let volumeEvents: any VolumeEvents
    let connectionInfo: any ConnectionInfoProvider
    let volumeControl: any VolumeControl
    let notifier: any Notifier
    let powerGuard: any PowerGuard
    let driveIO: any DriveIO
    let jobStore: JobStore
    let historyStore: HistoryStore
    let runSink: any RunSink

    static func live() -> AppDependencies {
        let connection = IOKitConnectionInfo()
        let events = DiskArbitrationVolumeEvents(connection: connection)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("USBVerify")
        let history = HistoryStore(path: support.appendingPathComponent("history.jsonl").path)
        let log = RunLog(
            path: FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Logs/USBVerify/usb-verify.log").path)
        return AppDependencies(
            volumeEvents: events,
            connectionInfo: connection,
            volumeControl: DiskutilVolumeControl(lookup: { id in
                await events.currentVolumes().first { $0.id == id }
            }),
            notifier: SystemNotifier(),
            powerGuard: ProcessPowerGuard(),
            driveIO: PosixDriveIO(),
            jobStore: JobStore(directory: support.appendingPathComponent("jobs").path),
            historyStore: history,
            runSink: CompositeRunSink([history, log]))
    }

    static func preview() -> AppDependencies {
        let volume = Volume(
            id: VolumeID("preview-drive"), name: "Khan SSD", mountPath: "/tmp/USBVerifyPreview",
            bsdName: "disk9s1", wholeDiskBSDName: "disk9", model: "Portable SSD", protocolName: "USB",
            filesystem: .exfat, totalBytes: 64_000_000_000, freeBytes: 42_000_000_000,
            route: Route(protocolName: "USB", hubInPath: true, hubDepth: 1, speedMbps: 480))
        let history = HistoryStore(path: NSTemporaryDirectory() + "USBVerifyPreviewHistory.jsonl")
        return AppDependencies(
            volumeEvents: PreviewVolumeEvents(volume: volume),
            connectionInfo: PreviewConnectionInfo(route: volume.route),
            volumeControl: PreviewVolumeControl(), notifier: PreviewNotifier(), powerGuard: PreviewPowerGuard(),
            driveIO: PreviewDriveIO(), jobStore: JobStore(directory: NSTemporaryDirectory() + "USBVerifyPreviewJobs"),
            historyStore: history, runSink: history)
    }
}

private struct PreviewVolumeEvents: VolumeEvents {
    let volume: Volume
    func currentVolumes() async -> [Volume] { [volume] }
    func events() -> AsyncStream<VolumeEvent> { AsyncStream { _ in } }
}

private struct PreviewConnectionInfo: ConnectionInfoProvider {
    let route: Route?
    func route(forWholeDisk bsdName: String) async -> Route? { route }
}

private struct PreviewVolumeControl: VolumeControl {
    func unmount(volume: VolumeID) async throws {}
    func mount(volume: VolumeID) async throws -> String { "/tmp/USBVerifyPreview" }
    func mountPath(of volume: VolumeID) async -> String? { "/tmp/USBVerifyPreview" }
    func eject(volume: VolumeID) async throws {}
    func eraseExFATWithMBR(wholeDisk: String, label: String, privilege: ErasePrivilege) async throws -> String {
        "Preview"
    }
}

private struct PreviewNotifier: Notifier {
    func notify(title: String, body: String) async {}
}

private final class PreviewPowerGuard: PowerGuard, @unchecked Sendable {
    var isOnBattery: Bool { false }
    func begin(reason: String) -> any PowerToken { PreviewPowerToken() }
    func wakeEvents() -> AsyncStream<Void> { AsyncStream { _ in } }
}

private struct PreviewPowerToken: PowerToken {
    func end() {}
}

private final class PreviewDriveIO: DriveIO, @unchecked Sendable {
    func openSource(path: String) throws -> any SourceFile { throw VerifyError.permissionDenied(path: path) }
    func createWriter(path: String, truncate: Bool) throws -> any DestinationWriter {
        throw VerifyError.permissionDenied(path: path)
    }
    func openReader(path: String) throws -> any DestinationReader { throw VerifyError.permissionDenied(path: path) }
    func fileSize(path: String) -> Int64? { nil }
    func rename(from: String, to: String) throws {}
    func removeFile(path: String) throws {}
    func freeSpace(path: String) throws -> Int64 { Int64.max }
}
