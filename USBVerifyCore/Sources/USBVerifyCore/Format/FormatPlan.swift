import Foundation

public enum FormatPlan {
    /// nil when valid, else a short plain-English reason. Valid: 1 to 11 characters from letters, digits, space, hyphen, underscore. Not all spaces.
    public static func labelProblem(_ label: String) -> String? {
        if label.isEmpty {
            return "The label cannot be empty."
        }
        if label.count > Defaults.maxVolumeLabelLength {
            return "The label must be \(Defaults.maxVolumeLabelLength) characters or fewer."
        }
        if label.allSatisfy({ $0 == " " }) {
            return "The label cannot be all spaces."
        }
        // Check Unicode scalars, not Characters: a letter plus a combining mark is one Character
        // but is not plain ASCII.
        for scalar in label.unicodeScalars {
            let isLetter =
                (scalar.value >= 0x41 && scalar.value <= 0x5A) || (scalar.value >= 0x61 && scalar.value <= 0x7A)
            let isDigit = scalar.value >= 0x30 && scalar.value <= 0x39
            let isAllowedPunct = scalar == " " || scalar == "-" || scalar == "_"
            if !isLetter && !isDigit && !isAllowedPunct {
                return "The label may only contain letters, digits, spaces, hyphens, and underscores."
            }
        }
        return nil
    }

    /// True for "disk" followed by digits only, for example "disk9". Nothing else.
    public static func isValidBSDName(_ s: String) -> Bool {
        guard s.hasPrefix("disk") else { return false }
        let rest = s.dropFirst(4)
        guard !rest.isEmpty else { return false }
        return rest.unicodeScalars.allSatisfy { $0.value >= 0x30 && $0.value <= 0x39 }
    }

    /// Generic means: empty or only spaces, "Untitled", "Untitled 1", "NO NAME" (case-insensitive), or the same name used by another volume in `others`.
    public static func isGenericName(_ name: String, among others: [String]) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        let lower = trimmed.lowercased()
        if lower == "untitled" || lower == "untitled 1" || lower == "no name" {
            return true
        }
        return others.contains { other in
            other.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    /// The text the user may type to confirm: the whole disk BSD name always works; the drive name works only when it is not generic.
    public static func confirmationMatches(typed: String, volume: Volume, otherNames: [String]) -> Bool {
        let clean = typed.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return false }
        if clean == volume.wholeDiskBSDName {
            return true
        }
        if !isGenericName(volume.name, among: otherNames) {
            if clean.caseInsensitiveCompare(volume.name.trimmingCharacters(in: .whitespaces)) == .orderedSame {
                return true
            }
        }
        return false
    }

    /// ["eraseDisk", "ExFAT", label, "MBR", wholeDisk]. Throws VerifyError.formatRefused when the label or BSD name is invalid.
    public static func arguments(wholeDisk: String, label: String) throws -> [String] {
        guard isValidBSDName(wholeDisk) else {
            throw VerifyError.formatRefused(reason: "Invalid BSD disk name: \(wholeDisk)")
        }
        if let problem = labelProblem(label) {
            throw VerifyError.formatRefused(reason: problem)
        }
        return ["eraseDisk", "ExFAT", label, "MBR", wholeDisk]
    }

    /// Single-quote a value for a shell string: wrap in single quotes and replace each ' with '\''.
    public static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Throws VerifyError.formatRefused unless: the volume has no running or paused job (`busyVolumes` does not contain it), the freshly read volume has the same id, whole disk name and size as the one the user confirmed, and the BSD name is valid.
    public static func checkBeforeErase(confirmed: Volume, fresh: Volume?, busyVolumes: Set<VolumeID>) throws {
        if busyVolumes.contains(confirmed.id) {
            throw VerifyError.formatRefused(reason: "The volume has a running or paused job.")
        }
        guard let fresh else {
            throw VerifyError.formatRefused(reason: "The volume is no longer connected.")
        }
        guard fresh.id == confirmed.id else {
            throw VerifyError.formatRefused(reason: "Volume ID changed.")
        }
        guard fresh.wholeDiskBSDName == confirmed.wholeDiskBSDName else {
            throw VerifyError.formatRefused(reason: "Whole disk BSD name changed.")
        }
        guard fresh.totalBytes == confirmed.totalBytes else {
            throw VerifyError.formatRefused(reason: "Volume size changed.")
        }
        guard isValidBSDName(fresh.wholeDiskBSDName) else {
            throw VerifyError.formatRefused(reason: "Invalid BSD disk name: \(fresh.wholeDiskBSDName)")
        }
    }
}
