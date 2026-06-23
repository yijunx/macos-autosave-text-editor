import Foundation
import SwiftUI
import AppKit

extension Notification.Name {
    static let jotFilesChanged = Notification.Name("jotFilesChanged")
}

enum ImageSupport {
    static let extensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif", "svg"
    ]

    static func isImage(_ url: URL?) -> Bool {
        guard let ext = url?.pathExtension.lowercased() else { return false }
        return extensions.contains(ext)
    }
}

enum JSONSupport {
    static let extensions: Set<String> = ["json", "jsonl"]

    static func isJSON(_ url: URL?) -> Bool {
        guard let ext = url?.pathExtension.lowercased() else { return false }
        return extensions.contains(ext)
    }

    static func beautifyFileIfPossible(at url: URL) {
        guard let content = try? String(contentsOf: url, encoding: .utf8),
              let formatted = beautifiedContent(content, fileExtension: url.pathExtension),
              formatted != content else { return }
        do {
            try formatted.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSLog("JSON beautify failed for %@: %@", url.path, String(describing: error))
        }
    }

    private static func beautifiedContent(_ content: String, fileExtension: String) -> String? {
        switch fileExtension.lowercased() {
        case "json":
            return prettyPrintedJSON(content)
        case "jsonl":
            return normalizedJSONLines(content)
        default:
            return nil
        }
    }

    private static func prettyPrintedJSON(_ content: String) -> String? {
        guard let data = content.data(using: .utf8) else { return nil }
        do {
            let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            let pretty = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .withoutEscapingSlashes]
            )
            guard var text = String(data: pretty, encoding: .utf8) else { return nil }
            if !text.hasSuffix("\n") { text += "\n" }
            return text
        } catch {
            return nil
        }
    }

    private static func normalizedJSONLines(_ content: String) -> String? {
        let hasTrailingNewline = content.hasSuffix("\n") || content.hasSuffix("\r")
        var lines = content.components(separatedBy: .newlines)
        if hasTrailingNewline, lines.last == "" {
            lines.removeLast()
        }

        var sawJSON = false
        var formatted: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                formatted.append("")
                continue
            }
            guard let data = trimmed.data(using: .utf8) else { return nil }
            do {
                let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
                let pretty = try JSONSerialization.data(
                    withJSONObject: object,
                    options: [.prettyPrinted, .withoutEscapingSlashes]
                )
                guard let text = String(data: pretty, encoding: .utf8) else { return nil }
                formatted.append(singleLinePrettyJSON(text))
                sawJSON = true
            } catch {
                return nil
            }
        }

        guard sawJSON else { return nil }
        var result = formatted.joined(separator: "\n")
        if hasTrailingNewline { result += "\n" }
        return result
    }

    private static func singleLinePrettyJSON(_ text: String) -> String {
        var output = ""
        var inString = false
        var escaped = false
        var pendingSpace = false

        for ch in text {
            if inString {
                output.append(ch)
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
                continue
            }

            if ch == "\"" {
                appendPendingSpaceIfNeeded(&output, pendingSpace: &pendingSpace, before: ch)
                output.append(ch)
                inString = true
            } else if ch.isWhitespace {
                pendingSpace = true
            } else {
                appendPendingSpaceIfNeeded(&output, pendingSpace: &pendingSpace, before: ch)
                output.append(ch)
            }
        }

        return output.trimmingCharacters(in: .whitespaces)
    }

    private static func appendPendingSpaceIfNeeded(_ output: inout String,
                                                   pendingSpace: inout Bool,
                                                   before next: Character) {
        guard pendingSpace else { return }
        pendingSpace = false
        guard !output.isEmpty else { return }
        if ",:}]".contains(next) { return }
        output.append(" ")
    }
}

enum YAMLSupport {
    static let extensions: Set<String> = ["yaml", "yml"]
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

    var isImage: Bool { ImageSupport.isImage(fileURL) }

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
        if !ImageSupport.isImage(targetURL),
           let content = try? String(contentsOf: targetURL, encoding: .utf8) {
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
            if JSONSupport.isJSON(target) {
                JSONSupport.beautifyFileIfPossible(at: target)
            }
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

    /// Drop the active document without saving if its file lives at (or
    /// beneath) `url`. Used after deleting from the sidebar so we don't
    /// re-create the just-trashed file via autosave.
    func discardIfActive(at url: URL) {
        guard let doc = activeDocument, let docURL = doc.fileURL else { return }
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        let active = docURL.standardizedFileURL.resolvingSymlinksInPath().path
        if active == target || active.hasPrefix(target + "/") {
            activeDocument = nil
        }
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
