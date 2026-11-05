import Foundation
import USBVerifyCore

// Observed with ioreg on 2026-11-05: USB devices expose "Device Speed", "USB Product Name",
// "locationID", "bDeviceClass", and "kUSBCurrentConfiguration". Ports expose "UsbProtocol (2.0)",
// "UsbProtocol (3.x)", "usb-port-number", and "locationID". Controllers use the IOClass
// AppleT8122USBXHCI. The requested "Protocol Characteristics" and "IOPropertyMatch" names were
// not present in the sampled output. Speed code mapping follows Apple's USB convention; code 5 and
// above is treated as 20 Gbps because the exact upper code mapping was not independently confirmed.

public func makeRoute(chain: [[String: Any]], protocolName: String) -> Route {
    let usbDevices = chain.filter { isUSBDevice($0) }
    let hubs = usbDevices.filter { numberValue($0["bDeviceClass"]) == 9 && !isRootHub($0) }
    let speedCode = chain.compactMap { numberValue($0["Device Speed"]) }.first
    let location = chain.compactMap { stringValue($0["locationID"]) ?? numberText($0["locationID"]) }.first
    return Route(
        protocolName: protocolName,
        hubInPath: usbDevices.isEmpty ? false : !hubs.isEmpty,
        hubDepth: usbDevices.isEmpty ? 0 : hubs.count,
        speedMbps: speedCode.flatMap(speedMbps(for:)),
        portLocation: location)
}

/// A root hub belongs to the Mac's own controller. A drive plugged straight into the Mac is not "behind a hub".
/// Real-hardware check is milestone M5 in docs/progress-tracker.md.
private func isRootHub(_ dictionary: [String: Any]) -> Bool {
    let name = (stringValue(dictionary["USB Product Name"]) ?? "").lowercased()
    let ioClass = (stringValue(dictionary["IOClass"]) ?? "").lowercased()
    return name.contains("root hub") || ioClass.contains("roothub")
}

private func isUSBDevice(_ dictionary: [String: Any]) -> Bool {
    if dictionary["bDeviceClass"] != nil { return true }
    return dictionary["USB Product Name"] != nil || dictionary["kUSBCurrentConfiguration"] != nil
}

private func speedMbps(for code: Int) -> Int? {
    switch code {
    case 0: return 1
    case 1: return 12
    case 2: return 480
    case 3: return 5_000
    case 4: return 10_000
    case 5...: return 20_000
    default: return nil
    }
}

private func numberValue(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    return nil
}

private func numberText(_ value: Any?) -> String? {
    guard let value = value as? NSNumber else { return nil }
    return String(value.intValue)
}

private func stringValue(_ value: Any?) -> String? {
    if let value = value as? String { return value }
    if let value = value as? NSString { return String(value) }
    return nil
}
