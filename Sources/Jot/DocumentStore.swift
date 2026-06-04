import Foundation
import SwiftUI
import AppKit

extension Notification.Name {
    static let jotFilesChanged = Notification.Name("jotFilesChanged")
}

final class EditorDocument: ObservableObject, Identifiable {
    let id = UUID()
    @Published var content: String = ""
    @Published var displayName: String = "Untitled"
    @Published var fileURL: URL? = nil {
        didSet {
            if oldValue != fileURL { restartWatcher() }
        }
    }
    @Published var scrollFraction: CGFloat = 0
    @Published var contentsOnly: Bool = false
    private var pendingName: String? = nil
    private var saveTask: DispatchWorkItem?
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var lastSelfWriteAt: Date?
    /// Snapshot of `content` as it last existed on disk. The doc is "dirty"
    /// (worth writing) iff `content != savedContent`.
    private var savedContent: String = ""

    var isDirty: Bool { content != savedContent }

    /// Replace `content` with a value that was just read from disk so the
    /// doc starts in a clean (non-dirty) state.
    func loadContent(_ newContent: String) {
        savedContent = newContent
        content = newContent
    }

    deinit {
        stopWatcher()
    }

    private func restartWatcher() {
        stopWatcher()
        guard let url = fileURL else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.handleExternalFileChange()
        }
        source.setCancelHandler {
            close(fd)
        }
        fileWatcher = source
        source.resume()
    }

    private func stopWatcher() {
        fileWatcher?.cancel()
        fileWatcher = nil
    }

    private func handleExternalFileChange() {
        guard let url = fileURL else { return }
        // Atomic writes (ours and others) replace the inode, so we need to
        // rewire the watcher onto the new file regardless of who wrote it.
        defer { restartWatcher() }

        if let last = lastSelfWriteAt, Date().timeIntervalSince(last) < 0.5 {
            // Our own save just landed — nothing to reload.
            return
        }
        guard let newContent = try? String(contentsOf: url, encoding: .utf8),
              newContent != content else { return }
        saveTask?.cancel()
        loadContent(newContent)
    }

    func scheduleSave(folder: URL) {
        if fileURL == nil {
            let preview = DocumentStore.deriveFilename(from: content)
            displayName = preview.isEmpty ? "Untitled" : preview
        }
        saveTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.save(folder: folder)
        }
        saveTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: task)
    }

    func saveNow(folder: URL) {
        saveTask?.cancel()
        save(folder: folder)
    }

    private func save(folder: URL) {
        var didCreate = false
        if fileURL == nil {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let baseName: String
            if let pending = pendingName, !pending.isEmpty {
                baseName = pending
                pendingName = nil
            } else {
                baseName = DocumentStore.deriveFilename(from: content)
            }
            let url = DocumentStore.uniqueURL(in: folder, baseName: baseName, ext: "md")
            fileURL = url
            displayName = url.lastPathComponent
            didCreate = true
        }
        guard let url = fileURL else { return }
        // Skip the write entirely when the buffer matches what's on disk —
        // avoids gratuitous mtime bumps on doc-switch/close.
        if !didCreate && content == savedContent {
            return
        }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            lastSelfWriteAt = Date()
            savedContent = content
            if didCreate {
                NotificationCenter.default.post(name: .jotFilesChanged, object: nil)
            }
        } catch {
            NSLog("Autosave failed: %@", String(describing: error))
        }
    }

    func rename(to newName: String) {
        let cleaned = DocumentStore.sanitize(newName)
        guard !cleaned.isEmpty else { return }
        guard let oldURL = fileURL else {
            pendingName = cleaned
            displayName = cleaned + ".md"
            return
        }
        let folder = oldURL.deletingLastPathComponent()
        let ext = oldURL.pathExtension.isEmpty ? "md" : oldURL.pathExtension
        let desired = folder.appendingPathComponent("\(cleaned).\(ext)")
        if desired == oldURL { return }
        let finalURL = FileManager.default.fileExists(atPath: desired.path)
            ? DocumentStore.uniqueURL(in: folder, baseName: cleaned, ext: ext)
            : desired
        do {
            try FileManager.default.moveItem(at: oldURL, to: finalURL)
            fileURL = finalURL
            displayName = finalURL.lastPathComponent
            NotificationCenter.default.post(name: .jotFilesChanged, object: nil)
        } catch {
            NSLog("Rename failed: %@", String(describing: error))
        }
    }
}

final class DocumentStore: ObservableObject {
    @Published var activeDocument: EditorDocument? = nil
    let settings: JotSettings

