import Foundation
import Observation
import USBVerifyCore

@MainActor
@Observable
final class AppModel {
    enum Route: Hashable { case drives, jobs, history }

    let dependencies: AppDependencies
    let coordinator: JobCoordinator
    var volumes: [Volume] = []
    var selectedVolume: Volume?
    var selectedRoute: Route = .drives
    var copyRequest: CopyRequest?
    var showingCopySheet = false
    var jobs: [PersistedJob] = []
    var history: [RunRecord] = []
    var snapshots: [String: ProgressSnapshot] = [:]
    var routeSummaries: [RouteSummary] = []

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        coordinator = JobCoordinator(dependencies: dependencies)
        jobs = coordinator.jobs
        Task { await refresh() }
    }

    var menuBarStatus: String {
        guard let snapshot = snapshots.values.first else { return "Idle" }
        guard snapshot.fileBytesTotal > 0 else { return "Copying" }
        return "Copying \(Int(snapshot.fileBytesDone * 100 / snapshot.fileBytesTotal))%"
    }

    var menuBarSymbol: String { snapshots.isEmpty ? "externaldrive" : "arrow.triangle.2.circlepath" }

    func refresh() async {
        volumes = await dependencies.volumeEvents.currentVolumes()
        history = (try? await dependencies.historyStore.loadAll()) ?? []
        routeSummaries = RouteHistory.summaries(from: history)
        observeEvents()
        observeJobEvents()
    }

    func presentCopySheet(for volume: Volume? = nil) {
        selectedVolume = volume ?? selectedVolume ?? volumes.first
        copyRequest = selectedVolume.map { CopyRequest(volume: $0, destinationFolder: "", sourcePaths: []) }
        showingCopySheet = selectedVolume != nil
    }

    func startCopy(_ request: CopyRequest) {
        do {
            let planned = try CopyPlanner.plan(request: request, io: dependencies.driveIO)
            guard planned.report.isOK else { return }
            coordinator.start(planned.job, volume: request.volume)
            jobs = coordinator.jobs
            selectedRoute = .jobs
            showingCopySheet = false
        } catch {
            showingCopySheet = false
        }
    }

    func resume(jobID: String) {
        guard let job = jobs.first(where: { $0.id == jobID }),
            let volume = volumes.first(where: { $0.id == job.volumeID })
        else { return }
        coordinator.resume(job, volume: volume)
    }

    func cancel(jobID: String, deletePartial: Bool) {
        guard jobs.contains(where: { $0.id == jobID }) else { return }
        coordinator.requestCancel()
        _ = deletePartial
    }

    func retryUnmount(jobID: String) {
        _ = jobID
        coordinator.retryUnmount()
    }

    func keepScanning(jobID: String, fileIndex: Int) {
        _ = jobID
        _ = fileIndex
    }

    func eject(volume: Volume) {
        Task { try? await dependencies.volumeControl.eject(volume: volume.id) }
    }

    func dismiss(jobID: String) { jobs.removeAll { $0.id == jobID } }

    private func observeEvents() {
        Task { [weak self] in
            guard let self else { return }
            for await event in dependencies.volumeEvents.events() {
                switch event {
                case .added(let volume), .changed(let volume):
                    if let index = volumes.firstIndex(where: { $0.id == volume.id }) {
                        volumes[index] = volume
                    } else {
                        volumes.append(volume)
                    }
                case .removed(let id):
                    volumes.removeAll { $0.id == id }
                    if coordinator.jobs.contains(where: { $0.volumeID == id }) {
                        coordinator.requestPause(.driveDisconnected)
                    }
                }
            }
        }
    }

    private func observeJobEvents() {
        guard let stream = coordinator.events else { return }
        Task { [weak self] in
            guard let self else { return }
            for await event in stream {
                if case .progress(let snapshot) = event { snapshots["active"] = snapshot }
                jobs = coordinator.jobs
            }
        }
    }
}
