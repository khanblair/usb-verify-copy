/// Name rules for exFAT and FAT32. Exact rules are confirmed later, so they live in this one place.
private let forbiddenNameScalars: Set<Unicode.Scalar> = [
    "\"", "*", "/", ":", "<", ">", "?", "\\", "|",
]

private func isControl(_ scalar: Unicode.Scalar) -> Bool {
    scalar.value <= 0x1F || scalar.value == 0x7F
}

private func isBadScalar(_ scalar: Unicode.Scalar) -> Bool {
    isControl(scalar) || forbiddenNameScalars.contains(scalar)
}

private func stripTrailingSpacesAndDots(_ text: String) -> String {
    var result = text
    while let last = result.unicodeScalars.last, last == " " || last == "." {
        result.unicodeScalars.removeLast()
    }
    return result
}

/// Keeps whole characters while their UTF-16 length fits the limit.
private func cut(_ text: String, toUTF16Units limit: Int) -> String {
    var result = ""
    var used = 0
    for character in text {
        let width = String(character).utf16.count
        if used + width > limit { break }
        result.append(character)
        used += width
    }
    return result
}

public enum FileNameRules {
    /// nil when the name is fine, else a short plain-English reason.
    public static func problem(with name: String) -> String? {
        if name.isEmpty {
            return "The name is empty."
        }
        if name == "." || name == ".." {
            return "The name cannot be a single dot or two dots."
        }
        if name.utf16.count > Defaults.maxFileNameUTF16Units {
            return "The name is longer than \(Defaults.maxFileNameUTF16Units) characters."
        }
        if name.unicodeScalars.contains(where: isControl) {
            return "The name contains a control character."
        }
        if let bad = name.unicodeScalars.first(where: { forbiddenNameScalars.contains($0) }) {
            return "The name contains a character that is not allowed: \(bad)"
        }
        if let last = name.unicodeScalars.last, last == " " {
            return "The name ends with a space."
        }
        if let last = name.unicodeScalars.last, last == "." {
            return "The name ends with a dot."
        }
        return nil
    }

    /// A safe replacement: bad characters become "_", trailing dots and spaces are removed, the name is cut to the limit keeping the extension. Never returns an empty string (use "file").
    public static func suggestedName(for name: String) -> String {
        let limit = Defaults.maxFileNameUTF16Units

        var replaced = ""
        for scalar in name.unicodeScalars {
            replaced.unicodeScalars.append(isBadScalar(scalar) ? "_" : scalar)
        }
        var base = stripTrailingSpacesAndDots(replaced)

        if base.utf16.count > limit {
            var stem = base
            var ext = ""
            if let dot = base.lastIndex(of: "."), dot != base.startIndex {
                let candidate = String(base[dot...])
                if candidate.utf16.count < limit - 1 {
                    stem = String(base[..<dot])
                    ext = candidate
                }
            }
            base = stripTrailingSpacesAndDots(cut(stem, toUTF16Units: limit - ext.utf16.count)) + ext
        }

        base = stripTrailingSpacesAndDots(base)
        return base.isEmpty ? "file" : base
    }
}
