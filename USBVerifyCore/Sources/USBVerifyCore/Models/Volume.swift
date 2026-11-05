/// Filesystems the app understands. Only `exfat` and `fat32` can be copy targets (decision D13).
public enum FilesystemKind: String, Codable, Sendable, Equatable {
    case exfat, fat32, apfs, hfs, ntfs, other

    /// Maps a DiskArbitration `VolumeKind` string. `msdos` covers FAT12, FAT16 and FAT32; all are
    /// treated as FAT32 because the 4 GiB file limit is the rule that matters.
    public static func from(volumeKind: String?) -> FilesystemKind {
        switch volumeKind?.lowercased() {
        case "exfat": return .exfat
        case "msdos": return .fat32
        case "apfs": return .apfs
        case "hfs": return .hfs
        case "ntfs": return .ntfs
        default: return .other
        }
    }

    public var isCopyTarget: Bool { self == .exfat || self == .fat32 }

    public var displayName: String {
        switch self {
        case .exfat: return "exFAT"
        case .fat32: return "FAT32"
        case .apfs: return "APFS"
        case .hfs: return "HFS+"
        case .ntfs: return "NTFS"
        case .other: return "an unsupported filesystem"
        }
    }
}

/// A volume is identified by its volume UUID. Never by name or BSD id (spec section 7).
public struct VolumeID: Hashable, Codable, Sendable {
    public var uuid: String
    public init(_ uuid: String) { self.uuid = uuid }
}

/// How a drive is connected (spec section 15). Unknown values are nil.
public struct Route: Codable, Equatable, Hashable, Sendable {
    public var protocolName: String
    public var hubInPath: Bool?
    public var hubDepth: Int?
    /// Negotiated link speed in megabits per second, for example 480 or 5000.
    public var speedMbps: Int?
    public var portLocation: String?

    public init(protocolName: String, hubInPath: Bool? = nil, hubDepth: Int? = nil,
                speedMbps: Int? = nil, portLocation: String? = nil) {
        self.protocolName = protocolName
        self.hubInPath = hubInPath
        self.hubDepth = hubDepth
        self.speedMbps = speedMbps
        self.portLocation = portLocation
    }

    /// Stable text used to group runs by route in History.
    public var key: String {
        let hub = hubInPath.map { $0 ? "hub" : "direct" } ?? "hub?"
        let speed = speedMbps.map { "\($0)Mbps" } ?? "speed?"
        return "\(protocolName)|\(hub)|\(speed)|\(portLocation ?? "port?")"
    }

    public var isUSB2Speed: Bool { (speedMbps ?? Int.max) <= 480 }
}

/// Raw facts about one mounted volume, as DiskArbitration and `statfs` report them.
/// `VolumeCatalog` (a later module) turns this into a `Volume` or hides it.
public struct DiskDescription: Equatable, Sendable {
    public var volumeUUID: String?
    public var volumeName: String?
    public var volumeKind: String?
    public var volumePath: String?
    public var bsdName: String
    public var wholeDiskBSDName: String?
    /// nil when the key is absent. Only `false` counts as external.
    public var deviceInternal: Bool?
    public var protocolName: String?
    public var modelName: String?
    public var totalBytes: Int64
    public var freeBytes: Int64
    public var isNetwork: Bool
    /// True when `statfs` reports `MNT_RDONLY`.
    public var isReadOnly: Bool
    public var isBootVolume: Bool
    public var hasTimeMachineBackups: Bool

    public init(volumeUUID: String? = nil, volumeName: String? = nil, volumeKind: String? = nil,
                volumePath: String? = nil, bsdName: String, wholeDiskBSDName: String? = nil,
                deviceInternal: Bool? = nil, protocolName: String? = nil, modelName: String? = nil,
                totalBytes: Int64 = 0, freeBytes: Int64 = 0, isNetwork: Bool = false,
                isReadOnly: Bool = false, isBootVolume: Bool = false,
                hasTimeMachineBackups: Bool = false) {
        self.volumeUUID = volumeUUID
        self.volumeName = volumeName
        self.volumeKind = volumeKind
        self.volumePath = volumePath
        self.bsdName = bsdName
        self.wholeDiskBSDName = wholeDiskBSDName
        self.deviceInternal = deviceInternal
        self.protocolName = protocolName
        self.modelName = modelName
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.isNetwork = isNetwork
        self.isReadOnly = isReadOnly
        self.isBootVolume = isBootVolume
        self.hasTimeMachineBackups = hasTimeMachineBackups
    }
}

/// A volume the app lists and can use.
public struct Volume: Identifiable, Codable, Equatable, Sendable {
    public var id: VolumeID
    public var name: String
    public var mountPath: String
    public var bsdName: String
    public var wholeDiskBSDName: String
    public var model: String?
    public var protocolName: String
    public var filesystem: FilesystemKind
    public var totalBytes: Int64
    public var freeBytes: Int64
    public var isReadOnly: Bool
    public var hasTimeMachineBackups: Bool
    public var route: Route?

    public init(id: VolumeID, name: String, mountPath: String, bsdName: String,
                wholeDiskBSDName: String, model: String? = nil, protocolName: String,
                filesystem: FilesystemKind, totalBytes: Int64, freeBytes: Int64,
                isReadOnly: Bool = false, hasTimeMachineBackups: Bool = false, route: Route? = nil) {
        self.id = id
        self.name = name
        self.mountPath = mountPath
        self.bsdName = bsdName
        self.wholeDiskBSDName = wholeDiskBSDName
        self.model = model
        self.protocolName = protocolName
        self.filesystem = filesystem
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.isReadOnly = isReadOnly
        self.hasTimeMachineBackups = hasTimeMachineBackups
        self.route = route
    }
}
