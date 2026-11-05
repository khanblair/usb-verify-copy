import SwiftUI
import USBVerifyCore

struct DrivesView: View {
    let model: AppModel

    var body: some View {
        Group {
            if model.volumes.isEmpty {
                ContentUnavailableView(
                    "No external drives", systemImage: "externaldrive.badge.questionmark",
                    description: Text("Connect an exFAT or FAT32 drive to begin."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.volumes) { volume in
                            DriveCard(volume: volume, model: model)
                        }
                    }
                    .padding(22)
                }
            }
        }
        .navigationTitle("Drives")
        .toolbar {
            ToolbarItem {
                Button("New Copy", systemImage: "plus") { model.presentCopySheet() }
            }
        }
    }
}

struct DriveCard: View {
    let volume: Volume
    let model: AppModel

    var body: some View {
        Button {
            model.selectedVolume = volume
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "externaldrive.fill")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading) {
                        Text(volume.name).font(.headline)
                        Text("\(volume.filesystem.displayName) · \(Formatting.bytes(volume.totalBytes))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if volume.hasTimeMachineBackups {
                        Label("Time Machine", systemImage: "clock.arrow.circlepath")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Label("\(Formatting.bytes(volume.freeBytes)) free", systemImage: "internaldrive")
                    Spacer()
                    Text(Formatting.route(volume.route))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack {
                    Button("Copy") { model.presentCopySheet(for: volume) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel("Copy files to \(volume.name)")
                    Button("Verify") { model.presentCopySheet(for: volume) }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Verify files on \(volume.name)")
                    Spacer()
                    Button("Eject") { model.eject(volume: volume) }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Eject \(volume.name)")
                }
            }
            .padding(16)
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Format…") {}
            Button("Capacity test…") {}
        }
    }
}
