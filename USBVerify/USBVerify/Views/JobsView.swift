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
                    Text(title).font(.headline)
                    Text(detailText).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if job.pausedReason != nil {
                    Button("Resume") { model.resume(jobID: job.id) }
                        .buttonStyle(.borderedProminent)
                }
            }
            if let snapshot = model.snapshots[job.id], snapshot.fileCount > 0 {
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
        ForEach(job.files.indices, id: \.self) { index in
            if let result = job.files[index].result {
                ResultLine(name: job.files[index].finalName, result: result)
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

    private var title: String {
        switch job.kind {
        case .copy: return job.files.first?.finalName ?? "Copy job"
        case .verifyOnly: return "Verify-only job"
        case .capacityTest: return "Capacity test"
        case .format: return "Format drive"
        }
    }
}

private struct ResultLine: View {
    let name: String
    let result: FileResult

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch result {
            case .passed:
                Label("PASS · \(name)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(_, let ranges):
                Label("FAIL · \(name)", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                ForEach(ranges, id: \.self) { range in
                    Text("Bad range \(Formatting.hex(range.offset)) (\(range.offset) bytes)")
                        .font(.caption.monospaced())
                }
            case .skipped(let reason):
                Text("SKIPPED · \(reason)").foregroundStyle(.secondary)
            case .cancelled:
                Text("CANCELLED").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }
}
