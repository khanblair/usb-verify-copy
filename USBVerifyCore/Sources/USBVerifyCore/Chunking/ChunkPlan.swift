/// Splits a file of `size` bytes into chunks of `chunkSize` bytes. The last chunk may be shorter.
public struct ChunkPlan: Equatable, Sendable {
    public let size: Int64
    public let chunkSize: Int

    public init(size: Int64, chunkSize: Int = Defaults.chunkSize) {
        precondition(chunkSize > 0 && chunkSize % Defaults.alignment == 0, "chunkSize must be a multiple of the alignment")
        precondition(size >= 0, "size must not be negative")
        self.size = size
        self.chunkSize = chunkSize
    }

    public var count: Int {
        size == 0 ? 0 : Int((size + Int64(chunkSize) - 1) / Int64(chunkSize))
    }

    public func offset(of index: Int) -> Int64 { Int64(index) * Int64(chunkSize) }

    public func length(of index: Int) -> Int {
        precondition(index >= 0 && index < count, "chunk index out of range")
        return Int(min(Int64(chunkSize), size - offset(of: index)))
    }

    public func range(of index: Int) -> BadRange {
        BadRange(offset: offset(of: index), length: Int64(length(of: index)))
    }

    /// Index of the chunk that holds the byte at `offset`.
    public func index(containing offset: Int64) -> Int {
        precondition(offset >= 0 && offset < size, "offset out of range")
        return Int(offset / Int64(chunkSize))
    }
}
