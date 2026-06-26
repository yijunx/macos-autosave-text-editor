import SwiftUI
import WebKit

struct WebPreviewView: NSViewRepresentable {
    @ObservedObject var doc: EditorDocument
    var search: PreviewSearchController? = nil
    var zoomScale: CGFloat = 1.0

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "scroll")
        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.pageZoom = zoomScale
        webView.setValue(false, forKey: "drawsBackground")

        context.coordinator.webView = webView
        context.coordinator.doc = doc
        context.coordinator.lastDocID = doc.id
        search?.webView = webView
        context.coordinator.refresh(
            payload: WebPreviewView.payload(from: doc),
            resetScroll: true
        )
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coord = context.coordinator
        coord.doc = doc
        search?.webView = webView
        if abs(webView.pageZoom - zoomScale) > 0.001 {
            webView.pageZoom = zoomScale
        }

        let payload = WebPreviewView.payload(from: doc)
        let docChanged = coord.lastDocID != doc.id
        if docChanged {
            coord.lastDocID = doc.id
            coord.lastContent = nil
            coord.lastFraction = nil
        }

        coord.refresh(payload: payload, resetScroll: docChanged)

        // Scroll sync only matters for Markdown (HTML preview scrolls independently).
        if payload.mode == .markdown {
            let fraction = doc.scrollFraction
            let fractionChanged = coord.lastFraction.map { abs($0 - fraction) > 0.001 } ?? true
            coord.lastFraction = fraction
            if fractionChanged && !docChanged && coord.isReady && coord.loadedKind == .template {
                coord.applyScroll(fraction)
            }
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "scroll")
    }

    enum LoadedKind { case none, template, html }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        weak var doc: EditorDocument?
        var isReady = false
        var pendingPayload: Payload?
        var pendingResetScroll = true
        var loadedKind: LoadedKind = .none
        var lastDocID: UUID?
        var lastContent: String?
        var lastFraction: CGFloat?
        var ignoreIncomingScroll = 0
        var htmlReloadTask: DispatchWorkItem?

        deinit {
            htmlReloadTask?.cancel()
        }

        /// Single entry point — decides whether to (re)load the preview template,
        /// load the user's HTML directly from disk with proper read access for
        /// sibling resources, or just push new content into the already-loaded page.
        func refresh(payload: Payload, resetScroll: Bool) {
            let neededKind: LoadedKind = payload.mode == .html ? .html : .template
            let kindChanged = loadedKind != neededKind
            let contentChanged = lastContent != payload.content

            if !kindChanged && !contentChanged && !resetScroll && loadedKind != .none {
                return
            }

            lastContent = payload.content

            if payload.mode == .html {
                scheduleHTMLLoad(immediate: kindChanged || loadedKind == .none)
                return
            }

            // Template-backed modes: Markdown, JSON, and JSONL.
            htmlReloadTask?.cancel()
            if kindChanged || loadedKind == .none {
                guard let webView = webView else { return }
                webView.loadHTMLString(WebPreviewView.htmlTemplate, baseURL: nil)
                loadedKind = .template
                isReady = false
                pendingPayload = payload
                pendingResetScroll = resetScroll
            } else if isReady {
                pushPayload(payload, resetScroll: resetScroll)
            } else {
                pendingPayload = payload
                pendingResetScroll = resetScroll || pendingResetScroll
            }
        }

        /// HTML mode uses `loadFileURL(_:allowingReadAccessTo:)` so WebKit grants
        /// read access to the file's directory tree — that's what lets relative
        /// `<img src="assets/…">` and `<link href="assets/…">` resolve. Loading from
        /// disk means we must wait long enough for autosave to flush in-memory edits;
        /// hence the 500ms debounce (autosave debounces to 400ms).
        private func scheduleHTMLLoad(immediate: Bool) {
            htmlReloadTask?.cancel()
            let task = DispatchWorkItem { [weak self] in
                guard let self = self,
                      let webView = self.webView,
                      let fileURL = self.doc?.fileURL else { return }
                let parent = fileURL.deletingLastPathComponent()
                webView.loadFileURL(fileURL, allowingReadAccessTo: parent)
                self.loadedKind = .html
                self.isReady = false
                self.pendingPayload = nil
            }
            htmlReloadTask = task
            if immediate {
                DispatchQueue.main.async(execute: task)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: task)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isReady = true
            if loadedKind == .template, let payload = pendingPayload {
                pushPayload(payload, resetScroll: pendingResetScroll)
                if !pendingResetScroll, let f = doc?.scrollFraction {
                    applyScroll(f)
                }
                pendingPayload = nil
            }
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "scroll",
                  let value = message.body as? Double else { return }
            if ignoreIncomingScroll > 0 { return }
            if !shouldSyncScroll { return }
            let cg = CGFloat(value)
            guard let doc = doc else { return }
            if abs(doc.scrollFraction - cg) > 0.002 {
                doc.scrollFraction = cg
                lastFraction = cg
            }
        }

        private var shouldSyncScroll: Bool {
            let ext = doc?.fileURL?.pathExtension.lowercased() ?? ""
            return ext.isEmpty || ext == "md" || ext == "markdown"
        }

        func pushPayload(_ payload: Payload, resetScroll: Bool) {
            guard let webView = webView else { return }
            let json = WebPreviewView.encodeJSONString(payload.content)
            let renderCall: String
            switch payload.mode {
            case .markdown:
                renderCall = "setMarkdown(\(json));"
            case .json:
                renderCall = "setJSON(\(json));"
            case .jsonLines:
                renderCall = "setJSONLines(\(json));"
            case .html:
                renderCall = "setHtml(\(json));"
            }
            var js = renderCall
            if resetScroll {
                js += "window.scrollTo(0, 0);"
            }
            ignoreIncomingScroll += 1
            webView.evaluateJavaScript(js, completionHandler: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.ignoreIncomingScroll = max(0, (self?.ignoreIncomingScroll ?? 1) - 1)
            }
        }

        func applyScroll(_ fraction: CGFloat) {
            guard let webView = webView else { return }
            if !shouldSyncScroll { return }
            ignoreIncomingScroll += 1
            webView.evaluateJavaScript("applyScroll(\(fraction));", completionHandler: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                self?.ignoreIncomingScroll = max(0, (self?.ignoreIncomingScroll ?? 1) - 1)
            }
        }
    }

    enum RenderMode { case markdown, html, json, jsonLines }
    struct Payload {
        let mode: RenderMode
        let content: String
    }

    static func payload(from doc: EditorDocument) -> Payload {
        let ext = doc.fileURL?.pathExtension.lowercased() ?? ""
        if ext == "html" || ext == "htm" {
            return Payload(mode: .html, content: doc.content)
        }
        if ext == "json" {
            return Payload(mode: .json, content: doc.content)
        }
        if ext == "jsonl" {
            return Payload(mode: .jsonLines, content: doc.content)
        }
        return Payload(mode: .markdown, content: doc.content)
    }

    static func encodeJSONString(_ s: String) -> String {
        if let data = try? JSONEncoder().encode(s),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "\"\""
    }

    static let htmlTemplate: String = {
        let markedJS = loadMarkedJS()
        return """
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
:root {
    --fg: #1c1c1e;
    --fg-secondary: #6c6c70;
    --bg: #ffffff;
    --border: #d6d6d8;
    --code-bg: #f4f4f5;
    --quote-border: #007aff;
    --link: #007aff;
    --json-key: #8a4f00;
    --json-string: #137333;
    --json-number: #9d174d;
    --json-literal: #5b5fc7;
}
@media (prefers-color-scheme: dark) {
    :root {
        --fg: #ebebec;
        --fg-secondary: #9c9c9e;
        --bg: #1e1e1e;
        --border: #3a3a3c;
        --code-bg: #2a2a2c;
        --quote-border: #0a84ff;
        --link: #0a84ff;
        --json-key: #f4bf75;
        --json-string: #7ee787;
        --json-number: #ff9ac1;
        --json-literal: #a5b4fc;
    }
}
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; background: var(--bg); color: var(--fg); }
body {
    font: 14px/1.6 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
    padding: 20px 24px 60px;
    -webkit-text-size-adjust: 100%;
    word-wrap: break-word;
}
h1, h2, h3, h4, h5, h6 { font-weight: 600; line-height: 1.25; margin: 22px 0 10px; }
h1 { font-size: 26px; font-weight: 700; }
h2 { font-size: 21px; font-weight: 700; }
h3 { font-size: 17px; }
h4 { font-size: 15px; }
h5 { font-size: 13px; }
h6 { font-size: 12px; color: var(--fg-secondary); }
p { margin: 0 0 12px; }
a { color: var(--link); text-decoration: none; }
a:hover { text-decoration: underline; }
ul, ol { margin: 0 0 12px; padding-left: 28px; }
li { margin: 4px 0; }
li > ul, li > ol { margin: 4px 0; }
li.task-list-item { list-style: none; margin-left: -22px; }
li.task-list-item input { margin-right: 6px; vertical-align: middle; }
blockquote {
    margin: 12px 0;
    padding: 4px 0 4px 14px;
    border-left: 3px solid var(--quote-border);
    color: var(--fg-secondary);
}
hr { border: none; border-top: 1px solid var(--border); margin: 18px 0; }
code {
    font: 13px/1.5 ui-monospace, "SF Mono", Menlo, Consolas, monospace;
    background: var(--code-bg);
    padding: 1px 5px;
    border-radius: 4px;
}
pre {
    background: var(--code-bg);
    padding: 12px 14px;
    border-radius: 6px;
    overflow-x: auto;
    margin: 12px 0;
}
pre code { padding: 0; background: transparent; border-radius: 0; }
pre.json-preview {
    margin: 0;
    padding: 0;
    background: transparent;
    border-radius: 0;
    white-space: pre-wrap;
    overflow-wrap: anywhere;
}
pre.json-preview code {
    font: 13px/1.55 ui-monospace, "SF Mono", Menlo, Consolas, monospace;
}
.json-key { color: var(--json-key); }
.json-string { color: var(--json-string); }
.json-number { color: var(--json-number); }
.json-literal { color: var(--json-literal); }
table { border-collapse: collapse; margin: 12px 0; }
th, td { border: 1px solid var(--border); padding: 6px 10px; text-align: left; }
th { background: var(--code-bg); font-weight: 600; }
img { max-width: 100%; height: auto; }
::selection { background: rgba(0,122,255,0.22); }
</style>
</head>
<body>
<div id="content"></div>
<script>
\(markedJS)
</script>
<script>
marked.setOptions({ breaks: true, gfm: true });
window.setMarkdown = function(text) {
    document.getElementById('content').innerHTML = marked.parse(text || '');
};
window.setHtml = function(html) {
    document.getElementById('content').innerHTML = html || '';
};
function escapeHTML(value) {
    return String(value).replace(/[&<>"']/g, function(ch) {
        return {
            '&': '&amp;',
            '<': '&lt;',
            '>': '&gt;',
            '"': '&quot;',
            "'": '&#39;'
        }[ch];
    });
}
function jsonSyntaxHighlight(text) {
    var tokenPattern = /("(?:\\\\u[a-fA-F0-9]{4}|\\\\[^u]|[^\\\\"])*"(\\s*:)?|\\btrue\\b|\\bfalse\\b|\\bnull\\b|-?\\d+(?:\\.\\d+)?(?:[eE][+\\-]?\\d+)?)/g;
    return String(text).replace(tokenPattern, function(token) {
        var cls = 'json-number';
        if (/^"/.test(token)) {
            cls = /:\\s*$/.test(token) ? 'json-key' : 'json-string';
        } else if (/true|false|null/.test(token)) {
            cls = 'json-literal';
        }
        return '<span class="' + cls + '">' + escapeHTML(token) + '</span>';
    });
}
function renderJSONParts(parts) {
    var html = parts.map(function(part) {
        return part.json ? jsonSyntaxHighlight(part.text) : escapeHTML(part.text);
    }).join('\\n');
    document.getElementById('content').innerHTML = '<pre class="json-preview"><code>' + html + '</code></pre>';
}
window.setJSON = function(text) {
    var source = text || '';
    try {
        renderJSONParts([{ json: true, text: JSON.stringify(JSON.parse(source), null, 2) }]);
    } catch (err) {
        renderJSONParts([{ json: false, text: source }]);
    }
};
window.setJSONLines = function(text) {
    var source = text || '';
    var lines = source.split(/\\r?\\n/);
    if (/\\r?\\n$/.test(source) && lines.length && lines[lines.length - 1] === '') {
        lines.pop();
    }
    var parts = lines.map(function(line) {
        var trimmed = line.trim();
        if (!trimmed) return { json: false, text: '' };
        try {
            return { json: true, text: JSON.stringify(JSON.parse(trimmed), null, 2) };
        } catch (err) {
            return { json: false, text: line };
        }
    });
    renderJSONParts(parts);
};
window.applyScroll = function(fraction) {
    var h = document.documentElement.scrollHeight - window.innerHeight;
    if (h <= 0) return;
    var y = fraction * h;
    if (Math.abs(window.scrollY - y) < 1) return;
    window.scrollTo(0, y);
};
window.addEventListener('scroll', function() {
    var h = document.documentElement.scrollHeight - window.innerHeight;
    var f = h > 0 ? Math.max(0, Math.min(1, window.scrollY / h)) : 0;
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.scroll) {
        window.webkit.messageHandlers.scroll.postMessage(f);
    }
}, { passive: true });
</script>
</body>
</html>
"""
    }()
}

private func loadMarkedJS() -> String {
    guard let url = Bundle.module.url(forResource: "marked.min", withExtension: "js"),
          let data = try? Data(contentsOf: url),
          let str = String(data: data, encoding: .utf8) else {
        return "console.error('marked.js missing from app bundle');"
    }
    return str
}
