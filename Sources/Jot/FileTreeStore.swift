import Foundation
import SwiftUI
import Combine

final class FileTreeStore: ObservableObject {
    @Published var root: URL
    @Published var refreshToken = UUID()
    @Published var searchHits: [SearchHit] = []
    @Published var searchInProgress = false
    let settings: JotSettings
    private var cancellables: Set<AnyCancellable> = []
    private var searchTask: Task<Void, Never>?

    /// Files larger than this are skipped when searching contents.
    private static let maxContentBytes = 5_000_000

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
            if ext == "md" || ext == "markdown" || ext == "html" || ext == "htm" {
                return true
            }
            if JSONSupport.extensions.contains(ext) { return true }
            if YAMLSupport.extensions.contains(ext) { return true }
            return ImageSupport.extensions.contains(ext)
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

    /// Returns true if `url` is a file type the tree displays.
    static func isSupportedFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "md" || ext == "markdown" || ext == "html" || ext == "htm" {
            return true
        }
        if JSONSupport.extensions.contains(ext) { return true }
        if YAMLSupport.extensions.contains(ext) { return true }
        return ImageSupport.extensions.contains(ext)
    }

    /// A text-based supported file whose contents are worth scanning.
    static func isTextFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ImageSupport.extensions.contains(ext) { return false }
        return isSupportedFile(url)
    }

    /// Kicks off a recursive search over the working directory, matching file
    /// names always and file contents when `includeContents` is set. The scan
    /// runs off the main thread after a short debounce and publishes to
    /// `searchHits`; a new call cancels any in-flight scan. An empty query
    /// clears the results immediately.
    func runSearch(query: String, caseSensitive: Bool, includeContents: Bool) {
        searchTask?.cancel()
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            searchHits = []
            searchInProgress = false
            return
        }
        let root = self.root
        searchInProgress = true
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000) // debounce keystrokes
            if Task.isCancelled { return }
            let hits = FileTreeStore.collectHits(
                root: root,
                needle: needle,
                caseSensitive: caseSensitive,
                includeContents: includeContents,
                isCancelled: { Task.isCancelled }
            )
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                self?.searchHits = hits
                self?.searchInProgress = false
            }
        }
    }

    /// Walks `root` and returns every match. Names are always tested; for text
    /// files, contents are scanned too when `includeContents` is set, and the
    /// matching line is captured as a snippet. Honors `caseSensitive`.
    static func collectHits(
        root: URL,
        needle: String,
        caseSensitive: Bool,
        includeContents: Bool,
        isCancelled: () -> Bool
    ) -> [SearchHit] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else {
            return []
        }
        let opts: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var hits: [SearchHit] = []
        for case let url as URL in enumerator {
            if isCancelled() { break }
            if isDirectory(url) { continue }
            guard isSupportedFile(url) else { continue }

            if url.lastPathComponent.range(of: needle, options: opts) != nil {
                hits.append(SearchHit(url: url, snippet: nil))
                continue
            }
            guard includeContents, isTextFile(url) else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size <= maxContentBytes else { continue }
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8),
                  let range = text.range(of: needle, options: opts) else { continue }
            hits.append(SearchHit(url: url, snippet: snippet(from: text, around: range)))
        }
        return hits.sorted {
            $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedAscending
        }
    }

    /// The trimmed line containing `range`, truncated for display.
    private static func snippet(from text: String, around range: Range<String.Index>) -> String {
        let line = text[text.lineRange(for: range)]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let maxLen = 140
        return line.count > maxLen ? String(line.prefix(maxLen)) + "\u{2026}" : line
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

struct SearchHit: Identifiable, Hashable {
    let url: URL
    /// The matching line of content, or nil when only the file name matched.
    let snippet: String?
    var id: String { url.path }
}

struct FileNode: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    var id: String { url.path }
    var displayName: String {
        isDirectory ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    }
}
