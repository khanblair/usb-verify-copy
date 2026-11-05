import Darwin
import Foundation

public struct DestinationGuard: Sendable {
    private let volume: Volume

    public init(volume: Volume) { self.volume = volume }

    public func path(folder: String, name: String) throws -> String {
        let components = folder.split(separator: "/", omittingEmptySubsequences: false)
        guard !folder.hasPrefix("/"), !components.contains(".."), !name.contains("/"), !name.contains("\0") else {
            throw VerifyError.destinationOutsideVolume(path: folder + "/" + name)
        }
        let result = URL(fileURLWithPath: volume.mountPath).appendingPathComponent(folder).appendingPathComponent(name)
            .path
        try validate(path: result)
        return result
    }

    public func validate(path: String) throws {
        guard volume.mountPath != "/", path.hasPrefix("/") else {
            throw VerifyError.destinationOutsideVolume(path: path)
        }
        let root = URL(fileURLWithPath: volume.mountPath).standardized.path
        let candidate = URL(fileURLWithPath: path).standardized.path
        guard candidate == root || candidate.hasPrefix(root + "/") else {
            throw VerifyError.destinationOutsideVolume(path: path)
        }
        if let resolvedRoot = realPath(root), let resolvedCandidate = resolveDeepestExisting(candidate) {
            guard resolvedCandidate == resolvedRoot || resolvedCandidate.hasPrefix(resolvedRoot + "/") else {
                throw VerifyError.destinationOutsideVolume(path: path)
            }
        }
    }

    public func relativeFolder(ofAbsolute folder: String) throws -> String {
        try validate(path: folder)
        let root = URL(fileURLWithPath: volume.mountPath).standardized.path
        let value = URL(fileURLWithPath: folder).standardized.path
        return value == root ? "" : String(value.dropFirst(root.count + 1))
    }

    public func isOnVolume(_ path: String) -> Bool { (try? validate(path: path)) != nil }

    private func realPath(_ path: String) -> String? {
        path.withCString { pointer in
            guard let value = Darwin.realpath(pointer, nil) else { return nil }
            defer { free(value) }
            return String(cString: value)
        }
    }

    private func resolveDeepestExisting(_ path: String) -> String? {
        var parts = path.split(separator: "/").map(String.init)
        var suffix: [String] = []
        while !parts.isEmpty {
            let prefix = "/" + parts.joined(separator: "/")
            if let resolved = realPath(prefix) {
                return URL(fileURLWithPath: resolved + suffix.reversed().map { "/" + $0 }.joined()).standardized.path
            }
            suffix.append(parts.removeLast())
        }
        return nil
    }
}
