import AppKit
import SwiftUI
import USBVerifyCore

extension CleanupConfirmation: Identifiable {
    var id: String { root + paths.joined(separator: "\n") }
}

struct VerifyOnlySheet: View {
    @Bindable var model: AppModel
    @State private var request: VerifyOnlyRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            sheetHeader(title: "Verify files", subtitle: request.map { "On \($0.volume.name)" }) {
                model.showingVerifyOnlySheet = false
            }
            if let request {
                Form {
                    Section("Source files") {
                        Text(
                            request.sourcePaths.isEmpty ? "No files selected" : "\(request.sourcePaths.count) selected")
                        Button("Choose files…") { chooseFiles() }
                    }
                    Section("Folder on the drive") {
                        Text(request.destinationFolder.isEmpty ? "Drive root" : request.destinationFolder)
                        Button("Choose folder…") { chooseFolder() }
                    }
                    Text("Files are matched by name. Verify only reads the drive and never writes to it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Start verification") { model.startVerifyOnly(request) }
                        .buttonStyle(.borderedProminent)
                        .disabled(request.sourcePaths.isEmpty)
                }
            }
        }
        .padding(24)
        .frame(width: 520, height: 390)
        .onAppear { request = model.verifyOnlyRequest }
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
        if panel.runModal() == .OK,
            let url = panel.url,
            let folder = try? DestinationGuard(volume: request.volume).relativeFolder(ofAbsolute: url.path)
        {
            var updated = request
            updated.destinationFolder = folder
            self.request = updated
        }
    }
}

struct FormatSheet: View {
    @Bindable var model: AppModel
    @State private var request: FormatRequest?
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sheetHeader(title: "Format drive", subtitle: request?.volume.name) {
                model.showingFormatSheet = false
            }
            if let request {
                Form {
                    Text("Name: \(request.volume.name)")
                    Text("Size: \(Formatting.bytes(request.volume.totalBytes))")
                    Text("BSD id: \(request.volume.wholeDiskBSDName)")
                    Text("Model: \(request.volume.model ?? "unknown")")
                    Section("Partitions") {
                        Text(request.volume.bsdName)
                            .font(.body.monospaced())
                    }
                    TextField(
                        "New label",
                        text: Binding(
                            get: { request.label },
                            set: { self.request?.label = $0 }))
                    if let problem = FormatPlan.labelProblem(request.label) {
                        Text(problem).font(.caption).foregroundStyle(.red)
                    }
                    SecureField(
                        "Type \(request.volume.wholeDiskBSDName) to confirm",
                        text: Binding(
                            get: { request.confirmation },
                            set: { self.request?.confirmation = $0 }))
                    if let errorText {
                        Text(errorText).foregroundStyle(.red)
                    }
                }
                HStack {
                    Spacer()
                    Button("Erase drive") { format(request) }
                        .buttonStyle(.borderedProminent)
                        .disabled(FormatPlan.labelProblem(request.label) != nil)
                }
            }
        }
        .padding(24)
        .frame(width: 560, height: 530)
        .onAppear { request = model.formatRequest }
    }

    private func format(_ request: FormatRequest) {
        guard
            FormatPlan.confirmationMatches(
                typed: request.confirmation,
                volume: request.volume,
                otherNames: model.volumes.map(\.name))
        else {
            errorText = "Type the drive BSD id or its non-generic name to confirm."
            return
        }
        model.startFormat(request)
    }
}

struct CapacitySheet: View {
    @Bindable var model: AppModel
    @State private var request: CapacityRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            sheetHeader(title: "Capacity test", subtitle: request?.volume.name) {
                model.showingCapacitySheet = false
            }
            if let request {
                Picker(
                    "Mode",
                    selection: Binding(
                        get: { request.mode },
                        set: { self.request?.mode = $0 })
                ) {
                    Text("Free space only").tag(CapacityRequest.Mode.freeSpaceOnly)
                    Text("Whole drive (erases everything)").tag(CapacityRequest.Mode.wholeDrive)
                }
                .pickerStyle(.segmented)
                Text("A fake-capacity drive can damage existing files. Back up the drive before testing it.")
                    .foregroundStyle(.orange)
                Text("Test size: \(Formatting.bytes(request.config.testFileSize))")
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Start capacity test") { model.startCapacity(request) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 520, height: 320)
        .onAppear { request = model.capacityRequest }
    }
}

struct CleanupConfirmationSheet: View {
    let model: AppModel
    let confirmation: CleanupConfirmation

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Remove macOS sidecar files?").font(.title2.weight(.semibold))
            Text("These files were found after a passing copy. Only the listed files will be removed.")
                .foregroundStyle(.secondary)
            List(confirmation.paths, id: \.self) { Text($0) }
            HStack {
                Spacer()
                Button("Keep files") { model.cancelCleanup() }
                Button("Remove listed files") { model.confirmCleanup() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 520, height: 400)
    }
}

private func sheetHeader(
    title: String,
    subtitle: String?,
    close: @escaping () -> Void
) -> some View {
    HStack {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.title2.weight(.semibold))
            if let subtitle { Text(subtitle).foregroundStyle(.secondary) }
        }
        Spacer()
        Button("Close", action: close)
            .keyboardShortcut(.cancelAction)
    }
}
