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
    var verifyOnlyRequest: VerifyOnlyRequest?
    var showingVerifyOnlySheet = false
    var formatRequest: FormatRequest?
    var showingFormatSheet = false
    var capacityRequest: CapacityRequest?
    var showingCapacitySheet = false
    var capacityReport: CapacityReport?
    var showingCapacityReport = false
    var formatRetryRequest: FormatRequest?
    var formatOutput: String?
    var pendingCleanup: CleanupConfirmation?

    private var cleanupFlags: [String: Bool] = [:]
    private var verifyTasks: [String: Task<Void, Never>] = [:]
    private var pendingWholeDriveCapacity: CapacityRequest?

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
        let jobID = coordinator.activeJobID
        let snapshot = jobID.flatMap { snapshots[$0] }
        let phase = jobID.flatMap { phases["\($0):\(snapshot?.fileIndex ?? 0)"] }
        return MenuBarPresentation.status(
            snapshot: snapshot,
            phase: phase,
            mostRecentResult: jobs.last.flatMap { job in
                job.files.last?.result.map { result in
                    if case .passed = result { return "PASS" }
                    if case .failed = result { return "FAIL" }
                    return nil
                } ?? nil
            } ?? nil)
    }

    var menuBarSymbol: String {
        let jobID = coordinator.activeJobID
        let snapshot = jobID.flatMap { snapshots[$0] }
        let phase = jobID.flatMap { phases["\($0):\(snapshot?.fileIndex ?? 0)"] }
        return MenuBarPresentation.symbol(phase: phase, hasActiveSnapshot: snapshot != nil)
    }

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
            cleanupFlags[planned.job.id] = request.removeDotFilesAfter
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

    func presentVerifyOnlySheet(for volume: Volume? = nil) {
        selectedVolume = volume ?? selectedVolume ?? volumes.first
        verifyOnlyRequest = selectedVolume.map {
            VerifyOnlyRequest(volume: $0, sourcePaths: [], destinationFolder: "")
        }
        showingVerifyOnlySheet = selectedVolume != nil
    }

    func startVerifyOnly(_ request: VerifyOnlyRequest) {
        let names = Set(
            FileManager.default.enumerator(atPath: request.volume.mountPath)?.compactMap { value in
                (value as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
            } ?? [])
        let matches = VerifyOnlyPlanner.matches(
            sourcePaths: request.sourcePaths,
            destinationFolder: request.destinationFolder,
            driveNames: names)
        let items = matches.filter(\.isMatched).map {
            VerifyOnlyItem(sourcePath: $0.sourcePath, destinationFolder: $0.destinationFolder, name: $0.name)
        }
        let states = items.map { item in
            FileJobState(
                sourcePath: item.sourcePath,
                destinationFolder: item.destinationFolder,
                finalName: item.name,
                tempName: item.name,
                chunkSize: Defaults.chunkSize,
                sourceIdentity: FileIdentity(size: 0, modifiedTimeNs: 0, inode: 0),
                phase: .queued)
        }
        let job = PersistedJob(kind: .verifyOnly, mode: .quick, volumeID: request.volume.id, files: states)
        showingVerifyOnlySheet = false
        selectedRoute = .jobs
        coordinator.startVerifyOnly(job, volume: request.volume, items: items)
        let jobID = job.id
        observeJobEvents(for: jobID)
        jobs = coordinator.jobs
    }

    func presentFormatSheet(for volume: Volume) {
        formatRequest = FormatRequest(volume: volume)
        showingFormatSheet = true
    }

    func presentCapacitySheet(for volume: Volume) {
        capacityRequest = CapacityRequest(volume: volume)
        showingCapacitySheet = true
    }

    func startFormat(_ request: FormatRequest, useAdminAfterPermissionFailure: Bool = false) {
        guard
            FormatPlan.confirmationMatches(
                typed: request.confirmation,
                volume: request.volume,
                otherNames: volumes.map(\.name))
        else {
            show(error: VerifyError.formatRefused(reason: "Type the drive BSD id or its non-generic name."))
            return
        }
        let state = FileJobState(
            sourcePath: "",
            destinationFolder: "",
            finalName: "Format \(request.volume.name)",
            tempName: "",
            chunkSize: Defaults.chunkSize,
            sourceIdentity: FileIdentity(size: 0, modifiedTimeNs: 0, inode: 0))
        let job = PersistedJob(
            kind: .format,
            mode: .quick,
            volumeID: request.volume.id,
            files: [state])
        coordinator.startFormat(
            job,
            volume: request.volume,
            label: request.label,
            useAdmin: useAdminAfterPermissionFailure)
        jobs = coordinator.jobs
        observeJobEvents(for: job.id)
        showingFormatSheet = false
    }

    func startCapacity(_ request: CapacityRequest) {
        if request.mode == .wholeDrive {
            pendingWholeDriveCapacity = request
            presentFormatSheet(for: request.volume)
            return
        }
        showingCapacitySheet = false
        let state = FileJobState(
            sourcePath: "",
            destinationFolder: request.config.folder,
            finalName: "Capacity test",
            tempName: "",
            chunkSize: Defaults.chunkSize,
            sourceIdentity: FileIdentity(size: request.volume.freeBytes, modifiedTimeNs: 0, inode: 0))
        let job = PersistedJob(
            kind: .capacityTest,
            mode: .quick,
            volumeID: request.volume.id,
            files: [state])
        coordinator.startCapacity(job, volume: request.volume, config: request.config)
        jobs = coordinator.jobs
        observeJobEvents(for: job.id)
    }

    func confirmFormatRetry() {
        guard let request = formatRetryRequest else { return }
        formatRetryRequest = nil
        startFormat(request, useAdminAfterPermissionFailure: true)
    }

    func confirmCleanup() {
        guard let pendingCleanup else { return }
        _ = DotCleaner.delete(pendingCleanup.paths, within: pendingCleanup.root)
        self.pendingCleanup = nil
    }

    func cancelCleanup() {
        pendingCleanup = nil
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
                if let index = volumes.firstIndex(where: { $0.id == volume.id }) {
                    volumes[index] = volume
                } else {
                    volumes.append(volume)
                }
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
        case .warning(let warning):
            warnings[jobID, default: []].append(warning)
            if warning.lowercased().contains("permission") {
                formatRetryRequest = formatRequest
                formatOutput = warning
            }
        case .waitingForUnmount(let blockers): waitingForUnmount[jobID] = blockers
        case .fileFinished(let index, let result): fileResults[jobID, default: [:]][index] = result
        case .paused, .finished:
            jobs = coordinator.jobs
            if case .finished = event {
                capacityReport = coordinator.latestCapacityReport
                showingCapacityReport = coordinator.latestCapacityReport != nil
                if let job = jobs.first(where: { $0.id == jobID }),
                    job.kind == .format,
                    let pending = pendingWholeDriveCapacity
                {
                    pendingWholeDriveCapacity = nil
                    startCapacity(
                        CapacityRequest(
                            volume: pending.volume,
                            mode: .freeSpaceOnly,
                            config: pending.config))
                }
                offerCleanupIfNeeded(jobID: jobID)
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
        if volumes.contains(where: { $0.id == job.volumeID }) {
            resumableJobIDs.insert(job.id)
        } else {
            reconnectMessages[job.id] = "Reconnect the drive"
        }
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

    private func isFinished(_ job: PersistedJob) -> Bool {
        job.files.allSatisfy { $0.result != nil }
    }

    private func offerCleanupIfNeeded(jobID: String) {
        guard cleanupFlags[jobID] == true,
            let job = jobs.first(where: { $0.id == jobID }),
            job.files.allSatisfy({
                if case .passed = $0.result { return true }
                return false
            })
        else { return }
        let paths = job.files.flatMap { file -> [String] in
            let root = [volumes.first(where: { $0.id == job.volumeID })?.mountPath, file.destinationFolder]
                .compactMap { $0 }.joined(separator: "/")
            return DotCleaner.scan(root: root)
        }
        if let root = volumes.first(where: { $0.id == job.volumeID })?.mountPath, !paths.isEmpty {
            pendingCleanup = CleanupConfirmation(root: root, paths: paths)
        }
    }
}

extension FileResult {
    fileprivate var isPass: Bool {
        if case .passed = self { return true }
        return false
    }

    fileprivate var badRanges: [BadRange] {
        if case .failed(_, let ranges) = self { return ranges }
        return []
    }
}
