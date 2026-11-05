import SwiftUI
import USBVerifyCore

struct HistoryView: View {
    let model: AppModel
    @State private var resultFilter: String?
    @State private var driveFilter: String?
    @State private var selectedRun: RunRecord?

    private var records: [RunRecord] {
        HistoryPresentation.filtered(model.history, result: resultFilter, driveName: driveFilter)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Result", selection: $resultFilter) {
                    Text("All results").tag(String?.none)
                    Text("PASS").tag(String?("PASS"))
                    Text("FAIL").tag(String?("FAIL"))
                    Text("SKIPPED").tag(String?("SKIPPED"))
                }
                Picker("Drive", selection: $driveFilter) {
                    Text("All drives").tag(String?.none)
                    ForEach(Array(Set(model.history.map(\.driveName))).sorted(), id: \.self) { name in
                        Text(name).tag(String?(name))
                    }
                }
                Spacer()
            }
            .padding(16)
            if records.isEmpty {
                ContentUnavailableView(
                    "No matching runs",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Completed copies and verification results will be kept here."))
            } else {
                List(records, id: \.runID) { run in
                    Button {
                        selectedRun = run
                    } label: {
                        HistoryRow(run: run)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("History")
        .sheet(
            isPresented: Binding(
                get: { selectedRun != nil },
                set: { if !$0 { selectedRun = nil } })
        ) {
            if let selectedRun {
                HistoryDetail(run: selectedRun, summaries: model.routeSummaries)
            }
        }
    }
}

private struct HistoryRow: View {
    let run: RunRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: run.result == "PASS" ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(run.result == "PASS" ? .green : .red)
                .accessibilityLabel(run.result == "PASS" ? "Passed" : "Not passed")
            VStack(alignment: .leading, spacing: 3) {
                Text(run.driveName).font(.headline)
                Text(run.sourcePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Drive test")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(
                run.kind == .verifyOnly ? "Verify only" : run.mode.map { $0 == .strict ? "Strict" : "Quick" } ?? "Test"
            )
            .foregroundStyle(.secondary)
            Text(run.result).font(.callout.weight(.semibold))
        }
        .padding(.vertical, 5)
    }
}

private struct HistoryDetail: View {
    let run: RunRecord
    let summaries: [RouteSummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(run.driveName).font(.title2.weight(.semibold))
            Form {
                LabeledContent("Date", value: run.startedAt.formatted())
                LabeledContent("Mode", value: run.mode.map { $0 == .strict ? "Strict" : "Quick" } ?? "Verify only")
                LabeledContent("Retries", value: "\(run.retries)")
                LabeledContent("Duration", value: run.endedAt.timeIntervalSince(run.startedAt).formatted())
                LabeledContent("Route", value: DrivePresentation.routeText(run.route))
                LabeledContent("Filesystem driver", value: run.filesystemDriver ?? "unknown")
                LabeledContent("macOS", value: run.macOSVersion)
                if let sourceHash = run.sourceHash {
                    Text(sourceHash).textSelection(.enabled)
                }
                if let rereadHash = run.rereadHash {
                    Text(rereadHash).textSelection(.enabled)
                }
                if !run.badRanges.isEmpty {
                    Section("Bad ranges") {
                        ForEach(run.badRanges, id: \.self) { range in
                            Text(HistoryPresentation.badRangeText(range)).font(.body.monospaced())
                        }
                    }
                }
                Section("Route comparison") {
                    ForEach(summaries, id: \.routeKey) { summary in
                        Text(DrivePresentation.routeComparison(summary))
                    }
                }
            }
            Spacer()
        }
        .padding(24)
        .frame(width: 620, height: 600)
    }
}
