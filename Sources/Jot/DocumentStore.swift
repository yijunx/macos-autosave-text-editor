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
            displayName = url.deletingPathExtension().lastPathComponent
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
            displayName = cleaned
            return
        }
        let folder = oldURL.deletingLastPathComponent()
        let desired = folder.appendingPathComponent("\(cleaned).md")
        if desired == oldURL { return }
        let finalURL = FileManager.default.fileExists(atPath: desired.path)
            ? DocumentStore.uniqueURL(in: folder, baseName: cleaned, ext: "md")
            : desired
        do {
            try FileManager.default.moveItem(at: oldURL, to: finalURL)
            fileURL = finalURL
            displayName = finalURL.deletingPathExtension().lastPathComponent
            NotificationCenter.default.post(name: .jotFilesChanged, object: nil)
        } catch {
            NSLog("Rename failed: %@", String(describing: error))
        }
    }
}

final class DocumentStore: ObservableObject {
    @Published var documents: [EditorDocument] = []
    @Published var activeID: UUID?

    var folder: URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let folder = docs.appendingPathComponent(formatter.string(from: Date()))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func newDocument() {
        let doc = EditorDocument()
        documents.append(doc)
        activeID = doc.id
    }

    func openFile(at url: URL) {
        if let existing = documents.first(where: { $0.fileURL == url }) {
            activeID = existing.id
            return
        }
        let doc = EditorDocument()
        doc.fileURL = url
        doc.displayName = url.deletingPathExtension().lastPathComponent
        if let content = try? String(contentsOf: url, encoding: .utf8) {
            doc.content = content
        }
        documents.append(doc)
        activeID = doc.id
    }

    func closeActive() {
        guard let id = activeID else { return }
        close(id: id)
    }

    func close(id: UUID) {
        guard let idx = documents.firstIndex(where: { $0.id == id }) else { return }
        let doc = documents[idx]
        doc.saveNow(folder: folder)
        documents.remove(at: idx)
        if activeID == id {
            if documents.isEmpty {
                activeID = nil
            } else {
                activeID = documents[max(0, idx - 1)].id
            }
        }
    }

    func next() {
        guard let id = activeID, let idx = documents.firstIndex(where: { $0.id == id }) else { return }
        activeID = documents[(idx + 1) % documents.count].id
    }

    func previous() {
        guard let id = activeID, let idx = documents.firstIndex(where: { $0.id == id }) else { return }
        let prev = (idx - 1 + documents.count) % documents.count
        activeID = documents[prev].id
    }

    func revealActive() {
        guard let id = activeID,
              let doc = documents.first(where: { $0.id == id }),
              let url = doc.fileURL else { return }
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
