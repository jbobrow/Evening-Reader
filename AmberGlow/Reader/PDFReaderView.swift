import SwiftUI
import WebKit

/// Drives a PDF's scrolling, and says where in it we are.
///
/// An article reports its own position: the reader document carries `DocumentPager`, and
/// a script can measure it and scroll it. A PDF has no document of ours to put a script
/// in — WebKit renders it natively and there is no DOM to reach. The same numbers come
/// off the web view's scroll view instead, which is a plain `UIScrollView` and public.
@MainActor
final class PDFPager: NSObject {
    weak var scrollView: UIScrollView?

    private var link: CADisplayLink?
    private var velocity: Double = 0
    private var lastFrame: CFTimeInterval = 0

    /// Points per second, signed. Zero stops. Ticked from a display link for the same
    /// reason the article's loop is ticked from `requestAnimationFrame` — the movement
    /// should land on the frames it is being drawn into.
    func autoScroll(_ points: Double) {
        velocity = points
        guard points != 0 else { stop(); return }
        guard link == nil else { return }
        lastFrame = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        velocity = 0
    }

    @objc private func step() {
        guard let scroll = scrollView else { stop(); return }
        let now = CACurrentMediaTime()
        let elapsed = min(0.05, now - lastFrame)
        lastFrame = now
        let limit = max(0, scroll.contentSize.height - scroll.bounds.height)
        scroll.contentOffset.y = min(limit, max(0, scroll.contentOffset.y + velocity * elapsed))
    }
}

/// Shows a saved PDF, lit like everything else.
///
/// A PDF has no document of ours to restyle, so it cannot be re-typeset the way an
/// article is. What it can be is filtered: WebKit renders the pages, and the same
/// grayscale-then-amber mapping the browser uses is applied to the rendered view, so a
/// white page becomes the panel's page and the type becomes ink. At night the mapping is
/// inverted, exactly as it is for a web page written for a light ground.
struct PDFReaderView: View {
    @Environment(DisplaySettings.self) private var settings
    @Environment(\.amber) private var amber

    let fileURL: URL
    /// Pages, counted when the file was saved. Absent on anything saved before that.
    var pageCount: Int?
    /// Where the reader left off, as a fraction.
    var initialProgress: Double = 0
    var onProgress: (Double) -> Void = { _ in }
    /// page, total, fraction read, and the document's length in points.
    var onPages: (Int, Int, Double, CGFloat) -> Void = { _, _, _, _ in }
    /// A bare tap on the page, which puts the chrome away as it does in an article.
    var onTap: () -> Void = {}
    let pager: PDFPager

    /// Where a white page lands, matching the app's own surfaces.
    private let pageLevel = 0.88
    private let inkFloor = 0.045

    private var isNight: Bool { settings.polarity == .night }
    private var tintSign: Double { isNight ? -1 : 1 }
    private var tintColor: Color { isNight ? amber.color(0.0) : amber.color(pageLevel) }
    private var tintFloor: Double {
        guard isNight else { return inkFloor }
        let ink = amber.rgb(0.0).0
        let page = amber.rgb(pageLevel).0
        return ink > 0 ? min(1, page / ink) : inkFloor
    }

    var body: some View {
        PDFWebView(fileURL: fileURL,
                   pageCount: pageCount,
                   initialProgress: initialProgress,
                   onProgress: onProgress,
                   onPages: onPages,
                   onTap: onTap,
                   pager: pager)
            .grayscale(1)
            .contrast(tintSign * (1 - tintFloor))
            .brightness(tintFloor / 2)
            .colorMultiply(tintColor)
            .overlay { BacklightBloom(level: isNight ? 0.0 : pageLevel) }
    }
}

private struct PDFWebView: UIViewRepresentable {
    let fileURL: URL
    var pageCount: Int?
    var initialProgress: Double
    var onProgress: (Double) -> Void
    var onPages: (Int, Int, Double, CGFloat) -> Void
    var onTap: () -> Void
    let pager: PDFPager

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // The document is on disk; nothing here should reach the network.
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        // Opaque, and backed with white — see `BrowserModel`, which is filtered the
        // same way and had the same seam.
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
        web.scrollView.showsVerticalScrollIndicator = false
        // No rubber band. WebKit draws the grey desk the pages sit on inside its own
        // process, so the app can neither read that colour nor set it — which means the
        // ground past the end of the document can never be made to match it, and pulling
        // beyond the document showed the join. A PDF has a first page and a last one;
        // stopping at them is honest, and there is then no past-the-end to give away.
        web.scrollView.bounces = false
        web.navigationDelegate = context.coordinator
        web.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
        pager.scrollView = web.scrollView
        context.coordinator.watch(web.scrollView)
        context.coordinator.listenForTaps(on: web)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, WKNavigationDelegate, UIGestureRecognizerDelegate {
        var parent: PDFWebView
        private var offsetToken: NSKeyValueObservation?
        private var sizeToken: NSKeyValueObservation?
        private var restored = false
        /// WebKit's own page indicator, once found. Held so it can be kept down without
        /// walking the view tree again.
        private let indicator = SystemPageIndicator()

        init(_ parent: PDFWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            indicator.hide(in: webView)
        }

        /// The content process was jettisoned while the app was away — see the same
        /// method on the article reader for what that is and why it happens. WebKit will
        /// often bring a file URL back by itself, but asking is what makes it certain.
        ///
        /// The reader's place does not come back with it: the document reopens at the
        /// top. The position is overwritten during the teardown, before the reload can
        /// use it, by a report this has not managed to trace. Worth fixing, but it costs
        /// a page rather than the page.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            let url = parent.fileURL
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }

