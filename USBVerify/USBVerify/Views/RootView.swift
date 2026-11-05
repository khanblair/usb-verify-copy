import SwiftUI
import USBVerifyCore

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedRoute) {
                Section("Workspace") {
                    Label("Drives", systemImage: "externaldrive")
                        .tag(AppModel.Route.drives)
                    Label("Jobs", systemImage: "clock.arrow.circlepath")
                        .tag(AppModel.Route.jobs)
                    Label("History", systemImage: "checkmark.seal")
                        .tag(AppModel.Route.history)
                }
            }
            .navigationTitle("USB Verify")
            .listStyle(.sidebar)
        } content: {
            switch model.selectedRoute {
            case .drives:
                DrivesView(model: model)
            case .jobs:
                JobsView(model: model)
            case .history:
                HistoryView(model: model)
            }
        } detail: {
            DetailView(model: model)
        }
        .sheet(isPresented: $model.showingCopySheet) {
            CopySheet(model: model)
        }
    }
}

private struct DetailView: View {
    let model: AppModel

    var body: some View {
        if let volume = model.selectedVolume {
            DriveDetailView(volume: volume, model: model)
        } else {
            ContentUnavailableView(
                "Select a drive", systemImage: "externaldrive",
                description: Text("Choose a drive to see its route and available actions."))
        }
    }
}

struct DriveDetailView: View {
    let volume: Volume
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(volume.name).font(.largeTitle.weight(.semibold))
                        Text("Physical drive · \(volume.model ?? "Unknown model")")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "externaldrive.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
                if volume.route?.hubInPath == true {
                    Label("This drive sits behind a hub or adapter.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Drive facts").font(.headline)
                    FactRow(label: "Capacity", value: Formatting.bytes(volume.totalBytes))
                    FactRow(label: "Free", value: Formatting.bytes(volume.freeBytes))
                    FactRow(label: "Format", value: volume.filesystem.displayName)
                    FactRow(label: "Connection", value: Formatting.route(volume.route))
                }
                .padding(16)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                HStack {
                    Button("Copy files") { model.presentCopySheet(for: volume) }
                        .buttonStyle(.borderedProminent)
                    Button("Verify only") { model.presentCopySheet(for: volume) }
                        .buttonStyle(.bordered)
                    Button("Eject") { model.eject(volume: volume) }
                        .buttonStyle(.bordered)
                }
                .accessibilityElement(children: .contain)
            }
            .padding(28)
        }
        .navigationTitle(volume.name)
    }
}

private struct FactRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }
}
