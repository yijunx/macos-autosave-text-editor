import Foundation
import SwiftUI

final class FileTreeStore: ObservableObject {
    @Published var root: URL
    @Published var refreshToken = UUID()

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.root = docs
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleChange),
            name: .jotFilesChanged,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleChange() {
        DispatchQueue.main.async { [weak self] in
            self?.refreshToken = UUID()
        }
    }

    func refresh() {
        refreshToken = UUID()
    }

    func children(of url: URL) -> [FileNode] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let filtered = contents.filter { item in
            if Self.isDirectory(item) { return true }
            return item.pathExtension.lowercased() == "md"
        }
        return filtered
            .sorted { lhs, rhs in
                let lDir = Self.isDirectory(lhs)
                let rDir = Self.isDirectory(rhs)
                if lDir != rDir { return lDir }
                if lDir {
                    // Date-named folders first, newest at top
                    return lhs.lastPathComponent > rhs.lastPathComponent
                }
                return lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
            }
            .map { FileNode(url: $0, isDirectory: Self.isDirectory($0)) }
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    static func todayFolderName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}

struct FileNode: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    var id: String { url.path }
    var displayName: String {
        isDirectory ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    }
}
