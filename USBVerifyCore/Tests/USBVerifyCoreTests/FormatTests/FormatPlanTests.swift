import Foundation
import Testing

@testable import USBVerifyCore

@Suite struct FormatPlanTests {
    @Test func labelProblemValidation() {
        // Valid labels (1 to 11 chars: letters, digits, space, hyphen, underscore; not all spaces)
        #expect(FormatPlan.labelProblem("Khan") == nil)
        #expect(FormatPlan.labelProblem("MY_DISK") == nil)
        #expect(FormatPlan.labelProblem("DISK-1") == nil)
        #expect(FormatPlan.labelProblem("USB DRIVE") == nil)
        #expect(FormatPlan.labelProblem("12345678901") == nil)
        #expect(FormatPlan.labelProblem("A") == nil)
        #expect(FormatPlan.labelProblem("A_B-C 1") == nil)

        // Invalid: empty
        #expect(FormatPlan.labelProblem("") != nil)

        // Invalid: all spaces
        #expect(FormatPlan.labelProblem(" ") != nil)
        #expect(FormatPlan.labelProblem("   ") != nil)

        // Invalid: longer than 11 characters
        #expect(FormatPlan.labelProblem("123456789012") != nil)
        #expect(FormatPlan.labelProblem("TOOLONGNAME!") != nil)

        // Invalid: injection attempts and bad characters
        #expect(FormatPlan.labelProblem("A; rm -rf /") != nil)
        #expect(FormatPlan.labelProblem("disk9; x") != nil)
        #expect(FormatPlan.labelProblem("test'") != nil)
        #expect(FormatPlan.labelProblem("test\"") != nil)
        #expect(FormatPlan.labelProblem("test`") != nil)
        #expect(FormatPlan.labelProblem("test$var") != nil)
        #expect(FormatPlan.labelProblem("test|cmd") != nil)
        #expect(FormatPlan.labelProblem("test&cmd") != nil)
        #expect(FormatPlan.labelProblem("test/slash") != nil)
        #expect(FormatPlan.labelProblem("test\\slash") != nil)
        #expect(FormatPlan.labelProblem("test*star") != nil)
        #expect(FormatPlan.labelProblem("test?query") != nil)
    }

    @Test func isValidBSDNameRules() {
        // Valid: disk followed by digits only
        #expect(FormatPlan.isValidBSDName("disk0"))
        #expect(FormatPlan.isValidBSDName("disk9"))
        #expect(FormatPlan.isValidBSDName("disk10"))
        #expect(FormatPlan.isValidBSDName("disk999"))

        // Invalid: missing digits
        #expect(!FormatPlan.isValidBSDName("disk"))

        // Invalid: uppercase
        #expect(!FormatPlan.isValidBSDName("DISK9"))
        #expect(!FormatPlan.isValidBSDName("Disk9"))

        // Invalid: injection attempts
        #expect(!FormatPlan.isValidBSDName("disk9; x"))
        #expect(!FormatPlan.isValidBSDName("disk9; rm -rf /"))
        #expect(!FormatPlan.isValidBSDName("disk9 && echo"))

        // Invalid: partition name, not whole disk
        #expect(!FormatPlan.isValidBSDName("disk9s1"))
        #expect(!FormatPlan.isValidBSDName("disk9s2"))

        // Invalid: raw disk or other prefixes
        #expect(!FormatPlan.isValidBSDName("rdisk9"))
        #expect(!FormatPlan.isValidBSDName("/dev/disk9"))
        #expect(!FormatPlan.isValidBSDName(""))
        #expect(!FormatPlan.isValidBSDName("disk "))
        #expect(!FormatPlan.isValidBSDName("disk9 "))
        #expect(!FormatPlan.isValidBSDName("other"))
    }

