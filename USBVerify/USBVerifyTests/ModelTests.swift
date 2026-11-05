import Testing
import USBVerifyCore

@testable import USBVerify

@Test
func formattingUsesHexOffsetsAndHumanBytes() {
    #expect(Formatting.hex(255) == "0xFF")
    #expect(Formatting.bytes(1_024).contains("KB"))
    #expect(Formatting.duration(65) == "1m 5s left")
}

@MainActor
@Test
func preflightIssueIsShownInPlainEnglishAndTechnicalDetail() {
    let model = AppModel(dependencies: .preview())
    let unsupported = Volume(
        id: VolumeID("unsupported"),
        name: "Mac disk",
        mountPath: "/tmp/USBVerifyPreview",
        bsdName: "disk1s1",
        wholeDiskBSDName: "disk1",
        protocolName: "USB",
        filesystem: .apfs,
        totalBytes: 1_000,
        freeBytes: 1_000)
    let request = CopyRequest(volume: unsupported, destinationFolder: "", sourcePaths: [])

    model.startCopy(request)

    #expect(model.lastErrorMessage == "This drive uses APFS. Only exFAT and FAT32 drives can be used.")
    #expect(model.lastErrorDetail?.contains("unsupportedFilesystem APFS") == true)
}

@MainActor
@Test
func selectedVolumeClearsWhenRefreshFindsItMissing() async {
    let model = AppModel(dependencies: .preview())
    let missing = Volume(
        id: VolumeID("missing"),
        name: "Missing",
        mountPath: "/tmp/missing",
        bsdName: "disk2s1",
        wholeDiskBSDName: "disk2",
        protocolName: "USB",
        filesystem: .exfat,
        totalBytes: 1_000,
        freeBytes: 1_000)
    model.selectedVolume = missing
    model.volumes = []

    await model.refresh()

    #expect(model.selectedVolume == nil)
}
