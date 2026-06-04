import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var store: DocumentStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showPreview: Bool = true

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            FileTreeView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 380)
        } detail: {
            HSplitView {
                EditorPane()
                    .frame(minWidth: 320)

                if showPreview {
                    if let doc = store.activeDocument {
                        MarkdownPreviewView(doc: doc)
                            .frame(minWidth: 260, idealWidth: 380)
                    } else {
                        Color(NSColor.textBackgroundColor)
                            .frame(minWidth: 260, idealWidth: 380)
                    }
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button {
                        store.newDocument()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .help("New file (⌘N)")
                }
                ToolbarItem(placement: .principal) {
                    Text(store.activeDocument?.displayName ?? "Jot")
                        .font(.system(.body).weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 360)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if let doc = store.activeDocument, isHTML(doc) {
                        ContentsOnlyToggle(doc: doc)
                    }
                    Button {
                        showPreview.toggle()
                    } label: {
                        Image(systemName: "sidebar.right")
                            .foregroundColor(showPreview ? .accentColor : .secondary)
                    }
                    .help(showPreview ? "Hide preview" : "Show preview")
                }
            }
        }
        .navigationTitle(store.activeDocument?.displayName ?? "Jot")
    }

    private func isHTML(_ doc: EditorDocument) -> Bool {
        let ext = doc.fileURL?.pathExtension.lowercased() ?? ""
        return ext == "html" || ext == "htm"
    }
}

struct ContentsOnlyToggle: View {
    @ObservedObject var doc: EditorDocument

    var body: some View {
        Toggle(isOn: $doc.contentsOnly) {
            Label("Contents only", systemImage: "text.alignleft")
        }
        .toggleStyle(.button)
        .help("Hide HTML tags so just the content shows")
    }
}

struct EditorPane: View {
    @EnvironmentObject var store: DocumentStore

    var body: some View {
        ZStack {
            Color(NSColor.textBackgroundColor)
            if let doc = store.activeDocument {
                EditorView(doc: doc)
                    .id(doc.id)
            } else {
                EmptyStateView()
            }
        }
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var store: DocumentStore

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Text("Jot")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
            Text("Markdown notes that save themselves.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .padding(.top, 2)
            Button {
                store.newDocument()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text("Create new file")
                }
                .font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 22)
            Text("or press ⌘N")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.65))
                .padding(.top, 8)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EditorView: View {
    @EnvironmentObject var store: DocumentStore
    @ObservedObject var doc: EditorDocument

    var body: some View {
        CodeEditorView(
            text: $doc.content,
            scrollFraction: $doc.scrollFraction,
            hideTags: shouldHideTags
        )
        .background(Color(NSColor.textBackgroundColor))
        .onChange(of: doc.content) { _, _ in
            doc.scheduleSave(folder: store.folder)
        }
    }

    private var shouldHideTags: Bool {
        guard doc.contentsOnly else { return false }
        let ext = doc.fileURL?.pathExtension.lowercased() ?? ""
        return ext == "html" || ext == "htm"
    }
}
