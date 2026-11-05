/// The check after the remount (spec section 8): re-read the whole file from the drive and compare it with the source.
/// Used by copy and by verify-only.
struct FinalPassResult: Equatable {
    var badRanges: [BadRange]
    var rereadHash: String
    /// Whole-file source hash, only when the pass had to read the source itself (verify-only).
    var sourceHash: String?
}

enum FinalPass {
    /// - Parameters:
    ///   - expectedChunkHashes: source chunk hashes saved during the copy. When nil, the source is read here.
    ///   - interrupt: called between slices. It throws to stop the pass.
    ///   - progress: called with the bytes of this pass done so far.
    static func run(io: any DriveIO, sourcePath: String, destinationPath: String, plan: ChunkPlan,
                    expectedChunkHashes: [String]?, interrupt: () throws -> Void,
                    progress: (Int64) -> Void) throws -> FinalPassResult {
        let reader = try io.openReader(path: destinationPath)
        defer { reader.close() }
        let source = try io.openSource(path: sourcePath)
        defer { source.close() }

        let destBuffer = AlignedBuffer(capacity: max(plan.chunkSize, Defaults.alignment))
        let sourceBuffer = AlignedBuffer(capacity: max(plan.chunkSize, Defaults.alignment))
        var rereadHasher = StreamingHasher()
        var sourceHasher = StreamingHasher()
        var bad: [BadRange] = []
        var done: Int64 = 0

        for index in 0..<plan.count {
            let offset = plan.offset(of: index)
            let length = plan.length(of: index)
            let got = try ChunkIO.readDestination(reader, into: destBuffer, offset: offset, length: length) { sliceBytes in
                try interrupt()
                done += Int64(sliceBytes)
                progress(done)
            }
            rereadHasher.update(destBuffer.bytes(count: got))

            var expected = expectedChunkHashes.flatMap { index < $0.count ? $0[index] : nil }
            var haveSourceChunk = false
            if expected == nil {
                let read = try ChunkIO.readSource(source, into: sourceBuffer, offset: offset, length: length) { _ in try interrupt() }
                if read != length { throw VerifyError.sourceChanged }
                sourceHasher.update(sourceBuffer.bytes(count: length))
                expected = StreamingHasher.hash(of: sourceBuffer.bytes(count: length))
                haveSourceChunk = true
            }

            if got < length {
                bad.append(BadRange(offset: offset + Int64(got), length: Int64(length - got)))
            }
            let actual = StreamingHasher.hash(of: destBuffer.bytes(count: got))
            if got == length, actual == expected { continue }

            // Mismatch: find the exact differing bytes by comparing with the source chunk.
            if !haveSourceChunk {
                let read = try ChunkIO.readSource(source, into: sourceBuffer, offset: offset, length: length) { _ in try interrupt() }
                if read != length { throw VerifyError.sourceChanged }
            }
            let comparable = min(got, length)
            for range in sourceBuffer.differences(from: destBuffer, count: comparable) {
                bad.append(BadRange(offset: offset + range.offset, length: range.length))
            }
        }

        if reader.size > plan.size {
            bad.append(BadRange(offset: plan.size, length: reader.size - plan.size))
        }
        return FinalPassResult(badRanges: ChunkIO.merge(bad), rereadHash: rereadHasher.finalize(),
                               sourceHash: expectedChunkHashes == nil ? sourceHasher.finalize() : nil)
    }
}
