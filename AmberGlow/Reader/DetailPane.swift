import SwiftUI

struct DetailPane: View {
    @Environment(Library.self) private var library
    @Environment(Highlights.self) private var highlights
    @Environment(DisplaySettings.self) private var settings
    @Environment(\.amber) private var amber
    @Environment(\.horizontalSizeClass) private var sizeClass

    let article: SavedArticle?
    @Binding var showLibrary: Bool
    @Binding var chromeVisible: Bool
    /// A passage to travel to, set when one is chosen from the highlights list. Cleared
    /// by the page once it has been reached.
    @Binding var revealHighlight: UUID?
    var panelOpen: Bool
    var onOpenLink: (URL) -> Void
    var onDismissArticle: () -> Void
    var onGlow: () -> Void

    @State private var selection: WebSelection?
    @State private var bridge = ReaderBridge()
    @State private var page = 1
    @State private var pageCount = 1
    @State private var percent: Double = 0
    /// Continuous, unlike the persisted `lastScroll`, which only moves in whole percent
    /// steps — that threshold is right for writing to disk and wrong for drawing a bar.
    @State private var liveProgress: Double = 0
    /// Height of the page area, so the scrubber can size its track to it.
    @State private var pageHeight: CGFloat = 0
    /// How much room the scrubber is taking, so the ground under it can match.
    @State private var scrubberHeight: CGFloat = 0
    /// Drives a PDF's scrolling, as `bridge` drives an article's.
    @State private var pdfPager = PDFPager()
    /// A PDF's length in points. Its pages are its own, so the scrubber cannot infer it.
    @State private var documentLength: CGFloat = 0
    /// A book's table of contents, read once when the book opens rather than on every
    /// render — it can run to several hundred entries.
    @State private var chapters: [BookChapter] = []
    /// The chapter anchor nearest the top of the screen right now, so the contents sheet
    /// can mark it — the reader's equivalent of `ArticleRow`'s selection highlight.
    @State private var currentChapterAnchor: String?
    @State private var showContents = false
    /// This reading's own marks, opened from the chrome.
    @State private var showHighlights = false
    /// A definition, or a question about a passage. One at a time: both are about the
    /// same selection, and both take the glass.
    @State private var panel: ReaderPanel?
    /// The mark whose card is open — just made, or just tapped.
    @State private var openMark: Highlight?
    /// Whether there is a model on this device to ask. Read when a selection appears
    /// rather than while the callout is being laid out — the answer can change while the
    /// app is open, but not between one frame and the next.
    @State private var canAskAI = false

    /// What the reader asked of a selection that the page cannot answer itself.
    enum ReaderPanel: Identifiable {
        case define(String)
        case ask(passage: String, title: String)

        var id: String {
            switch self {
            case .define(let term): return "define:" + term
            case .ask(let passage, _): return "ask:" + passage
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let article {
                // The chrome is lifted out of the layout rather than hidden in place, so
                // the page reclaims the space instead of leaving a gap where the bar was.
                if chromeVisible {
                    chrome(for: article)
                    Hairline()
                }
                content(for: article)
            } else {
                splash
            }
        }
        .overlay { markCard }
        .modifier(AmberFullScreenPresentation(isPresented: $showHighlights) {
            if let article {
                HighlightsSheet(scope: article) { _, mark in
                    revealHighlight = mark.id
                }
            }
        })
        .modifier(AmberItemPresentation(isCompact: isCompact, item: $panel) { panel in
            switch panel {
            case .define(let term):
                DefinitionCard(term: term,
                               onSearch: {
                                   self.panel = nil
                                   onOpenLink(searchURL(for: term))
                               },
                               onClose: { self.panel = nil })
                    // The card sizes itself now — see `entryHeight` — so all this owes
                    // it is a measure. On a phone the surface behind it is the whole
                    // glass and the card floats in the middle of it.
                    .frame(width: 420)
                    .padding(.horizontal, isCompact ? 20 : 0)
            case .ask(let passage, let title):
                AskAISheet(passage: passage, title: title)
            }
        })
    }

