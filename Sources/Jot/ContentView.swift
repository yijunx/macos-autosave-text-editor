import SwiftUI
import AppKit

final class UIState: ObservableObject {
    @Published var readingMode: Bool = false
    @Published var readingFindTick: Int = 0
}

struct ContentView: View {
    @EnvironmentObject var store: DocumentStore
    @EnvironmentObject var ui: UIState
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showPreview: Bool = true

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            FileTreeView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 380)
        } detail: {
            Group {
                if let doc = store.activeDocument, doc.isImage {
                    ImageViewerPane(doc: doc)
                } else if ui.readingMode {
                    ReadingPane(doc: store.activeDocument, findTick: ui.readingFindTick)
                } else {
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
                }
            }
            .toolbar { mainToolbar }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var mainToolbar: some ToolbarContent {
        navigationGroup
        principalTitleItem
        primaryActionGroup
    }

    @ToolbarContentBuilder
    private var navigationGroup: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItemGroup(placement: .navigation) { navigationButtons }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItemGroup(placement: .navigation) { navigationButtons }
        }
    }

    @ToolbarContentBuilder
    private var principalTitleItem: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .principal) { PrincipalTitle() }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .principal) { PrincipalTitle() }
        }
    }

    @ToolbarContentBuilder
    private var primaryActionGroup: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItemGroup(placement: .primaryAction) { primaryButtons }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItemGroup(placement: .primaryAction) { primaryButtons }
        }
    }

    @ViewBuilder
    private var navigationButtons: some View {
        ToolbarIconButton(systemName: "square.and.pencil", help: "New file (⌘N)") {
            store.newDocument()
        }
    }

    @ViewBuilder
    private var primaryButtons: some View {
        if let doc = store.activeDocument, isHTML(doc) {
            ContentsOnlyToggle(doc: doc)
        }
        if !(store.activeDocument?.isImage ?? false) {
            if !ui.readingMode {
                ToolbarIconButton(
                    systemName: "sidebar.right",
                    isActive: showPreview,
                    help: showPreview ? "Hide preview" : "Show preview"
                ) {
                    showPreview.toggle()
                }
            }
            ToolbarIconButton(
                systemName: ui.readingMode ? "book.fill" : "book",
                isActive: ui.readingMode,
                help: ui.readingMode ? "Exit reading mode (⌘R)" : "Reading mode (⌘R)"
            ) {
                ui.readingMode.toggle()
            }
        }
    }

    private func isHTML(_ doc: EditorDocument) -> Bool {
        let ext = doc.fileURL?.pathExtension.lowercased() ?? ""
        return ext == "html" || ext == "htm"
    }
}

/// A flat, borderless toolbar button: transparent at rest, a subtle highlight
/// on hover, and an accent-filled pill when `isActive`.
struct ToolbarIconButton: View {
    let systemName: String
    var isActive: Bool = false
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(isActive ? .white : .secondary)
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(fill)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }

    private var fill: Color {
        if isActive { return .accentColor }
        if hovering { return Color.primary.opacity(0.08) }
        return .clear
    }
}

struct ContentsOnlyToggle: View {
    @ObservedObject var doc: EditorDocument

    var body: some View {
        ToolbarIconButton(
            systemName: "text.alignleft",
            isActive: doc.contentsOnly,
            help: "Hide HTML tags so just the content shows"
        ) {
            doc.contentsOnly.toggle()
        }
    }
}

struct PrincipalTitle: View {
    @EnvironmentObject var store: DocumentStore

    var body: some View {
        if let doc = store.activeDocument {
            EditableTitle(doc: doc)
        } else {
            Text("Jot")
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 360)
        }
    }
}

struct EditableTitle: View {
    @ObservedObject var doc: EditorDocument
    @State private var editing = false
    @State private var draft = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .frame(minWidth: 120, maxWidth: 320)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
                    .onAppear { focused = true }
                    .onSubmit { commit() }
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused && editing { commit() }
                    }
            } else {
                Button(action: begin) {
                    HStack(spacing: 5) {
                        Text(doc.displayName)
                            .font(.system(.body, design: .rounded).weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "pencil")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                            .opacity(hovering ? 1 : 0)
                    }
                    .frame(maxWidth: 320)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(hovering ? Color.primary.opacity(0.06) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help("Rename file")
            }
        }
    }

    private func begin() {
        if let url = doc.fileURL {
            draft = url.deletingPathExtension().lastPathComponent
        } else if doc.displayName == "Untitled" {
            draft = ""
        } else {
            draft = (doc.displayName as NSString).deletingPathExtension
        }
        editing = true
    }

    private func commit() {
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

struct ImageViewerPane: View {
    @ObservedObject var doc: EditorDocument

    var body: some View {
        ZStack {
            Color(NSColor.textBackgroundColor)
            if let url = doc.fileURL, let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(20)
            } else {
                Text("Unable to display image")
                    .foregroundColor(.secondary)
            }
        }
    }
}
