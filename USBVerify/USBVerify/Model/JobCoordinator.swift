import Foundation
import USBVerifyCore

@MainActor
final class JobCoordinator {
    private let dependencies: AppDependencies
    private var runner: JobRunner?
    private var powerToken: (any PowerToken)?

    var jobs: [PersistedJob] = []
    var snapshots: [String: ProgressSnapshot] = [:]
    var events: AsyncStream<JobEvent>?

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        jobs = (try? dependencies.jobStore.loadAll()) ?? []
    }

    func start(_ job: PersistedJob, volume: Volume) {
        jobs.append(job)
        run(job, volume: volume)
    }

    func resume(_ job: PersistedJob, volume: Volume) {
        run(job, volume: volume)
    }

    func requestPause(_ reason: PauseReason) { runner?.control.requestPause(reason) }
    func requestCancel() { runner?.control.requestCancel() }
    func retryUnmount() { runner?.control.requestUnmountRetry() }

    private func run(_ job: PersistedJob, volume: Volume) {
        powerToken?.end()
        powerToken = dependencies.powerGuard.begin(reason: "USB Verify is checking a drive")
        let runner = JobRunner(
            job: job, volume: volume, io: dependencies.driveIO, volumeControl: dependencies.volumeControl,
            store: dependencies.jobStore, sink: dependencies.runSink, environment: RunEnvironment(route: volume.route))
        self.runner = runner
        events = runner.events
        Task { [weak self, weak runner] in
            guard let self, let runner else { return }
            let summary = await runner.run()
            self.finished(summary: summary)
        }
    }

    private func finished(summary: JobSummary) {
        powerToken?.end()
        powerToken = nil
        if let index = jobs.firstIndex(where: { $0.id == summary.job.id }) { jobs[index] = summary.job }
        runner = nil
    }
}
