import Foundation

/// Flags the UI sets and the engine polls between I/O slices. Lock protected, so it is safe to call from any thread.
public final class JobControl: @unchecked Sendable {
    private let lock = NSLock()
    private var pause: PauseReason?
    private var cancelled = false
    private var retryRequested = false

    public init() {}

    public func requestPause(_ reason: PauseReason) {
        lock.lock(); defer { lock.unlock() }
        if pause == nil { pause = reason }
    }

    public func requestCancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }

    /// The user pressed Retry while the job waits for an unmount.
    public func requestUnmountRetry() {
        lock.lock(); defer { lock.unlock() }
        retryRequested = true
    }

    public var pendingPause: PauseReason? {
        lock.lock(); defer { lock.unlock() }
        return pause
    }

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Returns true once for each retry request.
    func takeRetry() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let value = retryRequested
        retryRequested = false
        return value
    }

    /// Clears a pause request so the same control can drive a resumed job.
    public func clearPause() {
        lock.lock(); defer { lock.unlock() }
        pause = nil
    }
}
