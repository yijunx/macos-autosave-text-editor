import Foundation
import SwiftUI
import Combine

final class FileTreeStore: ObservableObject {
    @Published var root: URL
    @Published var refreshToken = UUID()
    let settings: JotSettings
    private var cancellables: Set<AnyCancellable> = []

    init(settings: JotSettings) {
        self.settings = settings
        self.root = settings.workingDirectory

        settings.$workingDirectory
            .sink { [weak self] newURL in
                self?.root = newURL
                self?.refreshToken = UUID()
            }
            .store(in: &cancellables)

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

    /// Moves `url` to the Trash. Returns true on success.
    @discardableResult
    func trash(_ url: URL) -> Bool {
        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            NotificationCenter.default.post(name: .jotFilesChanged, object: nil)
            return true
        } catch {
            NSLog("Trash failed for %@: %@", url.path, String(describing: error))
            return false
        }
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
            let ext = item.pathExtension.lowercased()
            return ext == "md" || ext == "markdown" || ext == "html" || ext == "htm"
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
