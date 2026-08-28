import SwiftUI
import PDFKit

/// A handle on the open PDF: drives its scrolling, and lets go of a selection.
///
/// An article is driven by a script in its own document. A PDF has no document of ours to
/// put a script in, so the same jobs are done through the view — which, now that PDFKit
/// renders it rather than WebKit, is a view that will answer.
@MainActor
final class PDFPager: NSObject {
    weak var view: PDFView? {
        didSet { goToPendingPage() }
    }
    weak var scrollView: UIScrollView?

    /// A page asked for before there was a view to ask. Held rather than dropped: opening
    /// a PDF from the highlights list asks for the page in the same breath as opening the
    /// document, and which of the two lands first is not ours to decide.
    private var pendingPage: Int?
    /// True once a particular page has been asked for, so the coordinator's restore of
    /// the last-read position stands down — the reader said where they wanted to be.
    private(set) var wentToPage = false

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

    func clearSelection() {
        view?.clearSelection()
    }

    /// Anchors what is selected right now, so the app can keep it.
    ///
    /// A PDF has no text of ours to count through, so a passage is pinned the way PDFKit
    /// itself pins one: to a page, and to the line boxes it covers on that page. Only the
    /// first page's lines are taken. A selection dragged across a page break would need a
    /// second anchor to draw the rest, and a page is the unit a PDF's own annotations are
    /// stored in — the passage's text is kept whole either way.
    func captureSelection() -> Highlight? {
        guard let view, let document = view.document,
              let selection = view.currentSelection,
              let text = selection.string, !text.trimmingCharacters(in: .whitespaces).isEmpty,
              let page = selection.pages.first else { return nil }
        let index = document.index(for: page)
        var boxes = selection.selectionsByLine().compactMap { line -> Highlight.Box? in
            guard let linePage = line.pages.first, document.index(for: linePage) == index else {
                return nil
            }
            return Highlight.Box(line.bounds(for: linePage))
        }
        if boxes.isEmpty { boxes = [Highlight.Box(selection.bounds(for: page))] }
        let pages = max(1, document.pageCount - 1)
        return Highlight(text: text,
                         pageIndex: index,
                         boxes: boxes,
                         progress: Double(index) / Double(pages))
    }

    /// Turn to the page a marked passage is on — the jump from the highlights list.
    func reveal(pageIndex: Int) {
        pendingPage = pageIndex
        wentToPage = true
        goToPendingPage()
    }

