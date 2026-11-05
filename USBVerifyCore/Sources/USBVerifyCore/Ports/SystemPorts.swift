/// Protocols for everything that touches macOS services. Real adapters live in the app target. Fakes live in tests.

public enum ErasePrivilege: Sendable, Equatable {
    case user
    case admin
}

public protocol VolumeControl: Sendable {
    /// Throws `VerifyError.unmountBusy` when something holds the volume open. Never forces.
    func unmount(volume: VolumeID) async throws
    /// Mounts the volume again and returns the new mount path, which can differ from the old one.
    func mount(volume: VolumeID) async throws -> String
    /// Current mount path, nil when the volume is not mounted.
    func mountPath(of volume: VolumeID) async -> String?
    func eject(volume: VolumeID) async throws
    /// Runs `diskutil eraseDisk ExFAT <label> MBR <wholeDisk>`. Returns the command output.
    func eraseExFATWithMBR(wholeDisk: String, label: String, privilege: ErasePrivilege) async throws -> String
}

public enum VolumeEvent: Equatable, Sendable {
    case added(Volume)
    case removed(VolumeID)
    case changed(Volume)
}

public protocol VolumeEvents: Sendable {
    func currentVolumes() async -> [Volume]
    func events() -> AsyncStream<VolumeEvent>
}

public protocol ConnectionInfoProvider: Sendable {
    func route(forWholeDisk bsdName: String) async -> Route?
}

public protocol Notifier: Sendable {
    func notify(title: String, body: String) async
}

public protocol PowerToken: Sendable {
    func end()
}

public protocol PowerGuard: Sendable {
    /// Blocks idle sleep until the token is ended.
    func begin(reason: String) -> any PowerToken
    /// Fires once for each wake from sleep.
    func wakeEvents() -> AsyncStream<Void>
    var isOnBattery: Bool { get }
}

/// Where finished runs go: the text log and the JSONL history.
public protocol RunSink: Sendable {
    func record(_ run: RunRecord) async
}
