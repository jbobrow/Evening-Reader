import SwiftUI
import WebKit

/// Serves an article's stored pictures to the reader.
///
/// The saved HTML points at `amber-asset://` rather than at the web, so a page opened
/// with no network still has its pictures. WebKit hands those requests here and they are
/// answered from disk.
final class AssetSchemeHandler: NSObject, WKURLSchemeHandler {
    private let store: ArticleStore
    init(store: ArticleStore = .shared) { self.store = store }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url,
              let file = store.assetFile(for: url),
              let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let response = URLResponse(url: url, mimeType: Self.mime(for: file.pathExtension),
                                   expectedContentLength: data.count, textEncodingName: nil)
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private static func mime(for ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        default: return "application/octet-stream"
        }
    }
}

/// A handle on the reader's web view, so the view that owns the edit callout can run
/// the actions without reaching into the representable's coordinator.
@MainActor
final class ReaderBridge: WKWebViewLike {
    weak var web: WKWebView?
    func runJavaScript(_ source: String) { web?.evaluateJavaScript(source) }
}

/// Hosts the rendered reader document. Style changes are pushed as CSS variables so the
/// page never reloads and never loses the reader's place.
struct ReaderWebView: UIViewRepresentable {
    let article: SavedArticle
    let body: String
    let palette: AmberPalette
    let settings: DisplaySettings
    var onProgress: (Double) -> Void
    var onOpenLink: (URL) -> Void
    var onTap: () -> Void
    var onSelection: (WebSelection?) -> Void
    var onPages: (Int, Int, Double) -> Void
    let bridge: ReaderBridge

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.userContentController.add(context.coordinator, name: "reader")
        config.allowsInlineMediaPlayback = true
        config.setURLSchemeHandler(AssetSchemeHandler(), forURLScheme: OfflineAssets.scheme)

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.allowsLinkPreview = false
        web.scrollView.decelerationRate = .normal
        web.scrollView.showsVerticalScrollIndicator = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        context.coordinator.web = web
        bridge.web = web
        context.coordinator.loadIfNeeded(self)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.loadIfNeeded(self)
        context.coordinator.applyStyle(self)
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "reader")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
        /// Decline WebKit's link preview and context menu; both are system chrome.
        func webView(_ webView: WKWebView,
                     contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                     completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
            completionHandler(nil)
        }

        var parent: ReaderWebView
        weak var web: WKWebView?
        private var loadedKey: String?
        private var lastStyle: String?
        private var didRestore = false

        init(_ parent: ReaderWebView) { self.parent = parent }

        func loadIfNeeded(_ parent: ReaderWebView) {
            let key = parent.article.id.uuidString + "|" + String(parent.body.count)
            guard key != loadedKey, let web else { return }
            loadedKey = key
            didRestore = false
            let html = ReaderRenderer.document(article: parent.article, body: parent.body,
                                               palette: parent.palette, settings: parent.settings)
            lastStyle = ReaderRenderer.applyStyleScript(palette: parent.palette, settings: parent.settings)
            web.loadHTMLString(html, baseURL: parent.article.url)
        }

        func applyStyle(_ parent: ReaderWebView) {
            let script = ReaderRenderer.applyStyleScript(palette: parent.palette, settings: parent.settings)
            guard script != lastStyle, let web else { return }
            lastStyle = script
            web.evaluateJavaScript(script)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            restoreScroll()
            // The content view only exists once something has loaded.
            WebKeyboardBridge.installOverrides(on: webView)
        }

        private func restoreScroll() {
            guard !didRestore, let web else { return }
            didRestore = true
            let fraction = parent.article.lastScroll
            guard fraction > 0.001 else { return }
            web.evaluateJavaScript("window.__ag && window.__ag.restore(\(fraction));")
        }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any],
                  let name = dict["name"] as? String else { return }
            switch name {
            case "progress":
                if let v = dict["value"] as? Double { parent.onProgress(v) }
            case "ready":
                restoreScroll()
            case "pages":
                parent.onPages(dict["page"] as? Int ?? 1,
                               dict["total"] as? Int ?? 1,
                               dict["percent"] as? Double ?? 0)
            case "tap":
                parent.onTap()
            case "selection":
                if let web { WebKeyboardBridge.removeEditMenu(from: web) }
                let text = dict["text"] as? String ?? ""
                guard !text.isEmpty else { parent.onSelection(nil); return }
                parent.onSelection(WebSelection(
                    text: text,
                    rect: CGRect(x: dict["x"] as? Double ?? 0, y: dict["y"] as? Double ?? 0,
                                 width: dict["w"] as? Double ?? 0, height: dict["h"] as? Double ?? 0),
                    isEditable: dict["editable"] as? Bool ?? false))
            default:
                break
            }
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                decisionHandler(.cancel)
                parent.onOpenLink(url)
                return
            }
            decisionHandler(.allow)
        }
    }
}
