import SwiftUI
import AppKit

final class JotSettings: ObservableObject {
    static let workingDirKey = "workingDirectoryPath"

    @Published var workingDirectory: URL {
        didSet {
            UserDefaults.standard.set(workingDirectory.path, forKey: Self.workingDirKey)
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
    }

    func resetToDefault() {
        workingDirectory = Self.defaultDirectory
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
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 220)
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
