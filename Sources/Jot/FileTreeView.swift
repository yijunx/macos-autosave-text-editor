import SwiftUI
import AppKit

struct FileTreeView: View {
    @EnvironmentObject var store: DocumentStore
    @EnvironmentObject var tree: FileTreeStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .foregroundColor(.secondary)
                Text(tree.root.lastPathComponent)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(tree.root.path)
                Spacer()
                Button {
                    store.newDocument()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("New file (⌘N)")
                Button {
                    tree.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    DirectoryRow(url: tree.root, depth: 0, alwaysExpanded: true)
                }
                .padding(.vertical, 4)
                .id(tree.refreshToken)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
}

struct DirectoryRow: View {
    @EnvironmentObject var tree: FileTreeStore
    let url: URL
    let depth: Int
    let alwaysExpanded: Bool
    @State private var expanded: Bool

    init(url: URL, depth: Int, alwaysExpanded: Bool = false) {
        self.url = url
        self.depth = depth
        self.alwaysExpanded = alwaysExpanded
        let isToday = url.lastPathComponent == FileTreeStore.todayFolderName()
        _expanded = State(initialValue: alwaysExpanded || isToday)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !alwaysExpanded {
                Button(action: { expanded.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 10)
                        Image(systemName: expanded ? "folder.fill" : "folder")
                            .font(.system(size: 11))
                            .foregroundColor(.accentColor.opacity(0.85))
                        Text(url.lastPathComponent)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.leading, CGFloat(depth) * 12 + 8)
                    .padding(.vertical, 3)
                    .padding(.trailing, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if expanded {
                ForEach(tree.children(of: url), id: \.id) { node in
                    if node.isDirectory {
                        DirectoryRow(url: node.url, depth: depth + (alwaysExpanded ? 0 : 1))
                    } else {
                        FileRow(url: node.url, depth: depth + (alwaysExpanded ? 0 : 1))
                    }
                }
            }
        }
    }
}

struct FileRow: View {
    @EnvironmentObject var store: DocumentStore
    let url: URL
    let depth: Int

    var isActive: Bool {
        store.activeDocument?.fileURL == url
    }

    private var ext: String { url.pathExtension.lowercased() }

    private var iconName: String {
        switch ext {
        case "html", "htm": return "chevron.left.forwardslash.chevron.right"
        case "md", "markdown": return "doc.text"
        default: return "doc"
        }
    }

    private var iconColor: Color {
        switch ext {
        case "html", "htm": return .orange
        case "md", "markdown": return .blue.opacity(0.85)
        default: return .secondary
        }
    }

    var body: some View {
        Button(action: { store.openFile(at: url) }) {
            HStack(spacing: 5) {
                Image(systemName: iconName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(iconColor)
                    .frame(width: 14, alignment: .center)
                Text(url.lastPathComponent)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.leading, CGFloat(depth) * 12 + 22)
            .padding(.vertical, 3)
            .padding(.trailing, 8)
            .background(isActive ? Color.accentColor.opacity(0.18) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(url.path)
    }
}
