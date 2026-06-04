import SwiftUI
import AppKit

// MARK: - Editor

struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    @Binding var scrollFraction: CGFloat
    var hideTags: Bool = false

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, scrollFraction: $scrollFraction)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesFindBar = true
        textView.delegate = context.coordinator

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        textView.string = text
        scrollView.documentView = textView

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.boundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        context.coordinator.scrollView = scrollView
        context.coordinator.textView = textView
        context.coordinator.startFindPolling()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        context.coordinator.textBinding = $text
        context.coordinator.fractionBinding = $scrollFraction

        if textView.string != text {
            let sel = textView.selectedRange()
            textView.string = text
            let maxLoc = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(sel.location, maxLoc), length: 0))
        }

        context.coordinator.hideTags = hideTags
        CodeEditorView.applyDecorations(
            textView,
            hideTags: hideTags,
            searchQuery: context.coordinator.currentSearchQuery()
        )

        // Defer scroll apply so SwiftUI completes any pending layout first.
        let target = scrollFraction
        DispatchQueue.main.async {
            context.coordinator.applyScrollFraction(target)
        }
    }

    /// Matches whole `<style>…</style>` and `<script>…</script>` blocks (case-insensitive),
    /// HTML comments, and finally any other `<…>` tag. Earlier alternatives win at each
    /// position, so style/script contents get swallowed before the generic tag rule fires.
    private static let hideRegex: NSRegularExpression = {
        let pattern = #"<style[^>]*>[\s\S]*?</style>|<script[^>]*>[\s\S]*?</script>|<!--[\s\S]*?-->|<[^>]+>"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static let hiddenFont: NSFont = .monospacedSystemFont(ofSize: 0.01, weight: .regular)

    /// Recomputes all *temporary* (display-only) attributes on the editor: tag-hiding
    /// when in contents-only mode, then yellow search match highlights on top. The
    /// text storage is never modified, so the storage keeps its adaptive `textColor`.
    static func applyDecorations(_ textView: NSTextView, hideTags: Bool, searchQuery: String) {
        guard let lm = textView.layoutManager,
              let storage = textView.textStorage else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
        lm.removeTemporaryAttribute(.font, forCharacterRange: fullRange)
        guard storage.length > 0 else { return }
        let string = storage.string

        if hideTags {
            hideRegex.enumerateMatches(in: string, range: fullRange) { match, _, _ in
                guard let r = match?.range else { return }
                lm.addTemporaryAttribute(.foregroundColor, value: NSColor.clear, forCharacterRange: r)
                lm.addTemporaryAttribute(.font, value: hiddenFont, forCharacterRange: r)
            }
        }

        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty,
           let regex = try? NSRegularExpression(
               pattern: NSRegularExpression.escapedPattern(for: q),
               options: [.caseInsensitive]) {
            regex.enumerateMatches(in: string, range: fullRange) { match, _, _ in
                guard let r = match?.range else { return }
                lm.addTemporaryAttribute(.foregroundColor, value: NSColor.systemYellow, forCharacterRange: r)
                lm.removeTemporaryAttribute(.font, forCharacterRange: r)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var textBinding: Binding<String>
        var fractionBinding: Binding<CGFloat>
        weak var scrollView: NSScrollView?
        weak var textView: NSTextView?
        var ignoreScrollEvents = 0
        var hideTags: Bool = false

        private var findPollTimer: Timer?
        private var lastFindChangeCount: Int = Int.min
        private var lastSearchQuery: String = ""
        private var lastFindBarVisible: Bool = false

        init(text: Binding<String>, scrollFraction: Binding<CGFloat>) {
            self.textBinding = text
            self.fractionBinding = scrollFraction
        }

        deinit {
            findPollTimer?.invalidate()
        }

        func startFindPolling() {
            findPollTimer?.invalidate()
            findPollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.pollFindState()
            }
        }

        func currentSearchQuery() -> String {
            lastSearchQuery
        }

        private func pollFindState() {
            guard let scrollView = scrollView, let textView = textView else { return }
            let pb = NSPasteboard(name: .find)
            let visible = scrollView.isFindBarVisible
            let changeCount = pb.changeCount
            let query: String
            if visible {
                query = pb.string(forType: .string) ?? ""
            } else {
                query = ""
            }
            if visible == lastFindBarVisible && changeCount == lastFindChangeCount && query == lastSearchQuery {
                return
            }
            lastFindBarVisible = visible
            lastFindChangeCount = changeCount
            lastSearchQuery = query
            CodeEditorView.applyDecorations(textView, hideTags: hideTags, searchQuery: query)
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let newText = tv.string
            if textBinding.wrappedValue != newText {
                textBinding.wrappedValue = newText
            }
        }

        @objc func boundsDidChange(_ notification: Notification) {
            guard ignoreScrollEvents == 0,
                  let scrollView = scrollView,
                  let textView = textView else { return }
            let fraction = SyncScrollMath.fraction(
                visibleOrigin: scrollView.contentView.bounds.origin.y,
                visibleHeight: scrollView.contentView.bounds.height,
                documentHeight: textView.frame.height
            )
            if abs(fraction - fractionBinding.wrappedValue) > 0.001 {
                fractionBinding.wrappedValue = fraction
            }
        }

        func applyScrollFraction(_ fraction: CGFloat) {
            guard let scrollView = scrollView, let textView = textView else { return }
            let visible = scrollView.contentView.bounds
            let scrollable = max(textView.frame.height - visible.height, 1)
            let targetY = fraction * scrollable
            if abs(visible.origin.y - targetY) < 0.5 { return }
            ignoreScrollEvents += 1
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            DispatchQueue.main.async {
                self.ignoreScrollEvents = max(0, self.ignoreScrollEvents - 1)
            }
        }
    }
}

// MARK: - Hosted scroll container (preview)

struct ScrollableHosting<Content: View>: NSViewRepresentable {
    @Binding var scrollFraction: CGFloat
    let content: Content

    init(scrollFraction: Binding<CGFloat>, @ViewBuilder content: () -> Content) {
        _scrollFraction = scrollFraction
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(scrollFraction: $scrollFraction, rootView: content)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let docView = context.coordinator.controller.view
        docView.translatesAutoresizingMaskIntoConstraints = true
        docView.autoresizingMask = []
        scrollView.documentView = docView

        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.boundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.viewportDidResize(_:)),
            name: NSView.frameDidChangeNotification,
            object: scrollView.contentView
        )

        context.coordinator.scrollView = scrollView
        DispatchQueue.main.async {
            context.coordinator.resizeContent()
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.fractionBinding = $scrollFraction
        context.coordinator.controller.rootView = content

        let target = scrollFraction
        DispatchQueue.main.async {
            context.coordinator.resizeContent()
            context.coordinator.applyScrollFraction(target)
        }
    }

    final class Coordinator: NSObject {
        var fractionBinding: Binding<CGFloat>
        let controller: NSHostingController<Content>
        weak var scrollView: NSScrollView?
        var ignoreScrollEvents = 0
        private var lastDocHeight: CGFloat = 0

        init(scrollFraction: Binding<CGFloat>, rootView: Content) {
            self.fractionBinding = scrollFraction
            self.controller = NSHostingController(rootView: rootView)
            super.init()
        }

        @objc func viewportDidResize(_ notification: Notification) {
            DispatchQueue.main.async {
                self.resizeContent()
                self.applyScrollFraction(self.fractionBinding.wrappedValue)
            }
        }

        func resizeContent() {
            guard let scrollView = scrollView else { return }
            let viewportSize = scrollView.contentView.bounds.size
            guard viewportSize.width > 0 else { return }

            let measured = controller.sizeThatFits(in: NSSize(width: viewportSize.width, height: 0))
            let docHeight = max(measured.height, 1)
            let targetFrame = NSRect(x: 0, y: 0, width: viewportSize.width, height: docHeight)

            if controller.view.frame != targetFrame {
                ignoreScrollEvents += 1
                controller.view.frame = targetFrame
                lastDocHeight = docHeight
                DispatchQueue.main.async {
                    self.ignoreScrollEvents = max(0, self.ignoreScrollEvents - 1)
                }
            }
        }

        @objc func boundsDidChange(_ notification: Notification) {
            guard ignoreScrollEvents == 0,
                  let scrollView = scrollView else { return }
            let fraction = SyncScrollMath.fraction(
                visibleOrigin: scrollView.contentView.bounds.origin.y,
                visibleHeight: scrollView.contentView.bounds.height,
                documentHeight: controller.view.frame.height
            )
            if abs(fraction - fractionBinding.wrappedValue) > 0.001 {
                fractionBinding.wrappedValue = fraction
            }
        }

        func applyScrollFraction(_ fraction: CGFloat) {
            guard let scrollView = scrollView else { return }
            let visible = scrollView.contentView.bounds
            let scrollable = max(controller.view.frame.height - visible.height, 1)
            let targetY = fraction * scrollable
            if abs(visible.origin.y - targetY) < 0.5 { return }
            ignoreScrollEvents += 1
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            DispatchQueue.main.async {
                self.ignoreScrollEvents = max(0, self.ignoreScrollEvents - 1)
            }
        }
    }
}

enum SyncScrollMath {
    static func fraction(visibleOrigin: CGFloat, visibleHeight: CGFloat, documentHeight: CGFloat) -> CGFloat {
        let scrollable = max(documentHeight - visibleHeight, 1)
        return max(0, min(1, visibleOrigin / scrollable))
    }
}
