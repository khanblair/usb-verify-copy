import Foundation

public func parseUnmountBlockers(_ output: String) -> [String] {
    let pattern = #"dissented by PID\s+(\d+)\s+\(([^)]+)\)"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(output.startIndex..<output.endIndex, in: output)
    return expression.matches(in: output, range: range).compactMap { match in
        guard let pidRange = Range(match.range(at: 1), in: output),
            let pathRange = Range(match.range(at: 2), in: output),
            let pid = Int(output[pidRange])
        else { return nil }
        let process = URL(fileURLWithPath: String(output[pathRange])).lastPathComponent
        return "\(process) (pid \(pid))"
    }
}

public func isUnmountBusy(_ output: String) -> Bool {
    let lower = output.lowercased()
    return lower.contains("failed to unmount") || lower.contains("resource busy") || lower.contains("dissented")
}

public func parseMountPoint(fromInfoPlist data: Data) -> String? {
    guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
        let dictionary = plist as? [String: Any],
        let path = dictionary["MountPoint"] as? String,
        !path.isEmpty
    else { return nil }
    return path
}

public func isDiskGone(_ output: String) -> Bool {
    let lower = output.lowercased()
    return lower.contains("could not find disk") || lower.contains("unable to find disk")
}
