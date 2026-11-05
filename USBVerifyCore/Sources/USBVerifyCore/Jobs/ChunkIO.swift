/// Sliced reads and writes. A 64 MiB chunk is moved in 4 MiB slices, so progress and pause checks run
/// several times per second even on a slow drive.
enum ChunkIO {
    /// Fills `buffer` from `source`. Returns the bytes read; fewer than `length` only at end of file.
    static func readSource(_ source: any SourceFile, into buffer: AlignedBuffer, offset: Int64, length: Int,
                           onSlice: (Int) throws -> Void) throws -> Int {
        var done = 0
        while done < length {
            let count = min(Defaults.ioSliceSize, length - done)
            let slice = UnsafeMutableRawBufferPointer(rebasing: buffer.mutableBytes(count: length)[done..<(done + count)])
            let got = try source.read(into: slice, at: offset + Int64(done))
            done += got
            try onSlice(got)
            if got < count { break }
        }
        return done
    }

    static func readDestination(_ reader: any DestinationReader, into buffer: AlignedBuffer, offset: Int64, length: Int,
                                onSlice: (Int) throws -> Void) throws -> Int {
        var done = 0
        while done < length {
            let count = min(Defaults.ioSliceSize, length - done)
            let slice = UnsafeMutableRawBufferPointer(rebasing: buffer.mutableBytes(count: length)[done..<(done + count)])
            let got = try reader.read(into: slice, at: offset + Int64(done))
            done += got
            try onSlice(got)
            if got < count { break }
        }
        return done
    }

    static func write(_ writer: any DestinationWriter, from buffer: AlignedBuffer, offset: Int64, length: Int,
                      onSlice: (Int) throws -> Void) throws {
        var done = 0
        while done < length {
            let count = min(Defaults.ioSliceSize, length - done)
            let slice = UnsafeRawBufferPointer(rebasing: buffer.bytes(count: length)[done..<(done + count)])
            try writer.write(slice, at: offset + Int64(done))
            done += count
            try onSlice(count)
        }
    }

    /// Sorts and merges touching or overlapping ranges.
    static func merge(_ ranges: [BadRange]) -> [BadRange] {
        let sorted = ranges.sorted { $0.offset < $1.offset }
        var out: [BadRange] = []
        for range in sorted {
            if let last = out.last, range.offset <= last.end {
                out[out.count - 1].length = max(last.end, range.end) - last.offset
            } else {
                out.append(range)
            }
        }
        return out
    }
}
