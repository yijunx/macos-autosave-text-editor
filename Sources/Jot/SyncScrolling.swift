import SwiftUI
import AppKit

// MARK: - Editor

struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    @Binding var scrollFraction: CGFloat

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

        // Defer scroll apply so SwiftUI completes any pending layout first.
        let target = scrollFraction
        DispatchQueue.main.async {
            context.coordinator.applyScrollFraction(target)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var textBinding: Binding<String>
        var fractionBinding: Binding<CGFloat>
        weak var scrollView: NSScrollView?
        weak var textView: NSTextView?
        var ignoreScrollEvents = 0

        init(text: Binding<String>, scrollFraction: Binding<CGFloat>) {
            self.textBinding = text
            self.fractionBinding = scrollFraction
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

    func makeCoordinator() -> Coordinator { Coordinator(scrollFraction: $scrollFraction) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = hosting

        NSLayoutConstraint.activate([
            hosting.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            hosting.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor)
        ])

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.boundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        context.coordinator.scrollView = scrollView
        context.coordinator.hosting = hosting
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.fractionBinding = $scrollFraction
        context.coordinator.hosting?.rootView = content

        let target = scrollFraction
        DispatchQueue.main.async {
            context.coordinator.applyScrollFraction(target)
        }
    }

    final class Coordinator: NSObject {
        var fractionBinding: Binding<CGFloat>
        weak var scrollView: NSScrollView?
        weak var hosting: NSHostingView<Content>?
        var ignoreScrollEvents = 0

        init(scrollFraction: Binding<CGFloat>) {
            self.fractionBinding = scrollFraction
        }

        @objc func boundsDidChange(_ notification: Notification) {
            guard ignoreScrollEvents == 0,
                  let scrollView = scrollView,
                  let hosting = hosting else { return }
            let fraction = SyncScrollMath.fraction(
                visibleOrigin: scrollView.contentView.bounds.origin.y,
                visibleHeight: scrollView.contentView.bounds.height,
                documentHeight: hosting.frame.height
            )
            if abs(fraction - fractionBinding.wrappedValue) > 0.001 {
                fractionBinding.wrappedValue = fraction
            }
        }

        func applyScrollFraction(_ fraction: CGFloat) {
            guard let scrollView = scrollView, let hosting = hosting else { return }
            let visible = scrollView.contentView.bounds
            let scrollable = max(hosting.frame.height - visible.height, 1)
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
