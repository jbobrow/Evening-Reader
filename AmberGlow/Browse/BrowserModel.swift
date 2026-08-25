import Foundation
import SwiftUI
import WebKit
import Observation

/// Owns a live `WKWebView` and mirrors the bits of its state the chrome needs.
@MainActor
@Observable
final class BrowserModel: NSObject, WKScriptMessageHandler, WKUIDelegate,
                          WKNavigationDelegate, WKWebViewLike {
    let web: WKWebView

    /// What the page currently has selected, if anything.
    var selection: WebSelection?
    /// The page measured in screenfuls.
    var page = 1
    var pageCount = 1
    var percent: Double = 0

    var currentURL: URL?
    var pageTitle: String = ""
    var progress: Double = 0
    var isLoading: Bool = false
    var canGoBack: Bool = false
    var canGoForward: Bool = false

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var appliedTint: String?

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // Fullscreen is presented in a window of its own that the panel's filter cannot
        // reach, so it is refused — here for the element API, and again in the page for
        // the video element's own route (see WebTint). Video plays inline instead.
        config.preferences.isElementFullscreenEnabled = false
        web = WKWebView(frame: .zero, configuration: config)
        web.allowsBackForwardNavigationGestures = true
        web.allowsLinkPreview = false
        web.customUserAgent = ArticleExtractor.desktopUserAgent
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        // The system indicator is grey — the one bit of furniture left that the ramp
        // does not reach. The reading position is shown in the chrome instead.
        web.scrollView.showsVerticalScrollIndicator = false
        super.init()
        web.uiDelegate = self
        web.navigationDelegate = self
        config.userContentController.add(self, name: "browse")

        observations = [
            web.observe(\.url, options: [.initial, .new]) { [weak self] w, _ in
                MainActor.assumeIsolated { self?.currentURL = w.url }
            },
            web.observe(\.title, options: [.initial, .new]) { [weak self] w, _ in
                MainActor.assumeIsolated { self?.pageTitle = w.title ?? "" }
            },
            web.observe(\.estimatedProgress, options: [.new]) { [weak self] w, _ in
                MainActor.assumeIsolated { self?.progress = w.estimatedProgress }
            },
            web.observe(\.isLoading, options: [.initial, .new]) { [weak self] w, _ in
                MainActor.assumeIsolated { self?.isLoading = w.isLoading }
            },
            web.observe(\.canGoBack, options: [.initial, .new]) { [weak self] w, _ in
                MainActor.assumeIsolated { self?.canGoBack = w.canGoBack }
            },
            web.observe(\.canGoForward, options: [.initial, .new]) { [weak self] w, _ in
                MainActor.assumeIsolated { self?.canGoForward = w.canGoForward }
            }
        ]
    }

    func load(_ url: URL) {
        web.load(URLRequest(url: url))
    }

    /// Turn whatever the user typed into something loadable: a URL if it parses as one,
    /// otherwise a search.
    func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let url = Self.url(from: trimmed) {
            load(url)
        } else {
            var components = URLComponents(string: "https://duckduckgo.com/")!
            components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
            if let url = components.url { load(url) }
        }
    }

    static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https", url.host != nil {
            return url
        }
        // A bare host like "example.com/page" — assume https.
        let head = trimmed.split(separator: "/").first.map(String.init) ?? trimmed
        guard head.contains("."), !head.hasSuffix("."),
              let url = URL(string: "https://" + trimmed), url.host != nil else { return nil }
        return url
    }

    /// Long-pressing a link would otherwise raise WebKit's preview sheet and context
    /// menu — its own window, system materials, no appearance API. Returning nil is the
    /// documented way to decline it.
    func webView(_ webView: WKWebView,
                 contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
        completionHandler(nil)
    }

    /// Re-issues link taps as ordinary loads.
    ///
    /// A universal link followed from a web view hands off to whichever app claims the
    /// domain — tap a YouTube link and iOS leaves for the YouTube app. A load the app
    /// starts itself never hands off, so cancelling and re-loading the same URL keeps
    /// the reader here. Only http(s) is re-issued; mail and tel links still belong to
    /// the system.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        webView.load(URLRequest(url: url))
    }

    func runJavaScript(_ source: String) {
        web.evaluateJavaScript(source)
    }

    func autoScroll(_ velocity: Double) {
        web.evaluateJavaScript("window.__agPager && window.__agPager.autoScroll(\(velocity));")
    }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any],
              let name = dict["name"] as? String else { return }
        if name == "pages" {
            page = dict["page"] as? Int ?? 1
            pageCount = dict["total"] as? Int ?? 1
            percent = dict["percent"] as? Double ?? 0
            return
        }
        guard name == "selection" else { return }
        WebKeyboardBridge.removeEditMenu(from: web)
        let text = dict["text"] as? String ?? ""
        guard !text.isEmpty else { selection = nil; return }
        selection = WebSelection(
            text: text,
            rect: CGRect(x: dict["x"] as? Double ?? 0, y: dict["y"] as? Double ?? 0,
                         width: dict["w"] as? Double ?? 0, height: dict["h"] as? Double ?? 0),
            isEditable: dict["editable"] as? Bool ?? false
        )
    }

    /// (Re)install the page-side preparation. The grayscale + amber mapping itself is
    /// applied natively over the whole web view, so only the grid depends on settings.
    func applyTint(showGrid: Bool) {
        let script = WebTint.script(showGrid: showGrid)
        guard script != appliedTint else { return }
        appliedTint = script

        let controller = web.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
                                             forMainFrameOnly: false))
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd,
                                             forMainFrameOnly: false))
        web.evaluateJavaScript(script)
    }
}

/// Thin bridge so SwiftUI can host the model's web view.
struct BrowserWebViewHost: UIViewRepresentable {
    let model: BrowserModel
    let palette: AmberPalette
    let showsTexture: Bool

    func makeUIView(context: Context) -> WKWebView { model.web }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // WebKit's content view only exists once there is something to show, so the
        // attach is retried here rather than done once at construction. It is a no-op
        // after it takes, and a no-op forever if the view can't be found.
        WebKeyboardBridge.shared.attach(to: uiView, palette: palette, showsTexture: showsTexture)
    }
}
