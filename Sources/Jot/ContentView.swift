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
                VStack(spacing: 0) {
                    if !store.documents.isEmpty {
                        TabBar()
                        Divider()
                    }
                    EditorPane()
                }
                .frame(minWidth: 320)

                if showPreview {
                    if let doc = activeDoc {
                        MarkdownPreviewView(doc: doc)
                            .frame(minWidth: 260, idealWidth: 380)
                    } else {
                        Color(NSColor.textBackgroundColor)
                            .frame(minWidth: 260, idealWidth: 380)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showPreview.toggle()
                    } label: {
                        Image(systemName: showPreview ? "sidebar.right" : "sidebar.right")
                            .symbolRenderingMode(showPreview ? .multicolor : .monochrome)
                            .foregroundColor(showPreview ? .accentColor : .secondary)
                    }
                    .help(showPreview ? "Hide preview" : "Show preview")
                }
            }
        }
        .navigationTitle(activeDoc?.displayName ?? "Jot")
    }

    var activeDoc: EditorDocument? {
        guard let id = store.activeID else { return nil }
        return store.documents.first { $0.id == id }
    }
}

struct TabBar: View {
    @EnvironmentObject var store: DocumentStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(store.documents) { doc in
                    TabItem(doc: doc)
                }
                Button {
                    store.newDocument()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New file (⌘N)")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

struct TabItem: View {
    @EnvironmentObject var store: DocumentStore
    @ObservedObject var doc: EditorDocument
    @State private var editing = false
    @State private var draft: String = ""
    @FocusState private var nameFocused: Bool

    var isActive: Bool { store.activeID == doc.id }

    var body: some View {
        HStack(spacing: 6) {
            if editing {
                TextField("", text: $draft, onCommit: commitRename)
                    .textFieldStyle(.plain)
                    .focused($nameFocused)
                    .frame(minWidth: 60, maxWidth: 220)
                    .onAppear { nameFocused = true }
                    .onExitCommand { editing = false }
            } else {
                Text(doc.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 220)
            }
            Button {
                store.close(id: doc.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close tab")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentColor.opacity(0.20) : Color.gray.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isActive ? Color.accentColor.opacity(0.45) : Color.gray.opacity(0.18), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            beginEdit()
        }
        .onTapGesture(count: 1) {
            if !editing {
                store.activeID = doc.id
            }
        }
        .help(doc.fileURL?.path ?? "Not yet saved")
    }

    private func beginEdit() {
        draft = doc.displayName
        editing = true
    }

    private func commitRename() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            doc.rename(to: trimmed)
        }
        editing = false
    }
}

struct EditorPane: View {
    @EnvironmentObject var store: DocumentStore

    var body: some View {
        ZStack {
            Color(NSColor.textBackgroundColor)
            if let doc = activeDoc {
                EditorView(doc: doc)
                    .id(doc.id)
            } else {
                EmptyStateView()
            }
        }
    }

    var activeDoc: EditorDocument? {
        guard let id = store.activeID else { return nil }
        return store.documents.first { $0.id == id }
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
        CodeEditorView(text: $doc.content, scrollFraction: $doc.scrollFraction)
            .background(Color(NSColor.textBackgroundColor))
            .onChange(of: doc.content) { _, _ in
                doc.scheduleSave(folder: store.folder)
            }
    }
}
