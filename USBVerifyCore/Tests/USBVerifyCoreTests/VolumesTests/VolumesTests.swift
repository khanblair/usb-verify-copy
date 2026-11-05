import Foundation
import Testing

@testable import USBVerifyCore

private func description(
    protocolName: String? = "USB", internalDevice: Bool? = false, path: String? = "/Volumes/Test", uuid: String? = "id"
) -> DiskDescription {
    DiskDescription(
        volumeUUID: uuid, volumeName: nil, volumeKind: "exfat", volumePath: path, bsdName: "disk9s1",
        deviceInternal: internalDevice, protocolName: protocolName)
}

@Test func volumeCatalogHideRules() {
    #expect(VolumeCatalog.makeVolume(from: description(uuid: nil)) == nil)
    #expect(VolumeCatalog.makeVolume(from: description(path: nil)) == nil)
    #expect(VolumeCatalog.makeVolume(from: description(internalDevice: nil)) == nil)
    #expect(VolumeCatalog.makeVolume(from: description(internalDevice: true)) == nil)
    #expect(VolumeCatalog.makeVolume(from: description().withBootVolume()) == nil)
    #expect(VolumeCatalog.makeVolume(from: description().withNetwork()) == nil)
    #expect(VolumeCatalog.makeVolume(from: description(protocolName: "Virtual Interface")) == nil)
}

@Test func volumeCatalogDefaultsAndWholeDisk() {
    let value = VolumeCatalog.makeVolume(from: description(protocolName: nil))
    #expect(value?.name == "Untitled")
    #expect(value?.protocolName == "Unknown")
    #expect(value?.wholeDiskBSDName == "disk9")
    #expect(VolumeCatalog.wholeDiskName(fromBSDName: "disk9") == "disk9")
    #expect(VolumeCatalog.wholeDiskName(fromBSDName: "disk9s1") == "disk9")
}

@Test func destinationGuardRejectsUnsafePaths() throws {
    let volume = Volume(
        id: VolumeID("id"), name: "Test", mountPath: "/Volumes/Test", bsdName: "disk9s1", wholeDiskBSDName: "disk9",
        protocolName: "USB", filesystem: .exfat, totalBytes: 1, freeBytes: 1)
    let guardValue = DestinationGuard(volume: volume)
    #expect(try guardValue.path(folder: "Games", name: "one.pkg") == "/Volumes/Test/Games/one.pkg")
    #expect(throws: VerifyError.destinationOutsideVolume(path: "../x/a")) {
        try guardValue.path(folder: "../x", name: "a")
    }
    #expect(throws: VerifyError.destinationOutsideVolume(path: "/tmp/x")) { try guardValue.validate(path: "/tmp/x") }
    #expect(try guardValue.relativeFolder(ofAbsolute: "/Volumes/Test/Games") == "Games")
    #expect(guardValue.isOnVolume("/Volumes/Test/file"))
    #expect(!guardValue.isOnVolume("/Volumes/Other/file"))
}

@Test func rootMountIsAlwaysRefused() {
    let volume = Volume(
        id: VolumeID("id"), name: "Root", mountPath: "/", bsdName: "disk1s1", wholeDiskBSDName: "disk1",
        protocolName: "USB", filesystem: .exfat, totalBytes: 1, freeBytes: 1)
    #expect(throws: VerifyError.destinationOutsideVolume(path: "/x")) {
        try DestinationGuard(volume: volume).validate(path: "/x")
    }
}

extension DiskDescription {
    fileprivate func withBootVolume() -> DiskDescription {
        var copy = self
        copy.isBootVolume = true
        return copy
    }
    fileprivate func withNetwork() -> DiskDescription {
        var copy = self
        copy.isNetwork = true
        return copy
    }
}