    @Test func isGenericNameDetection() {
        // Empty or only spaces
        #expect(FormatPlan.isGenericName("", among: []))
        #expect(FormatPlan.isGenericName("   ", among: []))

        // Untitled (case-insensitive)
        #expect(FormatPlan.isGenericName("Untitled", among: []))
        #expect(FormatPlan.isGenericName("untitled", among: []))
        #expect(FormatPlan.isGenericName("UNTITLED", among: []))
        #expect(FormatPlan.isGenericName(" Untitled ", among: []))

        // Untitled 1 (case-insensitive)
        #expect(FormatPlan.isGenericName("Untitled 1", among: []))
        #expect(FormatPlan.isGenericName("untitled 1", among: []))
        #expect(FormatPlan.isGenericName("UNTITLED 1", among: []))

        // NO NAME (case-insensitive)
        #expect(FormatPlan.isGenericName("NO NAME", among: []))
        #expect(FormatPlan.isGenericName("no name", among: []))
        #expect(FormatPlan.isGenericName("No Name", among: []))

        // Non-generic unique name
        #expect(!FormatPlan.isGenericName("Khan", among: ["Backups", "Data"]))
        #expect(!FormatPlan.isGenericName("PlayStation", among: []))

        // Same name used by another volume in others (case-insensitive)
        #expect(FormatPlan.isGenericName("Khan", among: ["Khan"]))
        #expect(FormatPlan.isGenericName("Khan", among: ["khan"]))
        #expect(FormatPlan.isGenericName("Khan", among: ["KHAN"]))
        #expect(FormatPlan.isGenericName("Khan", among: ["Backups", "Khan"]))
    }

    @Test func confirmationMatchesRules() {
        let uniqueVolume = Volume(
            id: VolumeID("vol-1"),
            name: "Khan",
            mountPath: "/Volumes/Khan",
            bsdName: "disk9s1",
            wholeDiskBSDName: "disk9",
            protocolName: "USB",
            filesystem: .exfat,
            totalBytes: 64_000_000_000,
            freeBytes: 32_000_000_000
        )

        // Whole disk BSD name always works (trimmed, case-sensitive)
        #expect(FormatPlan.confirmationMatches(typed: "disk9", volume: uniqueVolume, otherNames: []))
        #expect(FormatPlan.confirmationMatches(typed: "  disk9  ", volume: uniqueVolume, otherNames: []))
        #expect(!FormatPlan.confirmationMatches(typed: "DISK9", volume: uniqueVolume, otherNames: []))
        #expect(!FormatPlan.confirmationMatches(typed: "disk9s1", volume: uniqueVolume, otherNames: []))

        // Drive name works when not generic (trimmed, case-insensitive)
        #expect(FormatPlan.confirmationMatches(typed: "Khan", volume: uniqueVolume, otherNames: []))
        #expect(FormatPlan.confirmationMatches(typed: "khan", volume: uniqueVolume, otherNames: []))
        #expect(FormatPlan.confirmationMatches(typed: "  KHAN  ", volume: uniqueVolume, otherNames: []))
        #expect(!FormatPlan.confirmationMatches(typed: "Wrong", volume: uniqueVolume, otherNames: []))

        // When drive name is generic, drive name is refused; only wholeDiskBSDName works
        let genericVolume = Volume(
            id: VolumeID("vol-2"),
            name: "Untitled",
            mountPath: "/Volumes/Untitled",
            bsdName: "disk9s1",
            wholeDiskBSDName: "disk9",
            protocolName: "USB",
            filesystem: .exfat,
            totalBytes: 64_000_000_000,
            freeBytes: 32_000_000_000
        )
        #expect(!FormatPlan.confirmationMatches(typed: "Untitled", volume: genericVolume, otherNames: []))
        #expect(!FormatPlan.confirmationMatches(typed: "untitled", volume: genericVolume, otherNames: []))
        #expect(FormatPlan.confirmationMatches(typed: "disk9", volume: genericVolume, otherNames: []))

        // When name is shared with another volume, it is generic and name confirmation is refused
        #expect(!FormatPlan.confirmationMatches(typed: "Khan", volume: uniqueVolume, otherNames: ["Khan"]))
        #expect(FormatPlan.confirmationMatches(typed: "disk9", volume: uniqueVolume, otherNames: ["Khan"]))
    }

