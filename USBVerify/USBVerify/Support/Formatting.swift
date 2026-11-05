import Foundation
import USBVerifyCore

enum Formatting {
    static func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }

    static func rate(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "—" }
        return bytes(Int64(value)) + "/s"
    }

    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return "Calculating time" }
        let total = max(0, Int(seconds.rounded()))
        return total >= 60 ? "\(total / 60)m \(total % 60)s left" : "\(total)s left"
    }

    static func hex(_ value: Int64) -> String { "0x" + String(value, radix: 16, uppercase: true) }

    static func route(_ route: Route?) -> String {
        guard let route else { return "Route unknown" }
        let path = route.hubInPath == true ? "via hub or adapter" : "direct port"
        let speed = route.speedMbps.map { $0 >= 5_000 ? " · USB 3" : " · USB 2" } ?? ""
        return "\(route.protocolName) · \(path)\(speed)"
    }
}
