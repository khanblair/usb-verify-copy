import AppKit
import SwiftUI

@main
struct USBVerifyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel(dependencies: .live())

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .frame(minWidth: 960, minHeight: 600)
                .onAppear {
                    appDelegate.prepareForQuit = { await model.prepareForQuit() }
                }
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    var prepareForQuit: (() async -> Void)?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let prepareForQuit else { return .terminateNow }
        Task {
            await prepareForQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
