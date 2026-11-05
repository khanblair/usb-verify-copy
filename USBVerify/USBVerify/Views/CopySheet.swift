import AppKit
import SwiftUI
import USBVerifyCore

struct CopySheet: View {
    @Bindable var model: AppModel
    @State private var request: CopyRequest?
    @State private var issueText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New copy").font(.title2.weight(.semibold))
                    Text(request.map { "To \($0.volume.name)" } ?? "Choose a drive")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { model.showingCopySheet = false }
                    .keyboardShortcut(.cancelAction)
            }
            if var request {
                Form {
                    Section("Source files") {
                        HStack {
                            Text(
                                request.sourcePaths.isEmpty
                                    ? "No files selected" : "\(request.sourcePaths.count) file(s) selected"
                            )
                            .foregroundStyle(request.sourcePaths.isEmpty ? .secondary : .primary)
                            Spacer()
                            Button("Choose files…") { chooseFiles() }
                        }
                    }
                    Section("Verification") {
                        Picker("Mode", selection: Binding(get: { request.mode }, set: { request.mode = $0 })) {
                            Text("Strict").tag(VerifyMode.strict)
                            Text("Quick").tag(VerifyMode.quick)
                        }
                        .pickerStyle(.segmented)
                        Text(
                            request.mode == .strict
                                ? "Checks each chunk while writing, then reads the drive again after remount."
                                : "Writes faster, then relies on the required remount check."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Section("Destination") {
                        HStack {
                            Text(request.destinationFolder.isEmpty ? "Drive root" : request.destinationFolder)
                            Spacer()
                            Button("Choose folder…") { chooseFolder() }
                        }
                    }
                    Toggle(
                        "Remove macOS ._ files after copying",
                        isOn: Binding(get: { request.removeDotFilesAfter }, set: { request.removeDotFilesAfter = $0 }))
                }
                if let issueText {
                    Label(issueText, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                HStack {
                    Spacer()
                    Button("Start copy") { start(request) }
                        .buttonStyle(.borderedProminent)
                        .disabled(request.sourcePaths.isEmpty)
                }
            } else {
                ContentUnavailableView("Choose a drive first", systemImage: "externaldrive")
            }
        }
        .padding(26)
        .frame(width: 560, height: 510)
        .onAppear { request = model.copyRequest }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, var request {
            request.sourcePaths = panel.urls.map(\.path)
            self.request = request
        }
    }

    private func chooseFolder() {
        guard let request else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = URL(fileURLWithPath: request.volume.mountPath)
        if panel.runModal() == .OK, let url = panel.url,
            let folder = try? DestinationGuard(volume: request.volume).relativeFolder(ofAbsolute: url.path)
        {
            var updated = request
            updated.destinationFolder = folder
            self.request = updated
        }
    }

    private func start(_ request: CopyRequest) {
        model.startCopy(request)
        self.request = request
    }
}
