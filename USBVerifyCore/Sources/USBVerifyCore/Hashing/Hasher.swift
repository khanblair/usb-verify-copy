import CryptoKit

/// Streaming SHA-256. Hex strings are lower case.
public struct StreamingHasher: Sendable {
    private var sha = SHA256()
    public init() {}

    public mutating func update(_ bytes: UnsafeRawBufferPointer) {
        sha.update(bufferPointer: bytes)
    }

    public func finalize() -> String {
        Self.hex(sha.finalize())
    }

    public static func hash(of bytes: UnsafeRawBufferPointer) -> String {
        hex(SHA256.hash(data: bytes))
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        let table = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(64)
        for byte in digest {
            out.append(table[Int(byte >> 4)])
            out.append(table[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}
