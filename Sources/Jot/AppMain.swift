import SwiftUI
import AppKit

final class JotAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct JotApp: App {
    @NSApplicationDelegateAdaptor(JotAppDelegate.self) private var appDelegate
    @StateObject private var settings: JotSettings
    @StateObject private var store: DocumentStore
    @StateObject private var tree: FileTreeStore
    @StateObject private var ui = UIState()

    init() {
        let s = JotSettings()
        _settings = StateObject(wrappedValue: s)
        _store = StateObject(wrappedValue: DocumentStore(settings: s))
        _tree = StateObject(wrappedValue: FileTreeStore(settings: s))
    }

    var body: some Scene {
        Window("Jot", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(tree)
                .environmentObject(settings)
                .environmentObject(ui)
                .frame(minWidth: 800, minHeight: 500)
                .onOpenURL { url in
                    store.openFile(at: url)
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New File") { store.newDocument() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("Close File") { store.closeActive() }
                    .keyboardShortcut("w", modifiers: .command)
                Divider()
                Button("Reveal in Finder") { store.revealActive() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Button(ui.readingMode ? "Exit Reading Mode" : "Reading Mode") {
                    ui.readingMode.toggle()
                }
                .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button("Zoom In") {
                    settings.zoomReadingModeIn()
                }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(!ui.readingMode)
                Button("Zoom Out") {
                    settings.zoomReadingModeOut()
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!ui.readingMode)
            }
            CommandGroup(after: .textEditing) {
                Section {
                    Button("Find…") {
                        if ui.readingMode {
                            ui.readingFindTick &+= 1
                        } else {
                            sendFinderAction(.showFindInterface)
                        }
                    }
                    .keyboardShortcut("f", modifiers: .command)
                    Button("Find Next") { sendFinderAction(.nextMatch) }
                        .keyboardShortcut("g", modifiers: .command)
                    Button("Find Previous") { sendFinderAction(.previousMatch) }
                        .keyboardShortcut("g", modifiers: [.command, .shift])
                }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
        }
    }
}

private func sendFinderAction(_ action: NSTextFinder.Action) {
    let menuItem = NSMenuItem()
    menuItem.tag = action.rawValue
    NSApp.sendAction(
        #selector(NSResponder.performTextFinderAction(_:)),
        to: nil,
        from: menuItem
    )
}