        /// A bare tap puts the chrome away, the same as it does over an article.
        ///
        /// An article is asked in its own document: a script watches for a tap that is
        /// not a scroll, a link or a selection, and says so. A PDF has no document of
        /// ours to ask, so the tap is caught with a recogniser instead — added alongside
        /// WebKit's own rather than in front of them, so scrolling, selecting and
        /// following a link all still reach the page.
        func listenForTaps(on web: WKWebView) {
            let tap = UITapGestureRecognizer(target: self, action: #selector(pageTapped))
            tap.cancelsTouchesInView = false
            tap.delaysTouchesEnded = false
            tap.delegate = self
            // A double tap is a zoom, and its first tap is not a request for the chrome.
            for other in Self.taps(in: web) where other.numberOfTapsRequired == 2 {
                tap.require(toFail: other)
            }
            web.scrollView.addGestureRecognizer(tap)
        }

        private static func taps(in view: UIView) -> [UITapGestureRecognizer] {
            var found = (view.gestureRecognizers ?? []).compactMap { $0 as? UITapGestureRecognizer }
            for sub in view.subviews { found += taps(in: sub) }
            return found
        }

        @objc private func pageTapped() { parent.onTap() }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        /// WebKit owns the scroll view's delegate, so the position is watched rather than
        /// received. The content size is watched too: it is zero until the document has
        /// been laid out, which is also the moment the saved place can be restored.
        func watch(_ scroll: UIScrollView) {
            offsetToken = scroll.observe(\.contentOffset, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.report(view) }
            }
            sizeToken = scroll.observe(\.contentSize, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    self?.restoreIfNeeded(view)
                    self?.report(view)
                }
            }
        }

        @MainActor
        private func report(_ scroll: UIScrollView) {
            if let web = scroll.superview as? WKWebView { indicator.hide(in: web) }
            let viewport = scroll.bounds.height
            let length = scroll.contentSize.height
            guard viewport > 0, length > 0 else { return }

            let limit = max(0, length - viewport)
            let percent = limit > 0 ? min(1, max(0, scroll.contentOffset.y / limit)) : 0

            // Real pages where we know how many there are. A PDF's pages are the ones
            // printed on it, and "7 of 30" ought to mean that rather than a count of
            // screenfuls. Screenfuls remain the fallback, for files saved before the
            // count was stored — the same unit an article uses, since an article has no
            // pages of its own to report.
            let total = parent.pageCount ?? max(1, Int((length / viewport).rounded(.up)))
            let step = length / CGFloat(total)
            let page = min(total, max(1, Int(scroll.contentOffset.y / step) + 1))

            parent.onPages(page, total, percent, length)
            parent.onProgress(percent)
        }

        @MainActor
        private func restoreIfNeeded(_ scroll: UIScrollView) {
            guard !restored, parent.initialProgress > 0.001 else { return }
            let limit = max(0, scroll.contentSize.height - scroll.bounds.height)
            guard limit > 0 else { return }
            restored = true
            scroll.contentOffset.y = limit * parent.initialProgress
        }
    }
}


/// Puts down WebKit's own page indicator over a PDF — the blurred grey capsule that rises
/// in the corner while the document is scrolled and fades out after it.
///
/// It is the last piece of system material anywhere in the app, and it says what the
/// app's own pill already says, a few points away from it and in another language
/// entirely. There is no API to decline it, so it is found by class name and hidden,
/// which is the same trade the keyboard bridge makes: if WebKit renames or restructures
/// the view, nothing is found and nothing is touched. The indicator comes back, which is
/// untidy, and that is the whole of the damage.
///
/// A PDF can be arrived at two ways — opened from the library, or browsed to — and both
/// hold one of these, because the indicator belongs to WebKit rather than to either
/// reader.
@MainActor
final class SystemPageIndicator {
    private weak var view: UIView?
    /// When the hunt last ran, so a document that never has one is not searched on every
    /// frame of every scroll.
    private var lastSearch: CFTimeInterval = 0

    /// `isHidden` rather than removal — WebKit animates the thing's alpha to show and
    /// hide it, and a hidden view stays hidden through that. Called again on every scroll
    /// rather than once, since the view can be rebuilt underneath us.
    func hide(in web: WKWebView) {
        if let view {
            view.isHidden = true
            return
        }
        // WebKit builds the indicator lazily, so the first look usually finds nothing and
        // the search has to stay open. A budget of tries cannot do that: scroll events
        // spend it in a fraction of a second, long before there is anything to find, and
        // the indicator is then never taken down at all. Time bounds it instead — a walk
        // of a dozen views, four times a second at worst.
        let now = CACurrentMediaTime()
        guard now - lastSearch > 0.25 else { return }
        lastSearch = now
        guard let found = Self.find(in: web) else { return }
        view = found
        found.isHidden = true
    }

    private static func find(in view: UIView) -> UIView? {
        if isIndicator(view) { return view }
        for sub in view.subviews {
            if let found = find(in: sub) { return found }
        }
        return nil
    }

    /// The indicator has had more than one name, and matching one spelling of it is how
    /// this came to be hidden on the simulator and showing on the phone.
    ///
    /// Through iOS 18 it is PDFKit's `PDFPageLabelView`. On iOS 26 that class is still
    /// there, but WebKit puts up its own `WKPDFPageNumberIndicator` instead, so the old
    /// name matches nothing and the indicator stays. Both were read out of the two
    /// runtimes rather than guessed at.
    ///
    /// Matching the shape of the name rather than either spelling covers the two that
    /// exist and stands some chance against the next rename. It is still a name, and
    /// still fails the same safe way: nothing found, nothing touched.
    private static func isIndicator(_ view: UIView) -> Bool {
        let name = String(describing: type(of: view))
        guard name.contains("PDF") else { return false }
        return name.contains("PageLabel")
            || name.contains("PageNumber")
            || name.contains("PageIndicator")
    }
}