    /// The card for a mark — just made, or just tapped. Over the page rather than in a
    /// sheet: the passage it is about is a few lines away, and covering it would take
    /// away the thing the note is being written about.
    @ViewBuilder
    private var markCard: some View {
        if let mark = openMark, let article {
            ZStack {
                AmberScrim { closeMark() }
                HighlightCard(
                    highlight: mark,
                    onRemove: {
                        highlights.remove(mark.id, from: article)
                        closeMark()
                    },
                    onClose: closeMark,
                    onNote: { note in highlights.setNote(note, on: mark.id, in: article) }
                )
                .padding(.horizontal, 18)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func closeMark() {
        withAnimation(.easeOut(duration: 0.16)) { openMark = nil }
    }

    /// A passage picked out of a list has been reached.
    ///
    /// Its card opens here rather than in the list it was picked from, wherever that
    /// was. This is the source: the words are on the page under the scrim, and a note
    /// written about them is written about the passage rather than about a fragment
    /// quoted out of it — which is why the library's own card cannot write one.
    private func reachedPassage() {
        guard let id = revealHighlight, let article,
              let mark = highlights.highlight(id, in: article) else {
            revealHighlight = nil
            return
        }
        revealHighlight = nil
        withAnimation(.easeOut(duration: 0.16)) { openMark = mark }
    }

    private var isCompact: Bool { sizeClass == .compact }

    private func searchURL(for text: String) -> URL {
        var components = URLComponents(string: "https://duckduckgo.com/")!
        components.queryItems = [URLQueryItem(name: "q", value: text)]
        return components.url!
    }

    // MARK: - What a selection can become

    /// What the callout offers for this selection.
    ///
    /// Neither a PDF nor a saved article can be written in, so nothing that edits appears
    /// in either. What is left is what can be done *with* the words: kept, looked up,
    /// asked about, searched for. Two of the four are conditional — a dictionary has an
    /// answer for a word and not for a paragraph, and asking needs a model on the device
    /// — and both simply aren't there when they have nothing to offer.
    private func actions(for selection: WebSelection) -> [EditAction] {
        var list: [EditAction] = [.copy]
        if selection.singleWord != nil { list.append(.define) }
        list.append(.highlight)
        if canAskAI { list.append(.askAI) }
        list.append(.search)
        return list
    }

    private func noteSelection(_ found: WebSelection?) {
        if found != nil { canAskAI = AppleIntelligence.isAvailable }
        withAnimation(.easeOut(duration: 0.14)) { selection = found }
    }

    /// The three that are the app's rather than the page's. Answering true means the
    /// action has been dealt with here and the document should not be asked to do
    /// anything about it.
    ///
    /// Each of them lets the selection go afterwards. The callout is taken down by the
    /// app either way, but the words stay selected in the document underneath — and the
    /// page reports its selection again on the next scroll, so a callout the reader
    /// thought they had dismissed comes back on its own.
    private func handleShared(_ action: EditAction, on selection: WebSelection,
                              in article: SavedArticle) -> Bool {
        switch action {
        case .define:
            if let word = selection.singleWord { panel = .define(word) }
        case .askAI:
            panel = .ask(passage: selection.tidyText, title: article.displayTitle)
        case .highlight:
            mark(selection, in: article)
        default:
            return false
        }
        deselect(in: article)
        return true
    }

    /// Let go of the words, whichever kind of document is holding them.
    private func deselect(in article: SavedArticle) {
        if article.isPDF {
            pdfPager.clearSelection()
        } else {
            WebEditor.clearSelection(on: bridge)
        }
    }

    /// Keep this passage.
    ///
    /// An article's page is asked to anchor it — only the document knows where its own
    /// text starts and stops — and answers back through `onHighlight`. A PDF has no
    /// document of ours to ask, so the same job is done through the view.
    private func mark(_ selection: WebSelection, in article: SavedArticle) {
        if article.isPDF {
            guard let captured = pdfPager.captureSelection() else { return }
            keep(captured, in: article)
        } else {
            // Ordered before the deselect that follows: WebKit runs what it is given in
            // the order it is given it, and the capture needs the selection still there.
            bridge.runJavaScript("window.__agHL && window.__agHL.capture();")
        }
    }

    /// Saves an anchored passage and opens its card, so the note can be written while the
    /// reason for marking it is still in mind. The highlight is already saved by then —
    /// closing the card without typing leaves a plain one.
    private func keep(_ mark: Highlight, in article: SavedArticle) {
        highlights.add(mark, to: article)
        withAnimation(.easeOut(duration: 0.16)) { openMark = mark }
    }

    /// A PDF is read-only, so nothing that edits appears. The article's `WebEditor` runs
    /// its work as script in the page, which is exactly what a PDF has none of — but copy
    /// was never script to begin with.
    private func performPDF(_ action: EditAction, on selection: WebSelection,
                            in article: SavedArticle) {
        if handleShared(action, on: selection, in: article) { return }
        switch action {
        case .copy:
            UIPasteboard.general.string = selection.tidyText
        case .search:
            onOpenLink(searchURL(for: selection.tidyText))
        default:
            break
        }
        pdfPager.clearSelection()
    }

    private func toggleChrome() {
        withAnimation(.easeOut(duration: 0.2)) { chromeVisible.toggle() }
    }

    // MARK: - Chrome

    private func chrome(for article: SavedArticle) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                AmberIconButton(symbol: "sidebar.left") {
                    withAnimation(.drawer) { showLibrary = true }
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(article.displayTitle)
                        .font(.system(size: 13, weight: .semibold, design: .serif))
                        .lineLimit(1)
                        .foregroundStyle(amber.ink)
                    Text(article.sourceLabel)
                        .font(.system(size: 10, weight: .medium))
                        .tracking(0.5)
                        .foregroundStyle(amber.inkFaint)
                }
                .padding(.leading, 6)

                Spacer(minLength: 12)

                AmberIconButton(symbol: "sun.max", isActive: panelOpen, action: onGlow)
                // What you kept out of this one, where you are reading it. Only once
                // there is something to keep: an always-present button that opens an
                // empty list is a button that says nothing about the page you are on.
                if highlights.count(for: article) > 0 {
                    AmberIconButton(symbol: "highlighter") { showHighlights = true }
                }
                // A book has no page of its own to open in the browser — what the globe
                // button opens for everything else — so it gets the one piece of chrome
                // that means something instead: its contents.
                if article.isBook {
                    AmberIconButton(symbol: "list.bullet") { showContents = true }
                } else {
                    AmberIconButton(symbol: "globe") { onOpenLink(article.url) }
                }
                AmberIconButton(symbol: article.isArchived ? "tray.and.arrow.up" : "archivebox") {
                    library.setArchived(article, !article.isArchived)
                    if !article.isArchived { onDismissArticle() }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Reading position, as a hairline the eye can ignore.
            GeometryReader { geo in
                Rectangle()
                    .fill(amber.color(0.34))
                    .frame(width: geo.size.width * liveProgress, height: 2)
                    .animation(.linear(duration: 0.12), value: liveProgress)
            }
            .frame(height: 2)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(for article: SavedArticle) -> some View {
        switch article.state {
        case .ready:
            if article.isPDF {
                // The same furniture an article gets. A PDF is a different kind of
                // document, not a different kind of reading: where you are and how to
                // travel are the same two questions, so they are answered by the same
                // control. The one difference is what a page means — see the pager.
                ZStack(alignment: .bottomTrailing) {
                    PDFReaderView(fileURL: library.documentURL(for: article),
                                  initialProgress: article.lastScroll,
                                  onProgress: { p in
                                      liveProgress = p
                                      library.setScroll(p, for: article)
                                  },
                                  onPages: { page, total, percent, length in
                                      self.page = page
                                      self.pageCount = total
                                      self.percent = percent
                                      self.documentLength = length
                                  },
                                  onTap: toggleChrome,
                                  onSelection: noteSelection,
                                  highlights: highlights.list(for: article),
                                  pager: pdfPager)
                        .id(article.id)
                        .task(id: article.id) { liveProgress = article.lastScroll }
                        // The app's own callout, over a PDF as over an article.
                        .overlay {
                            GeometryReader { geo in
                                if let selection {
                                    AmberEditMenuOverlay(
                                        selection: selection,
                                        container: geo.size,
                                        actions: actions(for: selection)
                                    ) { action in
                                        performPDF(action, on: selection, in: article)
                                        withAnimation(.easeOut(duration: 0.14)) { self.selection = nil }
                                    }
                                }
                            }
                        }
                        // A passage chosen from the highlights list: turn to its page.
                        .task(id: revealHighlight) {
                            guard let target = revealHighlight,
                                  let mark = highlights.highlight(target, in: article),
                                  let page = mark.pageIndex else { return }
                            pdfPager.reveal(pageIndex: page)
                            reachedPassage()
                        }
                        .overlay {
                            if pageCount > 1, isCompact, scrubberHeight > 0 {
                                ScrubberGround(height: scrubberHeight)
                            }
                        }
                        .ignoresSafeArea(.container, edges: .bottom)

                    if pageCount > 1 {
                        PageScrubber(page: page,
                                     total: pageCount,
                                     percent: percent,
                                     style: Binding(get: { settings.progressStyle },
                                                    set: { settings.progressStyle = $0 }),
                                     available: pageHeight,
                                     documentLength: documentLength) { velocity in
                            pdfPager.autoScroll(velocity)
                        }
                        .padding(.trailing, 16)
                        .padding(.bottom, 18)
                    }
                }
                .background { HeightReader(height: $pageHeight) }
                .onPreferenceChange(ScrubberFootprint.self) { scrubberHeight = $0 }
                .onDisappear { pdfPager.stop() }
            } else if let body = library.body(for: article) {
                // The page runs to the physical bottom of the glass; the scrubber does
                // not. It is a control, so it stays a sibling of the web view rather than
                // an overlay on it — that keeps it inside the safe area and off the home
                // indicator, which on a phone reaches 34pt up from the bezel.
                ZStack(alignment: .bottomTrailing) {
                    ReaderWebView(
                        article: article,
                        body: body,
                        palette: settings.palette,
                        settings: settings,
                        onProgress: { p in
                            liveProgress = p
                            library.setScroll(p, for: article)
                        },
                        onOpenLink: onOpenLink,
                        onTap: toggleChrome,
                        onSelection: noteSelection,
                        onPages: { page, total, percent in
                            self.page = page
                            self.pageCount = total
                            self.percent = percent
                        },
                        onChapter: { anchor in currentChapterAnchor = anchor },
                        highlights: highlights.list(for: article),
                        revealHighlight: revealHighlight,
                        onRevealed: reachedPassage,
                        onHighlight: { mark in keep(mark, in: article) },
                        onMarkTap: { id in
                            guard let mark = highlights.highlight(id, in: article) else { return }
                            withAnimation(.easeOut(duration: 0.16)) { openMark = mark }
                        },
                        bridge: bridge
                    )
                    .id(article.id)
                    .task(id: article.id) {
                        liveProgress = article.lastScroll
                        chapters = article.isBook ? BookContents.read(for: article, store: .shared) : []
                        currentChapterAnchor = nil
                    }
                    .modifier(AddLinkPresentation(isCompact: isCompact, isPresented: $showContents) {
                        ContentsSheet(article: article, chapters: chapters,
                                     currentAnchor: currentChapterAnchor) { chapter in
                            bridge.runJavaScript("window.__ag && window.__ag.goto('\(chapter.href)');")
                        }
                    })
                    // The ground goes on the page, not on the control, so it can be the
                    // page — and it runs to the bezel with it, so the pool has no edge
                    // where the safe area starts. Under the callout, so a selection made
                    // down in that corner still reads.
                    .overlay {
                        if pageCount > 1, isCompact, scrubberHeight > 0 {
                            ScrubberGround(height: scrubberHeight)
                                .transition(.opacity.animation(.easeOut(duration: 0.22)))
                        }
                    }
                    // The callout is drawn by the app, over the page, because the system
                    // one is presented in its own window and cannot be given a colour.
                    .overlay {
                        GeometryReader { geo in
                            if let selection {
                                AmberEditMenuOverlay(
                                    selection: selection,
                                    container: geo.size,
                                    actions: actions(for: selection)
                                ) { action in
                                    if !handleShared(action, on: selection, in: article) {
                                        WebEditor.perform(action, on: bridge, selection: selection,
                                                          search: { onOpenLink(searchURL(for: $0)) })
                                    }
                                    withAnimation(.easeOut(duration: 0.14)) { self.selection = nil }
                                }
                            }
                        }
                    }
                    // The web view is otherwise inset by the home-indicator safe area,
                    // which left a visible ledge where the document's fill stopped.
                    .ignoresSafeArea(.container, edges: .bottom)

                    if pageCount > 1 {
                        PageScrubber(page: page,
                                     total: pageCount,
                                     percent: percent,
                                     style: Binding(get: { settings.progressStyle },
                                                    set: { settings.progressStyle = $0 }),
                                     available: pageHeight) { velocity in
                            bridge.runJavaScript("window.__agPager && window.__agPager.autoScroll(\(velocity));")
                        }
                        .padding(.trailing, 16)
                        .padding(.bottom, 18)
                    }
                }
                // Measured from behind rather than around: the scrubber's tap is a
                // zero-distance drag competing with WebKit's own recognisers, and it
                // does not survive another layout container being put in its way.
                .background { HeightReader(height: $pageHeight) }
                .onPreferenceChange(ScrubberFootprint.self) { scrubberHeight = $0 }
            } else {
                message(icon: "doc.questionmark",
                        title: "The saved text went missing.",
                        detail: "Read it again to fetch a fresh copy.") {
                    Button("Read it again") { library.retry(article) }
                        .buttonStyle(AmberButtonStyle(kind: .solid))
                }
            }

        case .pending:
            VStack(spacing: 18) {
                AmberSpinner()
                Text(article.isBook ? "Opening the book…" : "Setting the type…")
                    .font(.system(size: 15, design: .serif))
                    .foregroundStyle(amber.inkMuted)
                Text(article.sourceLabel)
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.6)
                    .foregroundStyle(amber.inkFaint)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed where article.isBook:
            message(icon: "text.badge.xmark",
                    title: "This book couldn't be opened.",
                    detail: library.lastError ?? "Something about this file's contents wasn't readable.") {
                Button("Try again") { library.retry(article) }
                    .buttonStyle(AmberButtonStyle(kind: .solid))
            }

        case .failed:
            message(icon: "text.badge.xmark",
                    title: "No article text on that page.",
                    detail: "Some pages build their text after loading, and a few just aren't articles. You can still read it in the amber browser.") {
                HStack(spacing: 10) {
                    Button("Try again") { library.retry(article) }
                        .buttonStyle(AmberButtonStyle(kind: .outline))
                    Button("Open in browser") { onOpenLink(article.url) }
                        .buttonStyle(AmberButtonStyle(kind: .solid))
                }
            }
        }
    }

    @ViewBuilder
    private func message<Actions: View>(icon: String, title: String, detail: String,
                                        @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(amber.inkFaint)
            Text(title)
                .font(.system(size: 19, weight: .medium, design: .serif))
                .foregroundStyle(amber.inkStrong)
            Text(detail)
                .font(.system(size: 13))
                .lineSpacing(3)
                .multilineTextAlignment(.center)
                .foregroundStyle(amber.inkMuted)
                .frame(maxWidth: 380)
            actions().padding(.top, 6)
        }
        .padding(isCompact ? 26 : 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty

    private var splash: some View {
        VStack(spacing: 0) {
            HStack {
                AmberIconButton(symbol: "sidebar.left") {
                    withAnimation(.drawer) { showLibrary = true }
                }
                Spacer()
            }
            .padding(12)

            Spacer()
            // The couplet is set to the glass it is on: at 40pt its first line needs more
            // width than a phone has, and the line breaks are the whole point of it — so
            // the type gives way rather than the wrap.
            Text("When the lights go off,\nenjoy the amber glow.")
                .font(.system(size: isCompact ? 27 : 40, weight: .regular, design: .serif))
                .multilineTextAlignment(.center)
                .lineSpacing(isCompact ? 4 : 6)
                .foregroundStyle(amber.inkStrong)
                .padding(.horizontal, isCompact ? 26 : 40)
            Text("Pick something from the library, or add a link.")
                .font(.system(size: isCompact ? 13 : 14))
                .multilineTextAlignment(.center)
                .foregroundStyle(amber.inkFaint)
                .padding(.horizontal, 26)
                .padding(.top, isCompact ? 16 : 22)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A spinner made of ticks on the amber ramp — no system accent color anywhere near it.
struct AmberSpinner: View {
    @Environment(\.amber) private var amber
    @State private var phase = 0

    private let count = 12

    var body: some View {
        ZStack {
            ForEach(0..<count, id: \.self) { i in
                let distance = Double((i - phase + count) % count) / Double(count)
                Capsule()
                    .fill(amber.color(0.12 + 0.62 * distance))
                    .frame(width: 2.5, height: 8)
                    .offset(y: -12)
                    .rotationEffect(.degrees(Double(i) / Double(count) * 360))
            }
        }
        .frame(width: 34, height: 34)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 70_000_000)
                phase = (phase + 1) % count
            }
        }
    }
}