    init(settings: JotSettings) {
        self.settings = settings
    }

    var workingDirectory: URL {
        settings.workingDirectory
    }

    var folder: URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let folder = workingDirectory.appendingPathComponent(formatter.string(from: Date()))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func newDocument() {
        activeDocument?.saveNow(folder: folder)
        activeDocument = EditorDocument()
    }

    func openFile(at url: URL) {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let workDir = workingDirectory.resolvingSymlinksInPath().standardizedFileURL
        let inside = resolved.path == workDir.path
            || resolved.path.hasPrefix(workDir.path + "/")

        let targetURL: URL
        if inside {
            targetURL = resolved
        } else {
            guard let imported = importExternalFile(from: resolved) else { return }
            targetURL = imported
            NotificationCenter.default.post(name: .jotFilesChanged, object: nil)
        }

        if activeDocument?.fileURL == targetURL { return }
        activeDocument?.saveNow(folder: folder)
        let doc = EditorDocument()
        doc.fileURL = targetURL
        doc.displayName = targetURL.lastPathComponent
        if let content = try? String(contentsOf: targetURL, encoding: .utf8) {
            doc.loadContent(content)
        }
        activeDocument = doc
    }

    private func importExternalFile(from source: URL) -> URL? {
        let destDir = folder
        let baseName = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension.isEmpty ? "md" : source.pathExtension
        let slugged = DocumentStore.sanitize(baseName)
        let finalBase = slugged.isEmpty ? "imported" : slugged
        let target = DocumentStore.uniqueURL(in: destDir, baseName: finalBase, ext: ext)
        do {
            try FileManager.default.copyItem(at: source, to: target)
            return target
        } catch {
            NSLog("Failed to import %@: %@", source.path, String(describing: error))
            return nil
        }
    }

    func closeActive() {
        activeDocument?.saveNow(folder: folder)
        activeDocument = nil
    }

    func revealActive() {
        guard let url = activeDocument?.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func deriveFilename(from content: String) -> String {
        let lines = content.components(separatedBy: "\n")
        var startIndex = 0

        // YAML frontmatter: if the first non-blank line is `---`, look for a closing
        // `---`. Prefer a `name:` or `title:` field inside; otherwise skip the block.
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" {
            var closing: Int? = nil
            var i = 1
            while i < lines.count {
                if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                    closing = i
                    break
                }
                i += 1
            }
            if let c = closing {
                for j in 1..<c {
                    if let v = parseYAMLField(lines[j], key: "name")
                        ?? parseYAMLField(lines[j], key: "title") {
                        let slug = sanitize(v)
                        if !slug.isEmpty { return slug }
                    }
                }
                startIndex = c + 1
            }
        }

        // Walk to the first line with real content; strip leading markdown markers.
        for i in startIndex..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" { continue }
            let stripped = stripMarkdownPrefix(trimmed)
            let head = String(stripped.prefix(60)).trimmingCharacters(in: .whitespaces)
            let slug = sanitize(head)
            if !slug.isEmpty { return slug }
        }

        return "untitled"
    }

    private static func parseYAMLField(_ line: String, key: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let prefix = key + ":"
        guard trimmed.lowercased().hasPrefix(prefix) else { return nil }
        var value = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\""))
               || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }

    private static func stripMarkdownPrefix(_ s: String) -> String {
        var t = s
        while t.hasPrefix("#") { t = String(t.dropFirst()) }
        t = t.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") || t.hasPrefix("> ") {
            return String(t.dropFirst(2))
        }
        // `N. ` ordered list
        if let dot = t.firstIndex(of: "."),
           dot > t.startIndex,
           t[..<dot].allSatisfy({ $0.isNumber }) {
            let afterDot = t.index(after: dot)
            if afterDot < t.endIndex, t[afterDot] == " " {
                return String(t[t.index(after: afterDot)...])
            }
        }
        return t
    }

    static func sanitize(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        var out = ""
        for scalar in s.unicodeScalars where allowed.contains(scalar) {
            out.append(Character(scalar))
        }
        out = out.replacingOccurrences(of: " ", with: "-")
        while out.contains("--") {
            out = out.replacingOccurrences(of: "--", with: "-")
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return String(out.prefix(40)).lowercased()
    }

    static func uniqueURL(in folder: URL, baseName: String, ext: String) -> URL {
        var candidate = folder.appendingPathComponent("\(baseName).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(baseName)-\(n).\(ext)")
            n += 1
        }
        return candidate
    }
}
