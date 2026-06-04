import SwiftUI
import WebKit

struct WebPreviewView: NSViewRepresentable {
    @ObservedObject var doc: EditorDocument

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "scroll")
        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")

        webView.loadHTMLString(WebPreviewView.htmlTemplate, baseURL: nil)

        context.coordinator.webView = webView
        context.coordinator.doc = doc
        context.coordinator.lastDocID = doc.id
        context.coordinator.pendingPayload = WebPreviewView.payload(from: doc)
        context.coordinator.pendingResetScroll = true
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coord = context.coordinator
        let payload = WebPreviewView.payload(from: doc)

        let docChanged = coord.lastDocID != doc.id
        if docChanged {
            coord.lastDocID = doc.id
            coord.lastContent = nil
            coord.lastFraction = nil
        }
        coord.doc = doc

        let contentChanged = coord.lastContent != payload.content
        let fraction = doc.scrollFraction
        let fractionChanged = coord.lastFraction.map { abs($0 - fraction) > 0.001 } ?? true

        coord.lastContent = payload.content
        coord.lastFraction = fraction

        guard coord.isReady else {
            coord.pendingPayload = payload
            coord.pendingResetScroll = docChanged || coord.pendingResetScroll
            return
        }

        if contentChanged || docChanged {
            coord.pushContent(payload, resetScroll: docChanged)
        }
        if fractionChanged && !docChanged {
            coord.applyScroll(fraction)
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "scroll")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        weak var doc: EditorDocument?
        var isReady = false
        var pendingPayload: Payload?
        var pendingResetScroll = true
        var lastDocID: UUID?
        var lastContent: String?
        var lastFraction: CGFloat?
        var ignoreIncomingScroll = 0

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isReady = true
            if let payload = pendingPayload {
                pushContent(payload, resetScroll: pendingResetScroll)
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
            let cg = CGFloat(value)
            guard let doc = doc else { return }
            if abs(doc.scrollFraction - cg) > 0.002 {
                doc.scrollFraction = cg
                lastFraction = cg
            }
        }

        func pushContent(_ payload: Payload, resetScroll: Bool) {
            guard let webView = webView else { return }
            let json = WebPreviewView.encodeJSONString(payload.content)
            let fn = payload.mode == .html ? "setHtml" : "setMarkdown"
            var js = "\(fn)(\(json));"
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
            ignoreIncomingScroll += 1
            webView.evaluateJavaScript("applyScroll(\(fraction));", completionHandler: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                self?.ignoreIncomingScroll = max(0, (self?.ignoreIncomingScroll ?? 1) - 1)
            }
        }
    }

    enum RenderMode { case markdown, html }
    struct Payload {
        let mode: RenderMode
        let content: String
    }

    static func payload(from doc: EditorDocument) -> Payload {
        let ext = doc.fileURL?.pathExtension.lowercased() ?? ""
        if ext == "html" || ext == "htm" {
            return Payload(mode: .html, content: doc.content)
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
