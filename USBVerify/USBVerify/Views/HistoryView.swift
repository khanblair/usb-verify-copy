import SwiftUI
import USBVerifyCore

struct HistoryView: View {
    let model: AppModel

    var body: some View {
        Group {
            if model.history.isEmpty {
                ContentUnavailableView(
                    "No history", systemImage: "checkmark.seal",
                    description: Text("Completed copies and verification results will be kept here."))
            } else {
                List(model.history, id: \.runID) { run in
                    HStack(spacing: 12) {
                        Image(systemName: run.result == "PASS" ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(run.result == "PASS" ? .green : .red)
                            .accessibilityLabel(run.result == "PASS" ? "Passed" : "Failed")
                        VStack(alignment: .leading) {
                            Text(run.driveName).font(.headline)
                            Text(run.route?.key ?? "Route unknown")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(run.result).font(.callout.weight(.semibold))
                    }
                    .padding(.vertical, 5)
                }
            }
        }
        .navigationTitle("History")
    }
}
