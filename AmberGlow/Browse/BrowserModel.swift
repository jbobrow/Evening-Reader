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
    /// A PDF can be browsed to as well as opened from the library, and WebKit puts its
    /// own page indicator over it either way.
    @ObservationIgnored private let pageIndicator = SystemPageIndicator()
    /// Whether what is loaded is a PDF rather than a page. Taken from the response's MIME
    /// type, which is the only thing that actually knows: a URL's extension is a hint, and
    /// plenty of PDFs are served without one.
    @ObservationIgnored private var showingPDF = false
    /// Drives a browsed PDF's scrolling. A page carries `DocumentPager` as a script and
    /// reports itself; a PDF has no document of ours to put a script in, so the same job
    /// is done from the scroll view — see `PDFPager`.
    @ObservationIgnored private let pdfPager = PDFPager()

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
        // Opaque, and backed with white.
        //
        // The page is filtered on its way to the ramp — luminance, then squeezed into the
        // ink..page span, then multiplied onto the emitter — and white is what comes out
        // the far end as the page colour exactly. So the backdrop is white for the same
        // reason the page is: it goes through the identical mapping and lands in the
        // identical place, at any warmth, glow or polarity.
        //
        // Left clear, the places the content does not reach — above a page pulled past
        // its top, around a PDF zoomed smaller than the glass — showed `GlowSurface`
        // through the gap. That is the lamp a second time, since this view already paints
        // one over itself, and two lamps is a lighter amber than one. The seam was
        // exactly where the content stopped.
        web.isOpaque = true
        web.backgroundColor = .white
        web.scrollView.backgroundColor = .white
        // The system indicator is grey — the one bit of furniture left that the ramp
        // does not reach. The reading position is shown in the chrome instead.
        web.scrollView.showsVerticalScrollIndicator = false
        super.init()
        web.uiDelegate = self
        web.navigationDelegate = self
        config.userContentController.add(self, name: "browse")

        observations = [
            // Watched for the indicator's sake: WebKit raises it as the document is
            // scrolled, so it has to be put down again as the document is scrolled.
            web.scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pageIndicator.hide(in: self.web)
                    self.reportPDFPosition()
                }
            },
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

    /// The content process was jettisoned while the app was away. A browsed page has a
    /// real URL behind it, so unlike the reader it can simply be fetched again — but it
    /// has to be asked, since WebKit leaves the view standing and empty.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageIndicator.hide(in: webView)
        reportPDFPosition()
    }

    /// What is arriving, so a PDF can be told from a page. Nothing is refused here; the
    /// answer only decides who reports the reading position afterwards.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame {
            showingPDF = navigationResponse.response.mimeType == "application/pdf"
            // The new document has not said where it is yet, and the last one's numbers
            // are not its own. The scrubber goes away until something reports again.
            pdfPager.stop()
            page = 1
            pageCount = 1
            percent = 0
        }
        decisionHandler(.allow)
    }

    /// Where a browsed PDF is, in screenfuls.
    ///
    /// The reader can say "5 of 9" because the file was counted by PDFKit when it was
    /// saved. A PDF being browsed has not been counted and WebKit will not say, so it is
    /// measured the same way every other browsed page is — which is also the only unit
    /// the two have in common.
    private func reportPDFPosition() {
        guard showingPDF else { return }
        let scroll = web.scrollView
        let viewport = scroll.bounds.height
        let length = scroll.contentSize.height
        guard viewport > 0, length > 0 else { return }
        let limit = max(0, length - viewport)
        percent = limit > 0 ? min(1, max(0, scroll.contentOffset.y / limit)) : 0
        pageCount = max(1, Int((length / viewport).rounded(.up)))
        page = min(pageCount, max(1, Int(scroll.contentOffset.y / viewport) + 1))
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
        if showingPDF {
            pdfPager.scrollView = web.scrollView
            pdfPager.autoScroll(velocity)
            return
        }
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
    /// applied natively over the whole web view, so this only needs to know the grid and
    /// whether pictures need to pre-invert to opt out of night's polarity flip.
    func applyTint(showGrid: Bool, isNight: Bool) {
        let script = WebTint.script(showGrid: showGrid, isNight: isNight)
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
