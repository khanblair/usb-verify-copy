/// Fixed numbers from docs/spec.md section 8 and 10.
public enum Defaults {
    /// Chunk size in bytes (64 MiB). A multiple of `alignment`.
    public static let chunkSize = 64 * 1024 * 1024
    /// Page size on Apple silicon. All buffers and offsets use this alignment.
    public static let alignment = 16 * 1024
    /// Reads and writes happen in slices of this size, so progress and pause checks run often (spec: progress at least once a second).
    public static let ioSliceSize = 4 * 1024 * 1024
    /// Rewrite attempts for a chunk whose read-back does not match.
    public static let maxRetries = 3
    /// Chunks re-read at the end of the temp file when a job resumes.
    public static let resumeTailChunks = 4
    /// A read-back faster than this is probably served from a cache.
    public static let cacheGuardBytesPerSecond = 1_000_000_000.0
    /// FAT32 stores sizes in 32 bits, so the largest file is 4 GiB minus 1 byte.
    public static let fat32MaxFileSize: Int64 = 4 * 1024 * 1024 * 1024 - 1
    /// exFAT file name limit in UTF-16 code units.
    public static let maxFileNameUTF16Units = 255
    public static let tempSuffix = ".usbverify-part"
    public static let failedSuffix = ".FAILED-partial"
    public static let capacityTestPrefix = "usbverify-test-"
    /// Largest exFAT volume label diskutil accepts.
    public static let maxVolumeLabelLength = 11
}
