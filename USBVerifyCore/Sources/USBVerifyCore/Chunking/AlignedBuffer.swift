import Darwin

/// A heap buffer aligned to `Defaults.alignment`, so `F_NOCACHE` I/O stays on the direct path.
public final class AlignedBuffer: @unchecked Sendable {
    public let capacity: Int
    private let base: UnsafeMutableRawPointer

    public init(capacity: Int = Defaults.chunkSize) {
        precondition(capacity > 0, "capacity must be positive")
        var raw: UnsafeMutableRawPointer?
        let rc = posix_memalign(&raw, Defaults.alignment, capacity)
        precondition(rc == 0 && raw != nil, "posix_memalign failed")
        base = raw!
        self.capacity = capacity
    }

    deinit { free(base) }

    public var mutableBytes: UnsafeMutableRawBufferPointer {
        UnsafeMutableRawBufferPointer(start: base, count: capacity)
    }

    public func mutableBytes(count: Int) -> UnsafeMutableRawBufferPointer {
        precondition(count <= capacity, "count exceeds capacity")
        return UnsafeMutableRawBufferPointer(start: base, count: count)
    }

    public func bytes(count: Int) -> UnsafeRawBufferPointer {
        precondition(count <= capacity, "count exceeds capacity")
        return UnsafeRawBufferPointer(start: base, count: count)
    }

    /// True when both buffers hold the same first `count` bytes.
    public func equals(_ other: AlignedBuffer, count: Int) -> Bool {
        memcmp(base, other.base, count) == 0
    }

    /// Byte ranges (relative to the buffer start) where the first `count` bytes differ from `other`.
    /// Adjacent differing bytes are merged into one range.
    public func differences(from other: AlignedBuffer, count: Int) -> [BadRange] {
        var ranges: [BadRange] = []
        let a = bytes(count: count)
        let b = other.bytes(count: count)
        var i = 0
        while i < count {
            if a[i] != b[i] {
                let start = i
                while i < count && a[i] != b[i] { i += 1 }
                ranges.append(BadRange(offset: Int64(start), length: Int64(i - start)))
            } else {
                i += 1
            }
        }
        return ranges
    }
}
