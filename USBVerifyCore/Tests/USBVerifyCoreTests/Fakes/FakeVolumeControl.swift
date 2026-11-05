import Foundation

@testable import USBVerifyCore

final class FakeVolumeControl: VolumeControl, @unchecked Sendable {
    private let lock = NSLock()
    private let drive: FakeDrive
    private var mounted = true
    private var busyRemaining = 0
    private var _mountPath: String
    private var _unmountCalls = 0
    private var _mountCalls = 0
    private var _ejectCalls = 0
    private var _erasedDisks: [(disk: String, label: String, privilege: ErasePrivilege)] = []

    init(drive: FakeDrive, mountPath: String) {
        self.drive = drive
        _mountPath = mountPath
    }

    var busyUnmounts: Int {
        get { lock.withLock { busyRemaining } }
        set { lock.withLock { busyRemaining = newValue } }
    }

    var unmountCalls: Int { lock.withLock { _unmountCalls } }
    var mountCalls: Int { lock.withLock { _mountCalls } }
    var ejectCalls: Int { lock.withLock { _ejectCalls } }
    var erasedDisks: [(disk: String, label: String, privilege: ErasePrivilege)] {
        lock.withLock { _erasedDisks }
    }

    var mountPath: String {
        get { lock.withLock { _mountPath } }
        set { lock.withLock { _mountPath = newValue } }
    }

    func unmount(volume: VolumeID) async throws {
        try checkConnected(volume)
        let shouldBeBusy = lock.withLock { () -> Bool in
            _unmountCalls += 1
            guard busyRemaining > 0 else { return false }
            busyRemaining -= 1
            return true
        }
        if shouldBeBusy {
            throw VerifyError.unmountBusy(blockers: ["Finder (pid 123)"])
        }
        lock.withLock { mounted = false }
    }

    func mount(volume: VolumeID) async throws -> String {
        try checkConnected(volume)
        let path = lock.withLock { () -> String in
            _mountCalls += 1
            mounted = true
            return _mountPath
        }
        drive.dropCaches()
        return path
    }

    func mountPath(of volume: VolumeID) async -> String? {
        lock.withLock { mounted ? _mountPath : nil }
    }

    func eject(volume: VolumeID) async throws {
        try checkConnected(volume)
        lock.withLock { _ejectCalls += 1 }
    }

    func eraseExFATWithMBR(wholeDisk: String, label: String, privilege: ErasePrivilege) async throws -> String {
        try checkConnected(VolumeID("fake"))
        lock.withLock { _erasedDisks.append((wholeDisk, label, privilege)) }
        return "erased"
    }

    private func checkConnected(_ volume: VolumeID) throws {
        if drive.isUnplugged {
            throw VerifyError.volumeNotFound(volumeID: volume.uuid)
        }
    }
}

final class FakeRunSink: RunSink, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [RunRecord] = []

    var records: [RunRecord] { lock.withLock { values } }

    func record(_ run: RunRecord) async {
        lock.withLock { values.append(run) }
    }
}

func makeTestVolume(drive: FakeDrive, mountPath: String) -> Volume {
    Volume(
        id: VolumeID("fake-volume"), name: "Test", mountPath: mountPath, bsdName: "disk9s1",
        wholeDiskBSDName: "disk9", protocolName: "USB", filesystem: .exfat,
        totalBytes: 1_000_000_000, freeBytes: 900_000_000)
}

extension NSLock {
    fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
