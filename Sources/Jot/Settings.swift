import SwiftUI
import AppKit

enum CopyPathFormat: String, CaseIterable, Identifiable {
    case absolute
    case tilde
    case relative

    var id: String { rawValue }

    var label: String {
        switch self {
        case .absolute: return "Absolute"
        case .tilde:    return "Home-relative (~)"
        case .relative: return "Relative to working folder"
        }
    }

    func example(workingDirectory: URL) -> String {
        let sample = workingDirectory.appendingPathComponent("2026-06-09/note.md")
        return format(sample, workingDirectory: workingDirectory)
    }

    func format(_ url: URL, workingDirectory: URL) -> String {
        let standardized = url.standardizedFileURL.resolvingSymlinksInPath().path
        switch self {
        case .absolute:
            return standardized
        case .tilde:
            return (standardized as NSString).abbreviatingWithTildeInPath
        case .relative:
            let base = workingDirectory.standardizedFileURL.resolvingSymlinksInPath().path
            if standardized == base { return "." }
            if standardized.hasPrefix(base + "/") {
                return String(standardized.dropFirst(base.count + 1))
            }
            return (standardized as NSString).abbreviatingWithTildeInPath
        }
    }
}

final class JotSettings: ObservableObject {
    static let workingDirKey = "workingDirectoryPath"
    static let copyPathFormatKey = "copyPathFormat"

    @Published var workingDirectory: URL {
        didSet {
            UserDefaults.standard.set(workingDirectory.path, forKey: Self.workingDirKey)
        }
    }

    @Published var copyPathFormat: CopyPathFormat {
        didSet {
            UserDefaults.standard.set(copyPathFormat.rawValue, forKey: Self.copyPathFormatKey)
        }
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    init() {
        if let path = UserDefaults.standard.string(forKey: Self.workingDirKey),
           FileManager.default.fileExists(atPath: path) {
            workingDirectory = URL(fileURLWithPath: path)
        } else {
            workingDirectory = Self.defaultDirectory
        }
        if let raw = UserDefaults.standard.string(forKey: Self.copyPathFormatKey),
           let fmt = CopyPathFormat(rawValue: raw) {
            copyPathFormat = fmt
        } else {
            copyPathFormat = .tilde
        }
    }

    func resetToDefault() {
        workingDirectory = Self.defaultDirectory
    }

    func formattedPath(for url: URL) -> String {
        copyPathFormat.format(url, workingDirectory: workingDirectory)
    }
}

struct SettingsView: View {
    @EnvironmentObject var settings: JotSettings

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 10) {
                    Text(settings.workingDirectory.path)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(settings.workingDirectory.path)
                    Button("Change…") { chooseFolder() }
                    Button("Reset") { settings.resetToDefault() }
                }
            } header: {
                Text("Working folder")
            } footer: {
                Text("New files autosave under **<Working folder>/<YYYY-MM-DD>/**. Files opened from outside this folder are copied in before opening.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            Section {
                Picker("Format", selection: $settings.copyPathFormat) {
                    ForEach(CopyPathFormat.allCases) { fmt in
                        Text(fmt.label).tag(fmt)
                    }
                }
                Text(settings.copyPathFormat.example(workingDirectory: settings.workingDirectory))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } header: {
                Text("Copy path")
            } footer: {
                Text("Right-click a file in the sidebar to copy its path or delete it.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 340)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.workingDirectory
        panel.prompt = "Use Folder"
        panel.title = "Choose a working folder"
        if panel.runModal() == .OK, let url = panel.url {
            settings.workingDirectory = url
        }
    }
}
