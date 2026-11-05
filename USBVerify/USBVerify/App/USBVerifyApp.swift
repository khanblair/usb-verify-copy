import AppKit
import SwiftUI

@main
struct USBVerifyApp: App {
    @State private var model = AppModel(dependencies: .live())

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .frame(minWidth: 960, minHeight: 600)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Copy") {
                    model.presentCopySheet()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }

        MenuBarExtra {
            Button("Show Window") {
                NSApp.activate(ignoringOtherApps: true)
            }
            Divider()
            Button("Quit USB Verify") {
                NSApp.terminate(nil)
            }
        } label: {
            Label(model.menuBarStatus, systemImage: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.menu)
    }
}
