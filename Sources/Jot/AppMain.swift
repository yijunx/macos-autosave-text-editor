import SwiftUI

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
                Button("Close Tab") { store.closeActive() }
                    .keyboardShortcut("w", modifiers: .command)
                Divider()
                Button("Next Tab") { store.next() }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Tab") { store.previous() }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Button("Reveal in Finder") { store.revealActive() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}
