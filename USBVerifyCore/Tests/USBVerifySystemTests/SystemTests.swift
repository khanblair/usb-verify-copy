import DiskArbitration
import Foundation
import Testing
import USBVerifyCore
@testable import USBVerifySystem

@Suite("USBVerifySystem")
struct SystemTests {
    @Test func parsesUnmountBlockers() {
        let text =
            "Volume Khan on disk9s1 failed to unmount: dissented by PID 400 (/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder)"
        #expect(parseUnmountBlockers(text) == ["Finder (pid 400)"])
        #expect(parseUnmountBlockers("failed to unmount") == [])
    }

    @Test func detectsUnmountAndGoneDisk() {
        #expect(isUnmountBusy("Resource busy"))
        #expect(isUnmountBusy("dissented by PID 12 (/bin/foo)"))
        #expect(isDiskGone("Could not find disk disk9"))
        #expect(isDiskGone("Unable to find disk"))
        #expect(!isDiskGone("erase failed"))
    }

    @Test func parsesMountPoint() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["MountPoint": "/Volumes/Khan 1"], format: .xml, options: 0)
        #expect(parseMountPoint(fromInfoPlist: data) == "/Volumes/Khan 1")
        #expect(parseMountPoint(fromInfoPlist: Data("bad".utf8)) == nil)
    }

    @Test func buildsAdminScriptFromValidatedArguments() throws {
        let args = try FormatPlan.arguments(wholeDisk: "disk9", label: "Khan Drive")
        let script = adminCommandScript(arguments: args)
        #expect(script.contains("'Khan Drive'"))
        #expect(script.contains("'disk9'"))
        #expect(script.contains("with administrator privileges"))
        #expect(throws: VerifyError.self) {
            try FormatPlan.arguments(wholeDisk: "disk9", label: "A\"; rm -rf /")
        }
    }

    @Test func routeBuilderCoversUsbAndNonUsbPaths() {
        let direct = makeRoute(chain: [["Device Speed": 3, "locationID": 42, "bDeviceClass": 0]], protocolName: "USB")
        #expect(direct.hubInPath == false)
        #expect(direct.hubDepth == 0)
        #expect(direct.speedMbps == 5_000)
        let hubs = makeRoute(
            chain: [["Device Speed": 2, "bDeviceClass": 0], ["bDeviceClass": 9], ["bDeviceClass": 9]],
            protocolName: "USB")
        #expect(hubs.hubInPath == true)
        #expect(hubs.hubDepth == 2)
        #expect(hubs.speedMbps == 480)
        let nvme = makeRoute(chain: [["IOClass": "AppleThunderboltDevice"]], protocolName: "Thunderbolt")
        #expect(nvme.hubInPath == false)
        #expect(nvme.hubDepth == 0)
        #expect(makeRoute(chain: [], protocolName: "Unknown").speedMbps == nil)
    }

    @Test func makesDiskDescriptionsFromFacts() {
        let facts = MountFacts(
            totalBytes: 100, freeBytes: 40, isReadOnly: false, isBootVolume: false, hasTimeMachineBackups: true)
        let dictionary: [String: Any] = [
            "DAMediaBSDName": "disk9s1",
            "DAVolumeUUID": UUID(uuidString: "11111111-1111-1111-1111-111111111111") as Any,
            "DAVolumeName": "Khan",
            "DAVolumeKind": "exfat",
            "DAVolumePath": URL(fileURLWithPath: "/Volumes/Khan"),
            "DADeviceInternal": false,
            "DADeviceProtocol": "USB",
            "DADeviceModel": "Test SSD",
            "DAVolumeNetwork": false,
            "DAMediaSize": 200,
        ]
        let description = makeDescription(from: dictionary, mountFacts: facts)
        #expect(description?.bsdName == "disk9s1")
        #expect(description?.wholeDiskBSDName == "disk9")
        #expect(description?.volumeKind == "exfat")
        #expect(description?.totalBytes == 100)
        #expect(description?.hasTimeMachineBackups == true)
        #expect(makeDescription(from: ["DAMediaBSDName": "disk9s1"], mountFacts: nil) != nil)
    }

    @Test func parsesFilesystemDriverLine() {
        let output = "/dev/disk9s1 on /Volumes/Khan (exfat, local, nodev, nosuid, fskit)\n"
        #expect(parseFilesystemDriver(output, mountPath: "/Volumes/Khan") == "fskit")
        #expect(
            parseFilesystemDriver("/dev/disk9s1 on /Volumes/Other (exfat, local)", mountPath: "/Volumes/Khan") == nil)
    }

    @Test func diskutilControlHandlesBusyUnmount() async {
        let runner = FakeCommandRunner(outputs: [
            "unmount disk9s1": CommandOutput(
                exitCode: 1, stdout: "failed to unmount: dissented by PID 400 (/Finder)", stderr: "")
        ])
        let control = DiskutilVolumeControl(runner: runner) { _ in testVolume() }
        do {
            try await control.unmount(volume: VolumeID("uuid"))
            Issue.record("Expected busy error")
        } catch let error as VerifyError {
            #expect(error == .unmountBusy(blockers: ["Finder (pid 400)"]))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func diskutilControlHandlesGoneDisk() async {
        let runner = FakeCommandRunner(outputs: [
            "unmount disk9s1": CommandOutput(exitCode: 1, stdout: "Could not find disk disk9s1", stderr: "")
        ])
        let control = DiskutilVolumeControl(runner: runner) { _ in testVolume() }
        do {
            try await control.unmount(volume: VolumeID("uuid"))
            Issue.record("Expected missing volume error")
        } catch let error as VerifyError {
            #expect(error == .volumeNotFound(volumeID: "uuid"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func diskutilMountReturnsNewPath() async throws {
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["MountPoint": "/Volumes/Khan 1"], format: .xml, options: 0)
        let runner = FakeCommandRunner(outputs: [
            "mount disk9s1": CommandOutput(exitCode: 0, stdout: "", stderr: ""),
            "info -plist disk9s1": CommandOutput(
                exitCode: 0, stdout: String(decoding: plist, as: UTF8.self), stderr: ""),
        ])
        let control = DiskutilVolumeControl(runner: runner) { _ in testVolume() }
        #expect(try await control.mount(volume: VolumeID("uuid")) == "/Volumes/Khan 1")
        #expect(
            await runner.commands() == ["/usr/sbin/diskutil mount disk9s1", "/usr/sbin/diskutil info -plist disk9s1"])
    }

    @Test func diskutilEraseUsesUserAndAdminCommands() async throws {
        let infoKey = "info -plist disk9"
        let outputs = [
            infoKey: CommandOutput(exitCode: 0, stdout: Self.plist(isInternal: false, wholeDisk: true), stderr: "")
        ]
        let ok = CommandOutput(exitCode: 0, stdout: "ok", stderr: "")
        let userRunner = FakeCommandRunner(outputs: outputs, defaultOutput: ok)
        let userControl = DiskutilVolumeControl(runner: userRunner) { _ in nil }
        #expect(try await userControl.eraseExFATWithMBR(wholeDisk: "disk9", label: "Khan", privilege: .user) == "ok")
        #expect(
            await userRunner.commands() == [
                "/usr/sbin/diskutil info -plist disk9", "/usr/sbin/diskutil eraseDisk ExFAT Khan MBR disk9",
            ])
        let adminRunner = FakeCommandRunner(outputs: outputs, defaultOutput: ok)
        let adminControl = DiskutilVolumeControl(runner: adminRunner) { _ in nil }
        _ = try await adminControl.eraseExFATWithMBR(wholeDisk: "disk9", label: "Khan", privilege: .admin)
        let commands = await adminRunner.commands()
        #expect(commands.last?.contains("/usr/bin/osascript -e") == true)
        #expect(commands.last?.contains("'Khan'") == true)
    }

    @Test func eraseRefusesInternalOrUnknownDisks() async {
        let ok = CommandOutput(exitCode: 0, stdout: "ok", stderr: "")
        let cases: [(String, CommandOutput)] = [
            ("internal", CommandOutput(exitCode: 0, stdout: Self.plist(isInternal: true, wholeDisk: true), stderr: "")),
            (
                "not whole",
                CommandOutput(exitCode: 0, stdout: Self.plist(isInternal: false, wholeDisk: false), stderr: "")
            ),
            ("not a plist", ok),
            ("diskutil failed", CommandOutput(exitCode: 1, stdout: "", stderr: "Could not find disk")),
        ]
        for (name, info) in cases {
            let runner = FakeCommandRunner(outputs: ["info -plist disk0": info], defaultOutput: ok)
            let control = DiskutilVolumeControl(runner: runner) { _ in nil }
            do {
                _ = try await control.eraseExFATWithMBR(wholeDisk: "disk0", label: "Khan", privilege: .user)
                Issue.record("erase was not refused for case: \(name)")
            } catch VerifyError.formatRefused {
                // expected
            } catch {
                Issue.record("wrong error for case \(name): \(error)")
            }
            #expect(!(await runner.commands()).contains { $0.contains("eraseDisk") }, "eraseDisk ran for case: \(name)")
        }
    }

    @Test func freshLookupBeatsCachedBsdNameAfterReplug() async throws {
        let id = VolumeID("UUID-1")
        let names = NameBox(["disk9s1", "disk10s1"])
        let runner = FakeCommandRunner(defaultOutput: CommandOutput(exitCode: 0, stdout: "ok", stderr: ""))
        let control = DiskutilVolumeControl(runner: runner) { _ in
            let bsd = names.next()
            return Volume(
                id: id, name: "Khan", mountPath: "/Volumes/Khan", bsdName: bsd,
                wholeDiskBSDName: String(bsd.dropLast(2)),
                protocolName: "USB", filesystem: .exfat, totalBytes: 1, freeBytes: 1)
        }
        try await control.unmount(volume: id)
        try await control.unmount(volume: id)
        #expect(
            await runner.commands() == ["/usr/sbin/diskutil unmount disk9s1", "/usr/sbin/diskutil unmount disk10s1"])
    }

    private static func plist(isInternal: Bool, wholeDisk: Bool) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Internal</key><\(isInternal ? "true" : "false")/>
        <key>WholeDisk</key><\(wholeDisk ? "true" : "false")/>
        </dict></plist>
        """
    }

    @Test func readOnlyAdaptersDoNotCrash() async {
        let events = DiskArbitrationVolumeEvents()
        _ = await events.currentVolumes()
        let power = ProcessPowerGuard()
        let token = power.begin(reason: "test")
        token.end()
        token.end()
        _ = power.isOnBattery
    }

    private func testVolume() -> Volume {
        Volume(
            id: VolumeID("uuid"), name: "Khan", mountPath: "/Volumes/Khan", bsdName: "disk9s1",
            wholeDiskBSDName: "disk9", protocolName: "USB", filesystem: .exfat, totalBytes: 100, freeBytes: 50)
    }
}

private actor FakeCommandRunner: CommandRunner {
    private let outputs: [String: CommandOutput]
    private let defaultOutput: CommandOutput
    private var recorded: [String] = []

    init(
        outputs: [String: CommandOutput] = [:],
        defaultOutput: CommandOutput = CommandOutput(exitCode: 1, stdout: "", stderr: "not canned")
    ) {
        self.outputs = outputs
        self.defaultOutput = defaultOutput
    }

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandOutput {
        let line = ([executable] + arguments).joined(separator: " ")
        recorded.append(line)
        let key = arguments.joined(separator: " ")
        return outputs[key] ?? defaultOutput
    }

    func commands() -> [String] {
        recorded
    }
}

private final class NameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String]
    init(_ names: [String]) { self.names = names }
    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        return names.count > 1 ? names.removeFirst() : names[0]
    }
}

@Test func rootHubDoesNotCountAsHub() {
    let drive: [String: Any] = [
        "bDeviceClass": 0, "USB Product Name": "Flash Drive", "Device Speed": 3, "locationID": 1_048_576,
    ]
    let rootHub: [String: Any] = ["bDeviceClass": 9, "USB Product Name": "USB 3.0 Root Hub Simulation"]
    let realHub: [String: Any] = ["bDeviceClass": 9, "USB Product Name": "USB3.0 Hub"]
    #expect(makeRoute(chain: [drive, rootHub], protocolName: "USB").hubInPath == false)
    let behindHub = makeRoute(chain: [drive, realHub, rootHub], protocolName: "USB")
    #expect(behindHub.hubInPath == true)
    #expect(behindHub.hubDepth == 1)
}

@Test func realDiskArbitrationUuidTypeIsConverted() {
    // DiskArbitration hands over a CFUUID, not a Swift UUID or String.
    let cfUUID = CFUUIDCreateFromString(kCFAllocatorDefault, "1612623E-D9A8-3D41-BC83-5E4C1AE4F53F" as CFString)!
    #expect(uuidString(cfUUID) == "1612623E-D9A8-3D41-BC83-5E4C1AE4F53F")
    #expect(
        uuidString(UUID(uuidString: "1612623E-D9A8-3D41-BC83-5E4C1AE4F53F")!) == "1612623E-D9A8-3D41-BC83-5E4C1AE4F53F")
    #expect(uuidString("ABC") == "ABC")
    #expect(uuidString(nil) == nil)

    let dict: [String: Any] = [
        String(kDADiskDescriptionMediaBSDNameKey): "disk4s1",
        String(kDADiskDescriptionVolumeUUIDKey): cfUUID,
        String(kDADiskDescriptionVolumeNameKey): "Khan",
        String(kDADiskDescriptionVolumeKindKey): "exfat",
        String(kDADiskDescriptionVolumePathKey): URL(fileURLWithPath: "/Volumes/Khan"),
        String(kDADiskDescriptionDeviceInternalKey): false,
        String(kDADiskDescriptionDeviceProtocolKey): "USB",
    ]
    let description = makeDescription(from: dict, mountFacts: nil)
    #expect(description?.volumeUUID == "1612623E-D9A8-3D41-BC83-5E4C1AE4F53F")
    #expect(description.flatMap { VolumeCatalog.makeVolume(from: $0) }?.name == "Khan")
}
