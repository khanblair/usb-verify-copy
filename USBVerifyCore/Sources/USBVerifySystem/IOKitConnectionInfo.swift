import Foundation
import IOKit
import USBVerifyCore

public final class IOKitConnectionInfo: ConnectionInfoProvider, @unchecked Sendable {
    public init() {}

    public func route(forWholeDisk bsdName: String) async -> Route? {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var chain: [[String: Any]] = []
        var current = service
        while current != 0 {
            if let properties = properties(of: current) { chain.append(properties) }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
            if current != service { IOObjectRelease(current) }
            current = parent
        }
        if current != service, current != 0 { IOObjectRelease(current) }
        let protocolName = chain.compactMap { $0["Physical Interconnect"] as? String }.first ?? "Unknown"
        return makeRoute(chain: chain, protocolName: protocolName)
    }

    private func properties(of entry: io_registry_entry_t) -> [String: Any]? {
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
            let properties
        else { return nil }
        return properties.takeRetainedValue() as? [String: Any]
    }
}
