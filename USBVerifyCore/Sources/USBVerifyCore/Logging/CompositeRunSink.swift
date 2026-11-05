import Foundation

public struct CompositeRunSink: RunSink {
    public let sinks: [any RunSink]

    public init(_ sinks: [any RunSink]) {
        self.sinks = sinks
    }

    public init(sinks: [any RunSink] = []) {
        self.sinks = sinks
    }

    public func record(_ run: RunRecord) async {
        for sink in sinks {
            await sink.record(run)
        }
    }
}
