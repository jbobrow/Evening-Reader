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
    /// The id of the `.ag-chapter` section currently at the top of the screen, for a
    /// book. Ignored otherwise.
    var onChapter: (String) -> Void = { _ in }
    /// What is marked on this page, drawn into the document and redrawn whenever the set
    /// changes. Anchored by offset; see `HighlightMarker`.
    var highlights: [Highlight] = []
    /// A passage to bring into view — the jump from the highlights list. Cleared through
    /// `onRevealed` once it has been done, so it happens once rather than on every layout.
    var revealHighlight: UUID?
    var onRevealed: () -> Void = {}
    /// A passage the reader has just marked, anchored and ready to be saved.
    var onHighlight: (Highlight) -> Void = { _ in }
    /// A tap on a mark already on the page.
    var onMarkTap: (UUID) -> Void = { _ in }
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
        context.coordinator.applyHighlights(self)
        context.coordinator.revealIfAsked(self)
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
        /// What the document was last told to mark, so a redraw is only paid for when
        /// the set has actually changed — `updateUIView` runs on every glow tweak.
        private var lastMarks: String?
        /// True once the document exists to be marked. Highlights and a reveal asked for
        /// before that are held and run from the `ready` message instead.
        private var didLoad = false
        private var pendingReveal: UUID?

        init(_ parent: ReaderWebView) { self.parent = parent }

        func loadIfNeeded(_ parent: ReaderWebView) {
            // Bytes rather than characters: `count` on a String walks every grapheme,
            // which for a novel is real work, and this runs on every update.
            let key = parent.article.id.uuidString + "|" + String(parent.body.utf8.count)
            guard key != loadedKey, let web else { return }
            loadedKey = key
            didRestore = false
            didLoad = false
            lastMarks = nil
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

        /// Draws the marks. The script is only run when the set has changed — or when the
        /// document has just been rebuilt, which `lastMarks` being torn up in
        /// `loadIfNeeded` is what says.
        func applyHighlights(_ parent: ReaderWebView, force: Bool = false) {
            let payload = parent.highlights.compactMap { mark -> [String: Any]? in
                guard let offset = mark.offset else { return nil }
                return ["id": mark.id.uuidString, "text": mark.text,
                        "offset": offset, "note": mark.hasNote]
            }
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            guard didLoad, let web else { return }
            guard force || json != lastMarks else { return }
            lastMarks = json
            web.evaluateJavaScript("window.__agHL && window.__agHL.apply(\(json));")
        }

        func revealIfAsked(_ parent: ReaderWebView) {
            guard let target = parent.revealHighlight else { return }
            pendingReveal = target
            runReveal()
        }

        /// A mark can only be scrolled to once it has been drawn, so the two are done in
        /// order and both are held until the document is there for them.
        private func runReveal() {
            guard didLoad, let target = pendingReveal, let web else { return }
            pendingReveal = nil
            applyHighlights(parent, force: true)
            web.evaluateJavaScript(
                "window.__agHL && window.__agHL.reveal(\"\(target.uuidString)\");")
            // Off this turn of the loop: this runs inside `updateUIView`, and clearing
            // the request is a change to the state that drove it.
            let done = parent.onRevealed
            DispatchQueue.main.async(execute: done)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            restoreScroll()
            // The content view only exists once something has loaded.
            WebKeyboardBridge.installOverrides(on: webView)
        }

        /// WebKit's content process was jettisoned — which the system does to a
        /// backgrounded app when memory runs short, and a reader is an app that spends
        /// its life backgrounded.
        ///
        /// The view survives; everything it was showing does not. And because the reader
        /// document paints no background of its own, what is left is not a white page but
        /// a blank one: the article's chrome, its scrubber, and nothing at all between
        /// them. It looks like the app opened to a page that was never there.
        ///
        /// Nothing recovers on its own. WebKit can re-fetch a page it holds a URL for,
        /// but the reader is handed an HTML string and has nowhere to go back to. Neither
        /// will `loadIfNeeded`, whose whole job is to *not* reload for anything short of
        /// a new article — which is what keeps a change of type or glow from throwing
        /// away the reader's place. So the record of what was loaded is torn up first,
        /// and the document goes back in behind it, landing where the reader left off:
        /// `lastScroll` was being kept the whole time.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            loadedKey = nil
            loadIfNeeded(parent)
        }

        private func restoreScroll() {
            guard !didRestore, let web else { return }
            didRestore = true
            let fraction = parent.article.lastScroll
            guard fraction > 0.001 else { return }
            web.evaluateJavaScript("window.__ag && window.__ag.restore(\(fraction));")
        }

        /// A second, corrective pass once every image has either finished loading or
        /// failed — which `window.load` guarantees and the `ready` message, fired as
        /// early as `DOMContentLoaded`, does not. Invisible in an article, where the
        /// document's height barely moves after first paint; in a long book, restoring a
        /// fraction against a height that still has images to lay out can land a chapter
        /// or more off. `load` only ever fires once per document, so this cannot repeat
        /// or compound into a visible jump under the reader's thumb.
        private func settleScroll() {
            guard let web else { return }
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
                didLoad = true
                restoreScroll()
                applyHighlights(parent, force: true)
                runReveal()
            case "settled":
                settleScroll()
            case "pages":
                parent.onPages(dict["page"] as? Int ?? 1,
                               dict["total"] as? Int ?? 1,
                               dict["percent"] as? Double ?? 0)
            case "chapter":
                if let anchor = dict["value"] as? String { parent.onChapter(anchor) }
            case "tap":
                parent.onTap()
            case "highlight":
                guard let text = dict["text"] as? String, !text.isEmpty else { return }
                let chapter = (dict["chapter"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                parent.onHighlight(Highlight(text: text,
                                             offset: dict["offset"] as? Int,
                                             progress: dict["progress"] as? Double ?? 0,
                                             chapterTitle: chapter))
            case "markTap":
                if let raw = dict["value"] as? String, let id = UUID(uuidString: raw) {
                    parent.onMarkTap(id)
                }
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
