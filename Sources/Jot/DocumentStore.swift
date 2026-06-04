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
    @Published var fileURL: URL? = nil
    @Published var scrollFraction: CGFloat = 0
    @Published var contentsOnly: Bool = false
    private var saveTask: DispatchWorkItem?

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
            let baseName = DocumentStore.deriveFilename(from: content)
            let url = DocumentStore.uniqueURL(in: folder, baseName: baseName, ext: "md")
            fileURL = url
            displayName = url.lastPathComponent
            didCreate = true
        }
        guard let url = fileURL else { return }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
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
            doc.content = content
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
        let firstLine = content.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? ""
        let head = String(firstLine.prefix(60)).trimmingCharacters(in: .whitespaces)
        let slug = sanitize(head)
        return slug.isEmpty ? "untitled" : slug
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