    private func goToPendingPage() {
        guard let pageIndex = pendingPage,
              let view, let document = view.document,
              pageIndex >= 0, pageIndex < document.pageCount,
              let page = document.page(at: pageIndex) else { return }
        pendingPage = nil
        view.go(to: page)
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
/// A PDF has no document of ours to restyle, so it cannot be re-typeset the way an article
/// is. What it can be is filtered: the pages are rendered and the same grayscale-then-amber
/// mapping the browser uses is applied to the rendered view, so a white page becomes the
/// panel's page and the type becomes ink. At night the mapping is inverted, exactly as it
/// is for a web page written for a light ground.
///
/// Rendered by PDFKit rather than by a web view, which is a change of engine and not only
/// of class. A `WKWebView` will show a PDF but will not say anything about it: it draws its
/// own page indicator that has to be found by class name and hidden, it draws the grey desk
/// the pages sit on inside its own process where the colour can be neither read nor
/// matched, it loses the document whenever the content process is jettisoned, and it will
/// not say a word about what the reader has selected — which is what finally settled it,
/// since the app draws its own edit menu everywhere else and could not here. `PDFView`
/// answers all four: no indicator, a background colour that is ours to set, no separate
/// process to lose, and `currentSelection` for the text and where it sits.
struct PDFReaderView: View {
    @Environment(DisplaySettings.self) private var settings

    let fileURL: URL
    /// Where the reader left off, as a fraction.
    var initialProgress: Double = 0
    var onProgress: (Double) -> Void = { _ in }
    /// page, total, fraction read, and the document's length in points.
    var onPages: (Int, Int, Double, CGFloat) -> Void = { _, _, _, _ in }
    /// A bare tap on the page, which puts the chrome away as it does in an article.
    var onTap: () -> Void = {}
    /// What the reader has selected, in the view's own coordinates, or nil for nothing.
    var onSelection: (WebSelection?) -> Void = { _ in }
    /// What is marked in this document, painted onto the pages as annotations.
    var highlights: [Highlight] = []
    let pager: PDFPager

    /// Where a white page lands, matching the app's own surfaces.
    private let pageLevel = 0.88

    private var isNight: Bool { settings.polarity == .night }

    var body: some View {
        PDFDocumentView(fileURL: fileURL,
                        initialProgress: initialProgress,
                        onProgress: onProgress,
                        onPages: onPages,
                        onTap: onTap,
                        onSelection: onSelection,
                        highlights: highlights,
                        pager: pager)
            .amberInk(pageLevel: pageLevel, isNight: isNight)
            .overlay { BacklightBloom(level: isNight ? 0.0 : pageLevel) }
            // The lattice, painted back on over the top.
            //
            // Everywhere else in the app it comes through from `GlowSurface`, which is
            // the only surface there is — the article reader's document is transparent
            // and the grid shows through it. A PDF is opaque and covers that surface
            // completely, so the page arrives smooth while every other page in the app is
            // textured. Same reason the bloom above is painted back on, and in the same
            // order the surface itself stacks them: bloom under, lattice over.
            .overlay {
                if settings.showTexture { PixelGrid() }
            }
    }
}

private struct PDFDocumentView: UIViewRepresentable {
    let fileURL: URL
    var initialProgress: Double
    var onProgress: (Double) -> Void
    var onPages: (Int, Int, Double, CGFloat) -> Void
    var onTap: () -> Void
    var onSelection: (WebSelection?) -> Void
    var highlights: [Highlight]
    let pager: PDFPager

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PDFView {
        let view = AmberPDFView()
        let document = PDFDocument(url: fileURL)
        // Set before the view asks for a page, or the pages it already made are the
        // plain kind and none of them will draw an edge.
        document?.delegate = context.coordinator
        view.document = document
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        // Enough of a gap that a page turn reads as one. The gap is background, and the
        // background is the page colour, so this buys the rhythm of pages without
        // bringing back a desk to put them on.
        view.pageBreakMargins = UIEdgeInsets(top: 14, left: 0, bottom: 14, right: 0)
        // White, for the same reason every other filtered surface in the app is white:
        // the page is mapped luminance-first onto the ramp, and white is what comes out
        // of that as the page colour exactly. The desk the pages sit on is therefore the
        // page colour too, and so is the ground past the end of the document — one
        // surface, with no seam anywhere for the eye to catch on. This is the thing a
        // web view would not give up: it drew that desk in another process.
        view.backgroundColor = .white
        // No shadow: PDFKit's is grey, and grey lands somewhere down the ramp. A page
        // says where it ends by drawing its own rule instead — see `AmberPDFPage`.
        view.pageShadowsEnabled = false
        view.subviews.compactMap { $0 as? UIScrollView }.first
            .map { $0.showsVerticalScrollIndicator = false }

        pager.view = view
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyHighlights(highlights, to: view)
    }

    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate, PDFDocumentDelegate {
        /// Every page drawn is one that draws its own edge.
        func classForPage() -> AnyClass { AmberPDFPage.self }

        var parent: PDFDocumentView
        private weak var view: PDFView?
        private var offsetToken: NSKeyValueObservation?
        private var sizeToken: NSKeyValueObservation?
        private var restored = false
        /// What is drawn on the pages now, so a redraw is only paid for when the set has
        /// changed — `updateUIView` runs on every glow tweak.
        private var drawnMarks: String?

        init(_ parent: PDFDocumentView) { self.parent = parent }

        func attach(to view: PDFView) {
            self.view = view

            NotificationCenter.default.addObserver(
                self, selector: #selector(selectionChanged),
                name: .PDFViewSelectionChanged, object: view)
            NotificationCenter.default.addObserver(
                self, selector: #selector(pageChanged),
                name: .PDFViewPageChanged, object: view)

            // The scroll view is PDFKit's own and not offered by name, so it is found
            // rather than asked for. Everything that needs it degrades quietly if it is
            // ever not there: the position stops being reported and the scrubber stops
            // travelling, and the document still reads.
            if let scroll = view.subviews.compactMap({ $0 as? UIScrollView }).first {
                parent.pager.scrollView = scroll
                offsetToken = scroll.observe(\.contentOffset, options: [.new]) { [weak self] s, _ in
                    MainActor.assumeIsolated { self?.settle(s) }
                }
                sizeToken = scroll.observe(\.contentSize, options: [.new]) { [weak self] s, _ in
                    MainActor.assumeIsolated { self?.settle(s) }
                }
            }

            let tap = UITapGestureRecognizer(target: self, action: #selector(pageTapped))
            tap.cancelsTouchesInView = false
            tap.delaysTouchesEnded = false
            tap.delegate = self
            view.addGestureRecognizer(tap)

            applyHighlights(parent.highlights, to: view)
        }

        /// Paints the marked passages onto the pages.
        ///
        /// PDFKit already knows how to draw a highlight, so it draws them — as its own
        /// annotations, in a grey that the view's grayscale-then-amber mapping lands
        /// somewhere sensible on the ramp, the same way it lands the type. They are
        /// annotations on the open document only: nothing is ever written back to the
        /// file, which stays exactly the bytes that were downloaded. The marks live in
        /// the sidecar next to it.
        ///
        /// Ours are recognised by what is in `contents`, so a document that arrived with
        /// annotations of its own keeps them.
        func applyHighlights(_ list: [Highlight], to view: PDFView) {
            let key = list.map { "\($0.id.uuidString):\($0.hasNote)" }.joined(separator: ",")
            guard key != drawnMarks, let document = view.document else { return }
            drawnMarks = key

            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                for annotation in page.annotations
                where annotation.contents?.hasPrefix(Self.markPrefix) == true {
                    page.removeAnnotation(annotation)
                }
            }

            for mark in list {
                guard let index = mark.pageIndex, let boxes = mark.boxes,
                      let page = document.page(at: index) else { continue }
                for box in boxes {
                    let annotation = PDFAnnotation(bounds: box.rect, forType: .highlight,
                                                   withProperties: nil)
                    annotation.color = UIColor(white: mark.hasNote ? 0.44 : 0.58, alpha: 1)
                    annotation.contents = Self.markPrefix + mark.id.uuidString
                    page.addAnnotation(annotation)
                }
            }
        }

        private static let markPrefix = "amber-highlight:"

        func detach() {
            NotificationCenter.default.removeObserver(self)
            offsetToken = nil
            sizeToken = nil
        }

        // MARK: - Where we are

        @MainActor
        private func settle(_ scroll: UIScrollView) {
            restoreIfNeeded(scroll)
            report(scroll)
        }

        @MainActor
        private func restoreIfNeeded(_ scroll: UIScrollView) {
            guard !restored, scroll.bounds.height > 0,
                  scroll.contentSize.height > scroll.bounds.height else { return }
            restored = true
            // A page was asked for while the document was still laying out. Restoring
            // where the reader left off would pull them straight back off it.
            guard !parent.pager.wentToPage else { return }
            let limit = scroll.contentSize.height - scroll.bounds.height
            guard parent.initialProgress > 0.001 else { return }
            scroll.contentOffset.y = limit * parent.initialProgress
        }

        @MainActor
        private func report(_ scroll: UIScrollView) {
            guard restored, let view, let document = view.document else { return }
            let viewport = scroll.bounds.height
            let length = scroll.contentSize.height
            guard viewport > 0, length > 0 else { return }

            let limit = max(0, length - viewport)
            let percent = limit > 0 ? min(1, max(0, scroll.contentOffset.y / limit)) : 0

            // The page is the one printed on the paper, asked for rather than worked out.
            // A web view had to be told the count from the file's own metadata and the
            // page inferred from how far down the scroll had gone.
            let total = max(1, document.pageCount)
            let page = view.currentPage.map { document.index(for: $0) + 1 } ?? 1

            parent.onPages(min(total, max(1, page)), total, percent, length)
            parent.onProgress(percent)
        }

        @objc private func pageChanged() {
            guard let scroll = parent.pager.scrollView else { return }
            MainActor.assumeIsolated { report(scroll) }
        }

        // MARK: - What is selected

        @objc private func selectionChanged() {
            MainActor.assumeIsolated {
                guard let view else { return }
                Self.declineSystemMenu(in: view)
                report(selectionOf: view)
            }
        }

        /// Takes off the edit-menu interactions, over and over.
        ///
        /// Refusing through `canPerformAction` is not enough here and was never going to
        /// be: the responder that is asked is PDFKit's own document view, not the
        /// `PDFView` the app subclassed, so the override was never reached. And the
        /// interaction is not there to be found when the view first meets a window — it
        /// arrives with the selection, which is why this runs each time one changes.
        ///
        /// The same move the app's text fields need, for the same reason: the callout is
        /// contributed through the interaction rather than the responder chain, and taking
        /// the interaction away is what actually removes it.
        private static func declineSystemMenu(in view: UIView) {
            for interaction in view.interactions where interaction is UIEditMenuInteraction {
                view.removeInteraction(interaction)
            }
            for sub in view.subviews { declineSystemMenu(in: sub) }
        }

        /// The whole reason the engine changed.
        ///
        /// `currentSelection` gives the text and, through the page it falls on, where it
        /// sits — which is all the app's own edit menu ever needed. A web view showing a
        /// PDF answers neither: its content view claims to be a `UITextInput` and then
        /// reports no text at all.
        @MainActor
        private func report(selectionOf view: PDFView) {
            guard let selection = view.currentSelection,
                  let page = selection.pages.first,
                  let text = selection.string, !text.isEmpty else {
                parent.onSelection(nil)
                return
            }
            let rect = view.convert(selection.bounds(for: page), from: page)
            parent.onSelection(WebSelection(text: text, rect: rect, isEditable: false))
        }

        // MARK: - Tap

        @objc private func pageTapped() {
            // A tap while something is selected is a tap to be done with it, and nothing
            // else — the chrome keeps whatever state it was in. That is what the same tap
            // means over an article, where the page's own script reports the selection
            // away before it reports the tap.
            if let view, view.currentSelection != nil {
                view.clearSelection()
                parent.onSelection(nil)
                return
            }
            parent.onTap()
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

/// A `PDFView` that declines the system's edit menu.
///
/// The callout is presented in a window of its own, above every filter the app can apply,
/// so it arrives in system grey and blue whatever the panel is set to. The app draws its
/// own over the reader and the browser, and now over this — so the built-in one is refused
/// twice: through the responder chain, and by taking off the interaction that contributes
/// to it on its own, which is the same pair the app's text fields need.
private final class AmberPDFView: PDFView {
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool { false }

    override func layoutSubviews() {
        super.layoutSubviews()
        holdTheFloor()
    }

    /// How far out a PDF may be pinched.
    ///
    /// Left to itself it goes down without end, and somewhere down there the pages stop
    /// being anything to read. Two things bound it, and the looser of them wins.
    ///
    /// The page across the glass is one — on a phone that is already smaller than the
    /// sheet, so there is nothing to be gained by going under it. On a wide panel it is
    /// the other way about: fitting the width blows the sheet up large, and pulling back
    /// to a column with margins either side is a reasonable thing to want. The narrowest
    /// column the reader will set an article in is 600pt, and a page is not worth
    /// shrinking past the point where it would be narrower than that.
    ///
    /// Both are measured at layout rather than when the document arrives, since neither
    /// means anything until the view has been given a size.
    private func holdTheFloor() {
        guard bounds.width > 0,
              let page = currentPage ?? document?.page(at: 0) else { return }
        let fit = scaleFactorForSizeToFit
        guard fit > 0 else { return }
        let sheet = page.bounds(for: displayBox).width
        let column = sheet > 0 ? Self.narrowestColumn / sheet : fit
        let floor = min(fit, column)
        if minScaleFactor != floor { minScaleFactor = floor }
        if maxScaleFactor < floor * 8 { maxScaleFactor = floor * 8 }
    }

    /// The bottom of the reader's own column range, in points — see `readerColumnPoints`.
    private static let narrowestColumn: CGFloat = 600
}

/// A page that draws its own edge.
///
/// Where a sheet ends is worth seeing. Prose runs straight across a page break — the last
/// line of one and the first of the next are the same sentence — and with nothing to mark
/// the join it reads as a line that has been cut in half rather than a page that has been
/// turned. PDFKit offers a shadow for this, which is grey, and grey is a colour this app
/// does not have. So the page draws a rule at its own boundary instead, and the rule is
/// drawn in grey on purpose: everything here is on its way through the filter, where grey
/// becomes amber and a light grey becomes a shade just off the page.
///
/// Drawn after `super`, so it sits over the sheet rather than under whatever is printed
/// on it. `PDFDocumentDelegate.classForPage()` is what puts this class in play.
final class AmberPDFPage: PDFPage {
    /// Just off white. Through the mapping that is a hair darker than the page, which is
    /// all an edge needs to be — it is there to be found, not to be looked at.
    private static let edge = UIColor(white: 0.86, alpha: 1).cgColor

    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        super.draw(with: box, to: context)
        context.saveGState()
        context.setStrokeColor(Self.edge)
        context.setLineWidth(1)
        // Inset by half the line, so the stroke lands on the sheet rather than straddling
        // its edge and losing half its width to whatever is outside.
        context.stroke(bounds(for: box).insetBy(dx: 0.5, dy: 0.5))
        context.restoreGState()
    }
}
