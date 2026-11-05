import Foundation
import USBVerifyCore

@MainActor
final class JobCoordinator {
    private struct QueuedRun {
        var job: PersistedJob
        var volume: Volume
    }

    private let dependencies: AppDependencies
    private var queue: [QueuedRun] = []
    private var runner: JobRunner?
    private var activeRun: Task<JobSummary, Never>?
    private var powerToken: (any PowerToken)?
    private var subscribers: [String: [AsyncStream<JobEvent>.Continuation]] = [:]
    private var savedRunners: [String: JobRunner] = [:]
    private var completionWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var knownVolumes: [VolumeID: Volume] = [:]

    var jobs: [PersistedJob] = []
    var snapshots: [String: ProgressSnapshot] = [:]
    var isRunning: Bool { runner != nil }
    var activeJobID: String? { runner?.currentJob.id }

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        jobs = (try? dependencies.jobStore.loadAll()) ?? []
        for index in jobs.indices where jobs[index].pausedReason == nil && !isFinished(jobs[index]) {
            jobs[index].pausedReason = .appQuit
            for fileIndex in jobs[index].files.indices where jobs[index].files[fileIndex].result == nil {
                jobs[index].files[fileIndex].phase = .paused
            }
            try? dependencies.jobStore.save(jobs[index])
        }
    }

    func events(for jobID: String) -> AsyncStream<JobEvent> {
        AsyncStream { continuation in
            subscribers[jobID, default: []].append(continuation)
        }
    }

    func setCurrentVolumes(_ volumes: [Volume]) {
        knownVolumes = Dictionary(uniqueKeysWithValues: volumes.map { ($0.id, $0) })
    }

    func start(_ job: PersistedJob, volume: Volume) {
        jobs.append(job)
        queue.append(QueuedRun(job: job, volume: volume))
        startNextIfNeeded()
    }

    func resume(_ job: PersistedJob, volume: Volume) {
        queue.append(QueuedRun(job: job, volume: volume))
        startNextIfNeeded()
    }

    func requestPause(_ reason: PauseReason) { runner?.control.requestPause(reason) }
    func requestCancel() { runner?.control.requestCancel() }
    func retryUnmount() { runner?.control.requestUnmountRetry() }

    func cancel(jobID: String, deletePartial: Bool) async {
        guard let active = runner, active.currentJob.id == jobID else { return }
        active.control.requestCancel()
        _ = await activeRun?.value
        if deletePartial { active.discardPartialFiles() }
    }

    func keepScanning(jobID: String, fileIndex: Int) {
        guard let oldRunner = savedRunners[jobID] else { return }
        do {
            try oldRunner.prepareKeepScanning(fileIndex: fileIndex)
            let updated = oldRunner.currentJob
            guard let volume = knownVolumes[updated.volumeID] else { return }
            replaceJob(updated)
            queue.insert(QueuedRun(job: updated, volume: volume), at: 0)
            startNextIfNeeded()
        } catch {
            return
        }
    }

    func waitForCompletion(of jobID: String) async {
        guard activeJobID == jobID || queue.contains(where: { $0.job.id == jobID }) else { return }
        await withCheckedContinuation { continuation in
            completionWaiters[jobID, default: []].append(continuation)
        }
    }

    func prepareForQuit() async {
        if let activeJobID {
            requestPause(.appQuit)
            await waitForCompletion(of: activeJobID)
        }
        for index in jobs.indices where !isFinished(jobs[index]) {
            jobs[index].pausedReason = .appQuit
            try? dependencies.jobStore.save(jobs[index])
        }
    }

    private func startNextIfNeeded() {
        guard runner == nil, let next = queue.first else { return }
        queue.removeFirst()
        run(next.job, volume: next.volume)
    }

    private func run(_ job: PersistedJob, volume: Volume) {
        powerToken = dependencies.powerGuard.begin(reason: "USB Verify is checking a drive")
        let newRunner = JobRunner(
            job: job,
            volume: volume,
            io: dependencies.driveIO,
            volumeControl: dependencies.volumeControl,
            store: dependencies.jobStore,
            sink: dependencies.runSink,
            environment: RunEnvironment(route: volume.route))
        runner = newRunner
        savedRunners[job.id] = newRunner
        let runTask = Task { await newRunner.run() }
        activeRun = runTask
        Task { [weak self, weak newRunner] in
            guard let self, let newRunner else { return }
            for await event in newRunner.events { publish(event, for: job.id) }
        }
        Task { [weak self, weak newRunner] in
            guard let self, let newRunner else { return }
            let summary = await runTask.value
            finish(summary: summary, runner: newRunner)
        }
    }

    private func finish(summary: JobSummary, runner: JobRunner) {
        powerToken?.end()
        powerToken = nil
        replaceJob(summary.job)
        let hasFailure = summary.job.files.contains {
            if case .failed = $0.result { return true }
            return false
        }
        let title = hasFailure ? "USB Verify failed" : title(for: summary.status)
        Task {
            await dependencies.notifier.notify(
                title: title,
                body: message(for: summary.status, hasFailure: hasFailure))
        }
        savedRunners[summary.job.id] = runner
        self.runner = nil
        activeRun = nil
        completionWaiters.removeValue(forKey: summary.job.id)?.forEach { $0.resume() }
        startNextIfNeeded()
    }

    private func publish(_ event: JobEvent, for jobID: String) {
        if case .progress(let snapshot) = event { snapshots[jobID] = snapshot }
        for continuation in subscribers[jobID] ?? [] { continuation.yield(event) }
    }

    private func replaceJob(_ job: PersistedJob) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job } else { jobs.append(job) }
    }

    private func isFinished(_ job: PersistedJob) -> Bool { job.files.allSatisfy { $0.result != nil } }

    private func title(for status: JobSummary.Status) -> String {
        switch status {
        case .completed: return "USB Verify passed"
        case .cancelled: return "USB Verify cancelled"
        case .paused: return "USB Verify paused"
        }
    }

    private func message(for status: JobSummary.Status, hasFailure: Bool) -> String {
        switch status {
        case .completed:
            return hasFailure
                ? "The copy finished with one or more failed files."
                : "The copy finished and passed verification."
        case .cancelled: return "The copy was cancelled."
        case .paused(let reason):
            switch reason {
            case .driveDisconnected: return "The drive was disconnected. Reconnect it to resume."
            case .wake: return "The Mac woke from sleep. Resume when the drive is ready."
            case .appQuit: return "The job was paused because USB Verify is quitting."
            }
        }
    }
}
