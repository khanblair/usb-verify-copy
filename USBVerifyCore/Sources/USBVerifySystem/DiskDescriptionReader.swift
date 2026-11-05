import Darwin
import DiskArbitration
import Foundation
import USBVerifyCore

public struct MountFacts: Sendable, Equatable {
    public let totalBytes: Int64
    public let freeBytes: Int64
    public let isReadOnly: Bool
    public let isBootVolume: Bool
    public let hasTimeMachineBackups: Bool

    public init(totalBytes: Int64, freeBytes: Int64, isReadOnly: Bool, isBootVolume: Bool, hasTimeMachineBackups: Bool)
    {
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.isReadOnly = isReadOnly
        self.isBootVolume = isBootVolume
        self.hasTimeMachineBackups = hasTimeMachineBackups
    }
}

public func mountFacts(for path: String) -> MountFacts? {
    var volumeStats = statfs()
    guard path.withCString({ statfs($0, &volumeStats) }) == 0 else { return nil }
    var rootStats = statfs()
    let rootSucceeded = "/".withCString { statfs($0, &rootStats) == 0 }
    let sameFileSystem = rootSucceeded && volumeStats.f_fsid.val == rootStats.f_fsid.val
    let isBoot = path == "/" || path == "/System/Volumes/Data" || sameFileSystem
    let total = Int64(volumeStats.f_blocks) * Int64(volumeStats.f_bsize)
    let free = Int64(volumeStats.f_bavail) * Int64(volumeStats.f_bsize)
    let backupPath = URL(fileURLWithPath: path).appendingPathComponent("Backups.backupdb").path
    return MountFacts(
        totalBytes: total,
        freeBytes: free,
        isReadOnly: (volumeStats.f_flags & UInt32(MNT_RDONLY)) != 0,
        isBootVolume: isBoot,
        hasTimeMachineBackups: FileManager.default.fileExists(atPath: backupPath))
}

public func makeDescription(from dict: [String: Any], mountFacts: MountFacts?) -> DiskDescription? {
    guard let bsdName = stringValue(dict[key(kDADiskDescriptionMediaBSDNameKey)]) else { return nil }
    let volumePath = urlValue(dict[key(kDADiskDescriptionVolumePathKey)])?.path
    let uuid = uuidString(dict[key(kDADiskDescriptionVolumeUUIDKey)])
    let mediaSize = int64Value(dict[key(kDADiskDescriptionMediaSizeKey)])
    let internalFlag = boolValue(dict[key(kDADiskDescriptionDeviceInternalKey)])
    let protocolName = stringValue(dict[key(kDADiskDescriptionDeviceProtocolKey)])
    return DiskDescription(
        volumeUUID: uuid,
        volumeName: stringValue(dict[key(kDADiskDescriptionVolumeNameKey)]),
        volumeKind: stringValue(dict[key(kDADiskDescriptionVolumeKindKey)]),
        volumePath: volumePath,
        bsdName: bsdName,
        wholeDiskBSDName: VolumeCatalog.wholeDiskName(fromBSDName: bsdName),
        deviceInternal: internalFlag,
        protocolName: protocolName,
        modelName: stringValue(dict[key(kDADiskDescriptionDeviceModelKey)]),
        totalBytes: mountFacts?.totalBytes ?? mediaSize,
        freeBytes: mountFacts?.freeBytes ?? 0,
        isNetwork: boolValue(dict[key(kDADiskDescriptionVolumeNetworkKey)]) ?? false,
        isReadOnly: mountFacts?.isReadOnly ?? false,
        isBootVolume: mountFacts?.isBootVolume ?? false,
        hasTimeMachineBackups: mountFacts?.hasTimeMachineBackups ?? false)
}

private func key(_ value: CFString) -> String {
    value as String
}

private func stringValue(_ value: Any?) -> String? {
    if let value = value as? String { return value }
    if let value = value as? NSString { return String(value) }
    return nil
}

private func urlValue(_ value: Any?) -> URL? {
    if let value = value as? URL { return value }
    if let value = value as? NSURL { return value as URL }
    return nil
}

private func boolValue(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    return nil
}

private func int64Value(_ value: Any?) -> Int64 {
    if let value = value as? Int64 { return value }
    if let value = value as? NSNumber { return value.int64Value }
    return 0
}

private func uuidString(_ value: Any?) -> String? {
    if let value = value as? UUID { return value.uuidString }
    if let value = value as? NSUUID { return value.uuidString }
    return stringValue(value)
}
