import SwiftUI
import WebKit

struct RichMessageView: View {
    let text: String
    @State private var contentHeight: CGFloat = 24

    var body: some View {
        MathMarkdownWebView(text: text, contentHeight: $contentHeight)
            .frame(maxWidth: .infinity, minHeight: 1, idealHeight: contentHeight, maxHeight: contentHeight)
            .accessibilityLabel(text)
    }
}

private struct MathMarkdownWebView: UIViewRepresentable {
    let text: String
    @Binding var contentHeight: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "contentHeight")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.scrollView.contentInset = .zero
        view.allowsLinkPreview = true
        context.coordinator.pendingText = text
        view.loadHTMLString(Self.template, baseURL: Bundle.main.resourceURL)
        return view
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.pendingText != text else { return }
        context.coordinator.pendingText = text
        context.coordinator.render(in: webView)
    }

    static let template = #"""
    <!doctype html>
    <html><head>
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
    <style>
      :root { color-scheme: light dark; }
      * { box-sizing: border-box; }
      html, body { margin: 0; padding: 0; background: transparent; }
      body { color: #151515; font: -apple-system-body; font-size: 16px; line-height: 1.55; overflow-wrap: anywhere; }
      #content > :first-child { margin-top: 0; }
      #content > :last-child { margin-bottom: 0; }
      p { margin: .35em 0 .75em; }
      h1, h2, h3, h4 { line-height: 1.25; margin: .95em 0 .4em; }
      h1 { font-size: 1.35em; } h2 { font-size: 1.22em; } h3 { font-size: 1.12em; }
      ul, ol { padding-left: 1.35em; margin: .45em 0 .8em; }
      li { margin: .22em 0; }
      blockquote { margin: .7em 0; padding: .15em .8em; border-left: 3px solid #8e8e93; color: #5e5e63; }
      code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .9em; background: rgba(127,127,127,.14); padding: .12em .3em; border-radius: 5px; }
      pre { overflow-x: auto; background: rgba(127,127,127,.12); padding: .8em; border-radius: 10px; white-space: pre; }
      pre code { background: transparent; padding: 0; }
      table { border-collapse: collapse; display: block; max-width: 100%; overflow-x: auto; margin: .7em 0; }
      th, td { border: 1px solid rgba(127,127,127,.38); padding: .4em .55em; text-align: left; }
      th { background: rgba(127,127,127,.12); font-weight: 600; }
      a { color: #0a84ff; text-decoration: none; }
      hr { border: 0; border-top: 1px solid rgba(127,127,127,.32); }
      mjx-container[jax="SVG"][display="true"] { overflow-x: auto; overflow-y: hidden; padding: .35em 0; max-width: 100%; }
      mjx-container svg { max-width: none; }
      @media (prefers-color-scheme: dark) { body { color: #f2f2f7; } blockquote { color: #aeaeb2; } }
    </style>
    <script>
      window.MathJax = {
        tex: { inlineMath: [['$', '$'], ['\\(', '\\)']], displayMath: [['$$', '$$'], ['\\[', '\\]']], processEscapes: true },
        svg: { fontCache: 'local' },
        options: { skipHtmlTags: ['script','noscript','style','textarea','pre','code'] },
        startup: { typeset: false }
      };
    </script>
    <script src="mathjax-tex-svg.js"></script>
    <script src="marked.min.js"></script>
    </head><body><main id="content"></main>
    <script>
      const root = document.getElementById('content');
      function decodeBase64(value) {
        const bytes = Uint8Array.from(atob(value), c => c.charCodeAt(0));
        return new TextDecoder('utf-8').decode(bytes);
      }
      function escapeHTML(value) {
        return value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
      }
      function secureLinks() {
        root.querySelectorAll('a').forEach(link => {
          try {
            const url = new URL(link.getAttribute('href'), 'https://local.invalid/');
            if (!['http:', 'https:', 'mailto:'].includes(url.protocol)) link.removeAttribute('href');
            else { link.target = '_blank'; link.rel = 'noopener noreferrer'; }
          } catch { link.removeAttribute('href'); }
        });
      }
      function reportHeight() {
        requestAnimationFrame(() => window.webkit.messageHandlers.contentHeight.postMessage(Math.ceil(document.documentElement.scrollHeight)));
      }
      async function renderMarkdown(encoded) {
        const source = escapeHTML(decodeBase64(encoded));
        if (window.MathJax?.typesetClear) MathJax.typesetClear([root]);
        root.innerHTML = marked.parse(source, { gfm: true, breaks: true });
        secureLinks();
        if (window.MathJax?.typesetPromise) await MathJax.typesetPromise([root]);
        reportHeight();
      }
      new ResizeObserver(reportHeight).observe(root);
    </script></body></html>
    """#

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: MathMarkdownWebView
        var pendingText: String
        private var loaded = false
        private var lastRendered: String?

        init(parent: MathMarkdownWebView) { self.parent = parent; pendingText = parent.text }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            render(in: webView)
        }

        func render(in webView: WKWebView) {
            guard loaded, lastRendered != pendingText else { return }
            lastRendered = pendingText
            let encoded = Data(pendingText.utf8).base64EncodedString()
            webView.evaluateJavaScript("renderMarkdown('\(encoded)')")
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "contentHeight", let value = message.body as? NSNumber else { return }
            let height = max(1, CGFloat(truncating: value))
            if abs(parent.contentHeight - height) > 0.5 { parent.contentHeight = height }
        }
    }
}
