import SwiftUI
import AppKit

struct MarkdownPreviewView: View {
    @ObservedObject var doc: EditorDocument

    var body: some View {
        WebPreviewView(doc: doc)
            .background(Color(NSColor.textBackgroundColor))
    }
}
