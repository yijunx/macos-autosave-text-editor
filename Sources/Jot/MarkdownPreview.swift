import SwiftUI
import AppKit
import WebKit

struct MarkdownPreviewView: View {
    @ObservedObject var doc: EditorDocument

    var body: some View {
        WebPreviewView(doc: doc)
            .background(Color(NSColor.textBackgroundColor))
    }
}

final class PreviewSearchController: ObservableObject {
    weak var webView: WKWebView?
    @Published var notFound: Bool = false

    func find(_ query: String, forward: Bool = true) {
        guard let webView = webView, !query.isEmpty else {
            notFound = false
            return
        }
        let cfg = WKFindConfiguration()
        cfg.backwards = !forward
        cfg.wraps = true
        cfg.caseSensitive = false
        webView.find(query, configuration: cfg) { [weak self] result in
            DispatchQueue.main.async {
                self?.notFound = !result.matchFound
            }
        }
    }
}

struct ReadingPane: View {
    let doc: EditorDocument?
    let findTick: Int

    @StateObject private var search = PreviewSearchController()
    @State private var findActive = false
    @State private var query = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if findActive {
                ReadingFindBar(
                    query: $query,
                    notFound: search.notFound,
                    focused: $fieldFocused,
                    onSubmit: { search.find(query, forward: true) },
                    onPrev: { search.find(query, forward: false) },
                    onNext: { search.find(query, forward: true) },
                    onClose: close
                )
            }
            if let doc {
                WebPreviewView(doc: doc, search: search)
                    .background(Color(NSColor.textBackgroundColor))
            } else {
                Color(NSColor.textBackgroundColor)
            }
        }
        .onChange(of: findTick) { _, _ in
            findActive = true
            DispatchQueue.main.async { fieldFocused = true }
        }
        .onChange(of: query) { _, q in
            search.find(q, forward: true)
        }
    }

    private func close() {
        findActive = false
        fieldFocused = false
        query = ""
        search.notFound = false
    }
}

private struct ReadingFindBar: View {
    @Binding var query: String
    var notFound: Bool
    var focused: FocusState<Bool>.Binding
    let onSubmit: () -> Void
    let onPrev: () -> Void
    let onNext: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 12))
            TextField("Find in preview", text: $query)
                .textFieldStyle(.plain)
                .focused(focused)
                .onSubmit(onSubmit)
                .onExitCommand(perform: onClose)
                .foregroundColor(notFound && !query.isEmpty ? .red : .primary)
            if notFound && !query.isEmpty {
                Text("Not found")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Button(action: onPrev) { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(query.isEmpty)
                .help("Previous match")
            Button(action: onNext) { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(query.isEmpty)
                .help("Next match")
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Close")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(
            Rectangle()
                .fill(Color(NSColor.separatorColor))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }
}
