import AppKit
import Foundation
import IOKit.ps
import USBVerifyCore

public final class ProcessPowerGuard: PowerGuard, @unchecked Sendable {
    public init() {}

    public func begin(reason: String) -> any PowerToken {
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: reason)
        return ActivityToken(activity: activity)
    }

    public func wakeEvents() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let box = ObserverBox()
            box.token = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: nil
            ) { _ in continuation.yield(()) }
            continuation.onTermination = { _ in
                if let token = box.token {
                    NSWorkspace.shared.notificationCenter.removeObserver(token)
                }
            }
        }
    }

    public var isOnBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        else { return false }
        return type == kIOPMBatteryPowerKey
    }

    private final class ActivityToken: PowerToken, @unchecked Sendable {
        private let lock = NSLock()
        private var activity: NSObjectProtocol?

        init(activity: NSObjectProtocol) {
            self.activity = activity
        }

        func end() {
            lock.lock()
            guard let activity else {
                lock.unlock()
                return
            }
            self.activity = nil
            lock.unlock()
            ProcessInfo.processInfo.endActivity(activity)
        }
    }

    private final class ObserverBox: @unchecked Sendable {
        var token: NSObjectProtocol?
    }
}
