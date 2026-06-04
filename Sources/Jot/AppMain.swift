import SwiftUI
import AppKit

@main
struct JotApp: App {
    @StateObject private var store = DocumentStore()
    @StateObject private var tree = FileTreeStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(tree)
                .frame(minWidth: 800, minHeight: 500)
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
            CommandGroup(after: .textEditing) {
                Section {
                    Button("Find…") { sendFinderAction(.showFindInterface) }
                        .keyboardShortcut("f", modifiers: .command)
                    Button("Find Next") { sendFinderAction(.nextMatch) }
                        .keyboardShortcut("g", modifiers: .command)
                    Button("Find Previous") { sendFinderAction(.previousMatch) }
                        .keyboardShortcut("g", modifiers: [.command, .shift])
                }
            }
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
