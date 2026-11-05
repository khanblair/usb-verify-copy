import DiskArbitration
import Foundation
import USBVerifyCore

public final class DiskArbitrationVolumeEvents: VolumeEvents, @unchecked Sendable {
    fileprivate final class Context {
        weak var owner: DiskArbitrationVolumeEvents?
    }

    private let queue = DispatchQueue(label: "USBVerify.DiskArbitration")
    private let lock = NSLock()
    private let session: DASession?
    private let context: Context
    private let connection: (any ConnectionInfoProvider)?
    private var known: [VolumeID: Volume] = [:]
    private var subscribers: [UUID: AsyncStream<VolumeEvent>.Continuation] = [:]

    public init(connection: (any ConnectionInfoProvider)? = nil) {
        self.connection = connection
        self.context = Context()
        self.session = DASessionCreate(kCFAllocatorDefault)
        context.owner = self
        guard let session else { return }
        DASessionSetDispatchQueue(session, queue)
        let opaque = Unmanaged.passUnretained(context).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, diskAppeared, opaque)
        DARegisterDiskDisappearedCallback(session, nil, diskDisappeared, opaque)
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, diskDescriptionChanged, opaque)
    }

    deinit {
        guard let session else { return }
        DASessionSetDispatchQueue(session, nil)
        lock.lock()
        let continuations = Array(subscribers.values)
        subscribers.removeAll()
        lock.unlock()
        continuations.forEach { $0.finish() }
    }

    public func currentVolumes() async -> [Volume] {
        snapshotVolumes()
    }

    public func events() -> AsyncStream<VolumeEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.lock()
            subscribers[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.subscribers.removeValue(forKey: id)
                self?.lock.unlock()
            }
        }
    }

    fileprivate func process(_ disk: DADisk, kind: EventKind) {
        guard let description = DADiskCopyDescription(disk) as? [String: Any] else { return }
        let facts = (description[String(kDADiskDescriptionVolumePathKey) as String] as? URL).flatMap {
            mountFacts(for: $0.path)
        }
        guard let diskDescription = makeDescription(from: description, mountFacts: facts) else { return }
        let bsdName = diskDescription.bsdName
        Task { [weak self] in
            guard let self else { return }
            let route = await connection?.route(forWholeDisk: diskDescription.wholeDiskBSDName ?? bsdName)
            guard let volume = VolumeCatalog.makeVolume(from: diskDescription, route: route) else { return }
            publish(volume: volume, kind: kind)
        }
    }

    private func publish(volume: Volume, kind: EventKind) {
        lock.lock()
        let event: VolumeEvent
        switch kind {
        case .appeared:
            known[volume.id] = volume
            event = .added(volume)
        case .changed:
            known[volume.id] = volume
            event = .changed(volume)
        }
        let values = Array(subscribers.values)
        lock.unlock()
        values.forEach { $0.yield(event) }
    }

    private func snapshotVolumes() -> [Volume] {
        lock.withLock { Array(known.values) }
    }

    fileprivate func remove(_ disk: DADisk) {
        guard let description = DADiskCopyDescription(disk) as? [String: Any],
            let uuid = uuidString(description[String(kDADiskDescriptionVolumeUUIDKey) as String])
        else { return }
        let id = VolumeID(uuid)
        lock.lock()
        let existed = known.removeValue(forKey: id) != nil
        let values = Array(subscribers.values)
        lock.unlock()
        guard existed else { return }
        values.forEach { $0.yield(.removed(id)) }
    }

    fileprivate enum EventKind { case appeared, changed }
}

private func diskAppeared(_ disk: DADisk, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<DiskArbitrationVolumeEvents.Context>.fromOpaque(context).takeUnretainedValue().owner?.process(
        disk, kind: .appeared)
}

private func diskDisappeared(_ disk: DADisk, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<DiskArbitrationVolumeEvents.Context>.fromOpaque(context).takeUnretainedValue().owner?.remove(disk)
}

private func diskDescriptionChanged(_ disk: DADisk, _ keys: CFArray, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<DiskArbitrationVolumeEvents.Context>.fromOpaque(context).takeUnretainedValue().owner?.process(
        disk, kind: .changed)
}

private func uuidString(_ value: Any?) -> String? {
    if let value = value as? UUID { return value.uuidString }
    if let value = value as? NSUUID { return value.uuidString }
    return value as? String
}
