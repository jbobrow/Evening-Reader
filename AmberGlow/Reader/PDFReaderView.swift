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
    let pager: PDFPager

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // The document is on disk; nothing here should reach the network.
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.showsVerticalScrollIndicator = false
        web.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
        pager.scrollView = web.scrollView
        context.coordinator.watch(web.scrollView)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject {
        var parent: PDFWebView
        private var offsetToken: NSKeyValueObservation?
        private var sizeToken: NSKeyValueObservation?
        private var restored = false

        init(_ parent: PDFWebView) { self.parent = parent }

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
