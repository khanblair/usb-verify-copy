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
    var phases: [String: JobPhase] = [:]
    var warnings: [String: [String]] = [:]
    var waitingForUnmount: [String: [String]] = [:]
    var fileResults: [String: [Int: FileResult]] = [:]
    var routeSummaries: [RouteSummary] = []
    var isOnBattery = false
    var lastErrorMessage: String?
    var lastErrorDetail: String?
    var preflightIssues: [(message: String, detail: String)] = []
    var resumableJobIDs: Set<String> = []
    var reconnectMessages: [String: String] = [:]

    private var volumeObserverStarted = false
    private var wakeObserverStarted = false
    private var eventTasks: [String: Task<Void, Never>] = [:]

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
        coordinator.setCurrentVolumes(volumes)
        isOnBattery = dependencies.powerGuard.isOnBattery
        history = (try? await dependencies.historyStore.loadAll()) ?? []
        routeSummaries = RouteHistory.summaries(from: history)
        clearRemovedSelection()
        startObserversIfNeeded()
        jobs = coordinator.jobs
        for job in jobs where job.pausedReason != nil { updateResumableState(for: job) }
    }

    func presentCopySheet(for volume: Volume? = nil) {
        selectedVolume = volume ?? selectedVolume ?? volumes.first
        copyRequest = selectedVolume.map { CopyRequest(volume: $0, destinationFolder: "", sourcePaths: []) }
        showingCopySheet = selectedVolume != nil
    }

    func startCopy(_ request: CopyRequest) {
        do {
            let planned = try CopyPlanner.plan(request: request, io: dependencies.driveIO)
            guard planned.report.isOK else {
                setPreflightIssues(planned.report.issues)
                return
            }
            coordinator.start(planned.job, volume: request.volume)
            isOnBattery = dependencies.powerGuard.isOnBattery
            jobs = coordinator.jobs
            observeJobEvents(for: planned.job.id)
            selectedRoute = .jobs
            showingCopySheet = false
            lastErrorMessage = nil
            lastErrorDetail = nil
        } catch {
            show(error: error)
        }
    }

    func resume(jobID: String) {
        guard let job = jobs.first(where: { $0.id == jobID }),
              let volume = volumes.first(where: { $0.id == job.volumeID })
        else { return }
        coordinator.resume(job, volume: volume)
        isOnBattery = dependencies.powerGuard.isOnBattery
        observeJobEvents(for: jobID)
        resumableJobIDs.remove(jobID)
    }

    func cancel(jobID: String, deletePartial: Bool) {
        Task { await coordinator.cancel(jobID: jobID, deletePartial: deletePartial) }
    }

    func retryUnmount(jobID: String) {
        guard coordinator.activeJobID == jobID else { return }
        coordinator.retryUnmount()
    }

    func keepScanning(jobID: String, fileIndex: Int) {
        coordinator.keepScanning(jobID: jobID, fileIndex: fileIndex)
        observeJobEvents(for: jobID)
    }

    func prepareForQuit() async {
        await coordinator.prepareForQuit()
        jobs = coordinator.jobs
    }

    func eject(volume: Volume) {
        Task { try? await dependencies.volumeControl.eject(volume: volume.id) }
    }

    func dismiss(jobID: String) { jobs.removeAll { $0.id == jobID } }

    private func startObserversIfNeeded() {
        if !volumeObserverStarted {
            volumeObserverStarted = true
            Task { [weak self] in await self?.observeVolumes() }
        }
        if !wakeObserverStarted {
            wakeObserverStarted = true
            Task { [weak self] in await self?.observeWakeEvents() }
        }
    }

    private func observeVolumes() async {
        for await event in dependencies.volumeEvents.events() {
            switch event {
            case .added(let volume), .changed(let volume):
                let wasAbsent = !volumes.contains { $0.id == volume.id }
                if let index = volumes.firstIndex(where: { $0.id == volume.id }) { volumes[index] = volume }
                else { volumes.append(volume) }
                coordinator.setCurrentVolumes(volumes)
                if wasAbsent { announceDriveBack(volume) }
            case .removed(let id):
                volumes.removeAll { $0.id == id }
                coordinator.setCurrentVolumes(volumes)
                clearRemovedSelection()
                if coordinator.jobs.first(where: { $0.id == coordinator.activeJobID })?.volumeID == id {
                    coordinator.requestPause(.driveDisconnected)
                }
            }
        }
    }

    private func observeWakeEvents() async {
        for await _ in dependencies.powerGuard.wakeEvents() {
            if coordinator.isRunning { coordinator.requestPause(.wake) }
        }
    }

    private func observeJobEvents(for jobID: String) {
        guard eventTasks[jobID] == nil else { return }
        let stream = coordinator.events(for: jobID)
        eventTasks[jobID] = Task { [weak self] in
            guard let self else { return }
            for await event in stream { apply(event, to: jobID) }
        }
    }

    private func apply(_ event: JobEvent, to jobID: String) {
        switch event {
        case .progress(let snapshot): snapshots[jobID] = snapshot
        case .phase(let fileIndex, let phase): phases["\(jobID):\(fileIndex)"] = phase
        case .warning(let warning): warnings[jobID, default: []].append(warning)
        case .waitingForUnmount(let blockers): waitingForUnmount[jobID] = blockers
        case .fileFinished(let index, let result): fileResults[jobID, default: [:]][index] = result
        case .paused, .finished:
            jobs = coordinator.jobs
            if case .finished = event {
                Task { await reloadHistory() }
            }
        }
    }

    private func announceDriveBack(_ volume: Volume) {
        for job in jobs where job.volumeID == volume.id && job.pausedReason != nil {
            resumableJobIDs.insert(job.id)
            Task {
                await dependencies.notifier.notify(
                    title: "Drive is back",
                    body: "\(volume.name) is back. Resume?")
            }
        }
    }

    private func updateResumableState(for job: PersistedJob) {
        if volumes.contains(where: { $0.id == job.volumeID }) { resumableJobIDs.insert(job.id) }
        else { reconnectMessages[job.id] = "Reconnect the drive" }
    }

    private func clearRemovedSelection() {
        if let selectedVolume, !volumes.contains(where: { $0.id == selectedVolume.id }) { self.selectedVolume = nil }
    }

    private func setPreflightIssues(_ issues: [PreflightIssue]) {
        preflightIssues = issues.map { issue in
            let error = issue.error
            return (error.plainMessage, error.technicalDetail)
        }
        lastErrorMessage = preflightIssues.first?.message
        lastErrorDetail = preflightIssues.first?.detail
    }

    private func show(error: Error) {
        if let error = error as? any UserFacingError {
            lastErrorMessage = error.plainMessage
            lastErrorDetail = error.technicalDetail
        } else {
            lastErrorMessage = "The copy could not be started."
            lastErrorDetail = String(describing: error)
        }
        showingCopySheet = false
    }

    private func reloadHistory() async {
        history = (try? await dependencies.historyStore.loadAll()) ?? []
        routeSummaries = RouteHistory.summaries(from: history)
    }
}
