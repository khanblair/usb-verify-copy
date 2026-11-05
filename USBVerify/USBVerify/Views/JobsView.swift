import SwiftUI
import USBVerifyCore

struct JobsView: View {
    let model: AppModel

    var body: some View {
        Group {
            if model.jobs.isEmpty {
                ContentUnavailableView(
                    "No jobs yet", systemImage: "clock.arrow.circlepath",
                    description: Text("A copy will appear here while it runs and after it finishes."))
            } else {
                List {
                    ForEach(model.jobs, id: \.id) { job in
                        JobRow(job: job, model: model)
                    }
                }
            }
        }
        .navigationTitle("Jobs")
    }
}

struct JobRow: View {
    let job: PersistedJob
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: iconName)
                    .foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.files.first?.finalName ?? "Copy job").font(.headline)
                    Text(detailText).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if job.pausedReason != nil {
                    Button("Resume") { model.resume(jobID: job.id) }
                        .buttonStyle(.borderedProminent)
                }
            }
            if let snapshot = model.snapshots["active"], snapshot.fileCount > 0 {
                ProgressView(value: Double(snapshot.fileBytesDone), total: Double(max(snapshot.fileBytesTotal, 1)))
                    .tint(.accentColor)
                HStack {
                    Text("\(Int(snapshot.fileBytesDone * 100 / max(snapshot.fileBytesTotal, 1)))%")
                    Spacer()
                    Text(Formatting.rate(snapshot.bytesPerSecond))
                    Text(Formatting.duration(snapshot.secondsRemaining))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }

    private var iconName: String {
        if job.pausedReason != nil { return "pause.circle.fill" }
        if job.files.contains(where: { $0.result != nil }) { return "checkmark.circle.fill" }
        return "arrow.triangle.2.circlepath.circle"
    }

    private var statusColor: Color { job.pausedReason != nil ? .orange : .accentColor }

    private var detailText: String {
        if let reason = job.pausedReason {
            return reason == .driveDisconnected
                ? "Drive disconnected. Reconnect to resume." : "Paused until the drive is ready."
        }
        let done = job.files.filter { $0.result != nil }.count
        return "\(done) of \(job.files.count) files complete · \(job.mode == .strict ? "Strict" : "Quick")"
    }
}
