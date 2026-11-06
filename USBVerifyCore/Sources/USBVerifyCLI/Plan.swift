import Foundation
import USBVerifyCore

public enum Plan {
    public static func keepBothName(_ name: String, existing: (String) -> Bool) -> String {
        let url = URL(fileURLWithPath: name)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"
        var number = 2
        var candidate = "\(base) \(number)\(ext)"
        while existing(candidate) {
            number += 1
            candidate = "\(base) \(number)\(ext)"
        }
        return candidate
    }

    public static func estimateText(bytes: Int64, mode: VerifyMode, speedBytesPerSecond: Double = 25_000_000) -> String
    {
        let passes = mode == .strict ? 3.0 : 2.0
        let seconds = Double(max(bytes, 0)) * passes / max(speedBytesPerSecond, 1)
        return "about \(Int(seconds / 60.0).formatted()) min"
    }
}
