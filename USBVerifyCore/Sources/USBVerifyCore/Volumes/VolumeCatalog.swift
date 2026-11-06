public enum VolumeCatalog {
    /// `allowDiskImages` is for testing with a RAM disk only. Disk images are hidden by default.
    public static func makeVolume(from d: DiskDescription, route: Route? = nil, allowDiskImages: Bool = false)
        -> Volume?
    {
        let isDiskImage = d.protocolName == "Virtual Interface"
        // A disk image has no "internal" key at all, so it counts as external only when images are allowed.
        let isExternal = d.deviceInternal == false || (allowDiskImages && isDiskImage && d.deviceInternal == nil)
        guard let uuid = d.volumeUUID, !uuid.isEmpty, let path = d.volumePath,
            isExternal, !d.isBootVolume, !d.isNetwork, allowDiskImages || !isDiskImage
        else { return nil }
        return Volume(
            id: VolumeID(uuid), name: d.volumeName ?? "Untitled", mountPath: path,
            bsdName: d.bsdName, wholeDiskBSDName: d.wholeDiskBSDName ?? wholeDiskName(fromBSDName: d.bsdName),
            model: d.modelName, protocolName: d.protocolName ?? "Unknown",
            filesystem: .from(volumeKind: d.volumeKind), totalBytes: d.totalBytes,
            freeBytes: d.freeBytes, isReadOnly: d.isReadOnly,
            hasTimeMachineBackups: d.hasTimeMachineBackups, route: route)
    }

    public static func filter(_ descriptions: [DiskDescription]) -> [Volume] {
        descriptions.compactMap { makeVolume(from: $0) }
    }

    public static func wholeDiskName(fromBSDName bsd: String) -> String {
        guard let sIndex = bsd.lastIndex(of: "s") else { return bsd }
        let suffix = bsd[bsd.index(after: sIndex)...]
        return !suffix.isEmpty && suffix.allSatisfy({ $0.isNumber }) ? String(bsd[..<sIndex]) : bsd
    }
}
