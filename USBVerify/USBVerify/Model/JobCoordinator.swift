import Foundation
import USBVerifyCore

@MainActor
final class JobCoordinator {
    enum Operation {
        case copy
        case verify(items: [VerifyOnlyItem])
        case capacity(config: CapacityConfig)
        case format(label: String, useAdmin: Bool)
    }

    private struct QueuedRun {
        var job: PersistedJob
        var volume: Volume
        var operation: Operation
    }

    private let dependencies: AppDependencies
    private var queue: [QueuedRun] = []
    private var runner: JobRunner?
    private var activeRun: Task<JobSummary, Never>?
    private var activeOperationTask: Task<Void, Never>?
    private var activeControl: JobControl?
    private var activeJobIDValue: String?
    private var powerToken: (any PowerToken)?
    private var subscribers: [String: [AsyncStream<JobEvent>.Continuation]] = [:]
    private var savedRunners: [String: JobRunner] = [:]
    private var completionWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var knownVolumes: [VolumeID: Volume] = [:]

    var jobs: [PersistedJob] = []
    var snapshots: [String: ProgressSnapshot] = [:]
    var latestCapacityReport: CapacityReport?
    var isRunning: Bool { activeJobIDValue != nil }
    var activeJobID: String? { activeJobIDValue }

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
        queue.append(QueuedRun(job: job, volume: volume, operation: .copy))
        startNextIfNeeded()
    }

    func startVerifyOnly(
        _ job: PersistedJob,
        volume: Volume,
        items: [VerifyOnlyItem]
    ) {
        jobs.append(job)
        queue.append(QueuedRun(job: job, volume: volume, operation: .verify(items: items)))
        startNextIfNeeded()
    }

    func startCapacity(_ job: PersistedJob, volume: Volume, config: CapacityConfig) {
        jobs.append(job)
        queue.append(QueuedRun(job: job, volume: volume, operation: .capacity(config: config)))
        startNextIfNeeded()
    }

    func startFormat(
        _ job: PersistedJob,
        volume: Volume,
        label: String,
        useAdmin: Bool = false
    ) {
        jobs.append(job)
        queue.append(
            QueuedRun(
                job: job,
                volume: volume,
                operation: .format(label: label, useAdmin: useAdmin)))
        startNextIfNeeded()
    }

    func resume(_ job: PersistedJob, volume: Volume) {
        queue.append(QueuedRun(job: job, volume: volume, operation: .copy))
        startNextIfNeeded()
    }

    func requestPause(_ reason: PauseReason) {
        if let runner {
            runner.control.requestPause(reason)
        } else {
            activeControl?.requestPause(reason)
        }
    }

    func requestCancel() {
        if let runner {
            runner.control.requestCancel()
        } else {
            activeControl?.requestCancel()
        }
    }

    func retryUnmount() {
        if let runner {
            runner.control.requestUnmountRetry()
        } else {
            activeControl?.requestUnmountRetry()
        }
    }

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
            queue.insert(QueuedRun(job: updated, volume: volume, operation: .copy), at: 0)
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
        run(next)
    }

    private func run(_ queued: QueuedRun) {
        let job = queued.job
        let volume = queued.volume
        powerToken = dependencies.powerGuard.begin(reason: "USB Verify is checking a drive")
        activeJobIDValue = job.id
        run(queued.operation, job: job, volume: volume)
    }

    private func run(_ operation: Operation, job: PersistedJob, volume: Volume) {
        switch operation {
        case .copy:
            runCopy(job, volume: volume)
        case .verify(let items):
            runVerify(items, job: job, volume: volume)
        case .capacity(let config):
            runCapacity(config, job: job, volume: volume)
        case .format(let label, let useAdmin):
            runFormat(label, useAdmin: useAdmin, job: job, volume: volume)
        }
    }

    private func runCopy(_ job: PersistedJob, volume: Volume) {
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

    private func runVerify(
        _ items: [VerifyOnlyItem],
        job: PersistedJob,
        volume: Volume
    ) {
        let verifyRunner = VerifyOnlyRunner(
            items: items,
            volume: volume,
            io: dependencies.driveIO,
            volumeControl: dependencies.volumeControl,
            sink: dependencies.runSink,
            environment: RunEnvironment(route: volume.route))
        activeControl = verifyRunner.control
        activeOperationTask = Task { [weak self, weak verifyRunner] in
            guard let self, let verifyRunner else { return }
            for await event in verifyRunner.events { publish(event, for: job.id) }
        }
        Task { [weak self, weak verifyRunner] in
            guard let self, let verifyRunner else { return }
            let results = await verifyRunner.run()
            finishVerify(results, job: job)
        }
    }

    private func runCapacity(
        _ config: CapacityConfig,
        job: PersistedJob,
        volume: Volume
    ) {
        let capacityRunner = CapacityRunner(
            volume: volume,
            config: config,
            io: dependencies.driveIO,
            volumeControl: dependencies.volumeControl,
            sink: dependencies.runSink,
            environment: RunEnvironment(route: volume.route))
        activeControl = capacityRunner.control
        activeOperationTask = Task { [weak self, weak capacityRunner] in
            guard let self, let capacityRunner else { return }
            for await event in capacityRunner.events { publish(event, for: job.id) }
        }
        Task { [weak self, weak capacityRunner] in
            guard let self, let capacityRunner else { return }
            latestCapacityReport = await capacityRunner.run()
            finishSimple(job: job)
        }
    }

    private func runFormat(
        _ label: String,
        useAdmin: Bool,
        job: PersistedJob,
        volume: Volume
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let fresh = knownVolumes[volume.id]
                let busy = Set(
                    jobs
                        .filter { $0.id != job.id && !isFinished($0) }
                        .map(\.volumeID))
                let coordinator = FormatCoordinator(volumeControl: dependencies.volumeControl)
                _ = try await coordinator.erase(
                    confirmed: volume,
                    fresh: fresh,
                    busyVolumes: busy,
                    label: label,
                    useAdminAfterPermissionFailure: useAdmin)
            } catch {
                publish(.warning(String(describing: error)), for: job.id)
            }
            finishSimple(job: job)
        }
    }

    private func finishVerify(_ results: [FileResult], job: PersistedJob) {
        var updated = job
        for (index, result) in results.enumerated() where updated.files.indices.contains(index) {
            updated.files[index].result = result
            switch result {
            case .passed:
                updated.files[index].phase = .passed
            case .failed(_, let ranges):
                updated.files[index].phase = .failed
                updated.files[index].badRanges = ranges
            case .skipped, .cancelled:
                updated.files[index].phase = .failed
            }
        }
        updated.currentIndex = results.count
        replaceJob(updated)
        finishActive(jobID: job.id)
    }

    private func finishSimple(job: PersistedJob) {
        var updated = job
        for index in updated.files.indices {
            updated.files[index].result = .passed(sourceHash: "", rereadHash: "")
            updated.files[index].phase = .passed
        }
        replaceJob(updated)
        finishActive(jobID: job.id)
    }

    private func finishActive(jobID: String) {
        powerToken?.end()
        powerToken = nil
        activeControl = nil
        activeOperationTask = nil
        activeJobIDValue = nil
        completionWaiters.removeValue(forKey: jobID)?.forEach { $0.resume() }
        startNextIfNeeded()
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
        activeJobIDValue = nil
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
