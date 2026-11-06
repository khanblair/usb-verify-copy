import Foundation
import USBVerifyCore
import USBVerifySystem

public struct CLIEnvironment: Sendable {
    public var volumes: any VolumeEvents
    public var volumeControl: any VolumeControl
    public var drive: @Sendable (Volume) -> any DriveIO
    public var power: any PowerGuard
    public var jobStore: JobStore
    public var sink: (any RunSink)?

    public init(
        volumes: any VolumeEvents, volumeControl: any VolumeControl,
        drive: @escaping @Sendable (Volume) -> any DriveIO,
        power: any PowerGuard, jobStore: JobStore, sink: (any RunSink)? = nil
    ) {
        self.volumes = volumes
        self.volumeControl = volumeControl
        self.drive = drive
        self.power = power
        self.jobStore = jobStore
        self.sink = sink
    }

    public static func live(includeDiskImages: Bool = false) -> CLIEnvironment {
        let connection = IOKitConnectionInfo()
        let source = DiskArbitrationVolumeEvents(connection: connection, includeDiskImages: includeDiskImages)
        let control = DiskutilVolumeControl(lookup: { id in
            await source.currentVolumes().first { $0.id == id }
        })
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let store = JobStore(directory: "\(home)/Library/Application Support/USBVerify/jobs")
        let log = RunLog(path: "\(home)/Library/Logs/USBVerify/usb-verify.log")
        let history = HistoryStore(path: "\(home)/Library/Application Support/USBVerify/history.jsonl")
        return CLIEnvironment(
            volumes: source, volumeControl: control, drive: { _ in PosixDriveIO() },
            power: ProcessPowerGuard(), jobStore: store, sink: CompositeRunSink([log, history]))
    }
}
