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
    /// Whether what is loaded reads as an article — something with a body of prose the
    /// reader could pull out and keep — as against a feed, a player, a shelf, a form.
    /// A PDF always is. Save and Read are offered only when this is true.
    var isSaveable: Bool = false
    /// Whether the bar has been put away. Reading down a page puts it away; coming
    /// back up, a tap on the page, or a new page brings it back.
    var chromeHidden: Bool = false
    /// Whether the page belongs to one of the reader's own sites — a door kept on the
    /// front page. Such a site carries its own navigation, so the bar keeps out of the
    /// way: put away as each page arrives, and a tap shows only a strip.
    var isAppSite: Bool = false
    /// A site's page that is not an article. The moment one turns out to be — a pinned
    /// paper's story, say — the full bar is back, so Save and Read are reachable.
    var appMode: Bool { isAppSite && !isSaveable }

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var appliedTint: String?
    /// The frames inside the current page, as each one announced itself. A change of
    /// polarity has to reach them one by one: script run against the view goes to the
    /// top document only.
    @ObservationIgnored private var frames: [WKFrameInfo] = []
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
    /// A page that changes its address without loading — a feed, a reader app — is
    /// asked again a moment after it has moved, since nothing else will ask.
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    @ObservationIgnored private var lastOffset: CGFloat = 0

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
        // The desktop page on an iPad, the phone page on a phone — what Safari does.
        // The desktop page on a phone was laid out for far more width than there is:
        // content ran off the left edge and video sat letterboxed in a column meant
        // for a wider layout.
        web.customUserAgent = ArticleExtractor.browsingUserAgent
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
                    self.trackScroll()
                }
            },
            web.observe(\.url, options: [.initial, .new]) { [weak self] w, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.currentURL = w.url
                    self.scheduleProbe()
                }
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
        load(Self.url(from: trimmed) ?? Self.searchURL(for: trimmed))
    }

    /// A web search for some words.
    static func searchURL(for text: String) -> URL {
        var components = URLComponents(string: "https://duckduckgo.com/")!
        components.queryItems = [URLQueryItem(name: "q", value: text)]
        return components.url ?? URL(string: "https://duckduckgo.com/")!
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

    /// A new page: the old page's frames are gone with it.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        frames.removeAll()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageIndicator.hide(in: webView)
        reportPDFPosition()
        probeSaveable()
    }

    /// Is there an article here? Counted rather than judged: a couple of hundred words
    /// of paragraph text inside the page's main region is prose worth keeping, and a
    /// player, a feed or a login form never has that many.
    private static let saveableProbe = """
    (function () {
      var root = document.querySelector('article')
        || document.querySelector('main, [role="main"]')
        || document.body;
      if (!root) { return false; }
      var words = 0, ps = root.querySelectorAll('p');
      for (var i = 0; i < ps.length; i++) {
        var t = ps[i].innerText || '';
        words += t.split(/\\s+/).filter(function (w) { return w.length > 0; }).length;
        if (words >= 200) { return true; }
      }
      return false;
    })()
    """

    /// The bar follows the reading: a page going up under the finger puts it away, a
    /// page coming back down brings it out, and the top of a page always has it.
    private func trackScroll() {
        let y = web.scrollView.contentOffset.y
        let delta = y - lastOffset
        lastOffset = y
        if y <= 8 {
            if chromeHidden, !appMode { chromeHidden = false }
        } else if delta > 8, y > 80, !chromeHidden {
            chromeHidden = true
        } else if delta < -8, chromeHidden, !appMode {
            chromeHidden = false
        }
    }

    private func probeSaveable() {
        if showingPDF {
            isSaveable = true
            return
        }
        web.evaluateJavaScript(Self.saveableProbe) { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let saveable = (result as? Bool) ?? false
                // An article on a site kept as an app gets its bar back, so the
                // buttons for keeping it are there to be seen.
                if saveable, !self.isSaveable, self.isAppSite { self.chromeHidden = false }
                self.isSaveable = saveable
            }
        }
    }

    private func scheduleProbe() {
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            self?.probeSaveable()
        }
    }

    /// What is arriving, so a PDF can be told from a page. Nothing is refused here; the
    /// answer only decides who reports the reading position afterwards.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame {
            showingPDF = navigationResponse.response.mimeType == "application/pdf"
            // A new document, not yet read: nothing to save until it has been looked at.
            isSaveable = showingPDF
            chromeHidden = isAppSite
            lastOffset = 0
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
        if name == "chrome" {
            // On a site kept as an app, scrolling only ever puts the strip away; it
            // is the tap that brings it out.
            let show = dict["show"] as? Bool ?? true
            if show, appMode { return }
            if chromeHidden == show { chromeHidden = !show }
            return
        }
        if name == "field" {
            WebKeyboardBridge.shared.focusedField(isLogin: dict["login"] as? Bool ?? false)
            return
        }
        if name == "frame" {
            if !message.frameInfo.isMainFrame { frames.append(message.frameInfo) }
            return
        }
        if name == "tap" {
            // A plain tap on the page turns the bar over, as it does in the reader. The
            // page's own controls are left out by the script that reports it, so what
            // arrives here is a tap on nothing in particular — which on a page that
            // moves its content without scrolling is the only way to put the bar away.
            chromeHidden.toggle()
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

    /// Lets the page go when the browser is closed.
    ///
    /// The user content controller holds its message handler strongly, and this model
    /// is that handler while it holds the web view that holds the controller — a ring
    /// nothing ever let go of. Every browser closed left its page alive behind the
    /// screen, still running: a YouTube page kept its player, and WebKit lets one
    /// media session play at a time in a process, so the next YouTube page opened
    /// could not — "playback error", on every video after the first. The ring is
    /// broken here, and the page is sent to nothing first so whatever it was playing
    /// stops now rather than when the view is finally freed.
    func retire() {
        probeTask?.cancel()
        observations = []
        web.stopLoading()
        web.navigationDelegate = nil
        web.uiDelegate = nil
        let controller = web.configuration.userContentController
        controller.removeAllUserScripts()
        controller.removeScriptMessageHandler(forName: "browse")
        web.loadHTMLString("", baseURL: nil)
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
        for frame in frames {
            web.evaluateJavaScript(script, in: frame, in: .page) { _ in }
        }
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
