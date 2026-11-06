import USBVerifyCore

public enum DriveResolver {
    public static func resolve(_ selector: DriveSelector, from volumes: [Volume]) throws -> Volume {
        if let number = Int(selector.value), number > 0 {
            guard volumes.indices.contains(number - 1) else {
                throw CLIError.operational("No drive has number \(number).")
            }
            return volumes[number - 1]
        }
        let matches = volumes.filter {
            $0.id.uuid.caseInsensitiveCompare(selector.value) == .orderedSame || $0.name == selector.value
        }
        guard matches.count == 1 else {
            if matches.count > 1 {
                let ids = matches.map { $0.id.uuid }.joined(separator: ", ")
                throw CLIError.operational("Drive name is ambiguous. Matching volume UUIDs: \(ids)")
            }
            throw CLIError.operational("Drive \(selector.value) was not found in the volume catalog.")
        }
        return matches[0]
    }
}