    @Test func argumentsBuilder() throws {
        // Valid arguments
        let args = try FormatPlan.arguments(wholeDisk: "disk9", label: "MY_DISK")
        #expect(args == ["eraseDisk", "ExFAT", "MY_DISK", "MBR", "disk9"])

        // Refused on invalid BSD name
        #expect(throws: VerifyError.self) {
            _ = try FormatPlan.arguments(wholeDisk: "disk", label: "VALID")
        }
        #expect(throws: VerifyError.self) {
            _ = try FormatPlan.arguments(wholeDisk: "disk9s1", label: "VALID")
        }
        #expect(throws: VerifyError.self) {
            _ = try FormatPlan.arguments(wholeDisk: "disk9; rm -rf /", label: "VALID")
        }

        // Refused on invalid label
        #expect(throws: VerifyError.self) {
            _ = try FormatPlan.arguments(wholeDisk: "disk9", label: "")
        }
        #expect(throws: VerifyError.self) {
            _ = try FormatPlan.arguments(wholeDisk: "disk9", label: "   ")
        }
        #expect(throws: VerifyError.self) {
            _ = try FormatPlan.arguments(wholeDisk: "disk9", label: "A; rm -rf /")
        }
        #expect(throws: VerifyError.self) {
            _ = try FormatPlan.arguments(wholeDisk: "disk9", label: "TOO_LONG_LABEL")
        }
    }

    @Test func shellQuoting() {
        #expect(FormatPlan.shellQuoted("disk9") == "'disk9'")
        #expect(FormatPlan.shellQuoted("my disk") == "'my disk'")
        #expect(FormatPlan.shellQuoted("don't") == "'don'\\''t'")
        #expect(FormatPlan.shellQuoted("'") == "''\\'''")
        #expect(FormatPlan.shellQuoted("A; rm -rf /") == "'A; rm -rf /'")
        #expect(FormatPlan.shellQuoted("") == "''")
        #expect(FormatPlan.shellQuoted("'quoted'") == "''\\''quoted'\\'''")
    }

    @Test func checkBeforeEraseValidations() throws {
        let confirmed = Volume(
            id: VolumeID("vol-target"),
            name: "Khan",
            mountPath: "/Volumes/Khan",
            bsdName: "disk9s1",
            wholeDiskBSDName: "disk9",
            protocolName: "USB",
            filesystem: .exfat,
            totalBytes: 64_000_000_000,
            freeBytes: 32_000_000_000
        )

        // Happy path: fresh matches confirmed, not busy
        let fresh = confirmed
        try FormatPlan.checkBeforeErase(confirmed: confirmed, fresh: fresh, busyVolumes: [])

        // Busy volume
        #expect(throws: VerifyError.self) {
            try FormatPlan.checkBeforeErase(confirmed: confirmed, fresh: fresh, busyVolumes: [VolumeID("vol-target")])
        }

        // Fresh is nil (disconnected)
        #expect(throws: VerifyError.self) {
            try FormatPlan.checkBeforeErase(confirmed: confirmed, fresh: nil, busyVolumes: [])
        }

        // Volume ID changed
        var freshDifferentID = confirmed
        freshDifferentID.id = VolumeID("vol-other")
        #expect(throws: VerifyError.self) {
            try FormatPlan.checkBeforeErase(confirmed: confirmed, fresh: freshDifferentID, busyVolumes: [])
        }

        // Whole disk BSD name changed
        var freshDifferentBSD = confirmed
        freshDifferentBSD.wholeDiskBSDName = "disk10"
        #expect(throws: VerifyError.self) {
            try FormatPlan.checkBeforeErase(confirmed: confirmed, fresh: freshDifferentBSD, busyVolumes: [])
        }

        // Size changed
        var freshDifferentSize = confirmed
        freshDifferentSize.totalBytes = 32_000_000_000
        #expect(throws: VerifyError.self) {
            try FormatPlan.checkBeforeErase(confirmed: confirmed, fresh: freshDifferentSize, busyVolumes: [])
        }

        // Invalid BSD name on fresh volume
        var freshBadBSD = confirmed
        freshBadBSD.wholeDiskBSDName = "disk9s1"
        #expect(throws: VerifyError.self) {
            try FormatPlan.checkBeforeErase(confirmed: confirmed, fresh: freshBadBSD, busyVolumes: [])
        }
    }
}

@Test func combiningMarksAreNotAsciiLetters() {
    #expect(FormatPlan.labelProblem("a\u{0323}") != nil)
    #expect(FormatPlan.labelProblem("A1 -_b") == nil)
    #expect(!FormatPlan.isValidBSDName("disk9\u{0301}"))
    #expect(FormatPlan.isValidBSDName("disk12"))
}
