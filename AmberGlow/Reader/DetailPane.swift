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
    /// The open article's text, read once — see `articleContent`.
    @State private var loadedBody: Library.LoadedBody?

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

        /// A definition arrives as a card; a question fills the panel it is asked in.
        /// The presentation needs to know which — see `AmberItemPresentation`.
        var isDefinition: Bool {
            if case .define = self { return true }
            return false
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
        // A novel's text is not kept around once nothing is reading it.
        .onChange(of: article?.id) { _, id in if id == nil { loadedBody = nil } }
        .overlay { markCard }
        .modifier(AmberFullScreenPresentation(isPresented: $showHighlights) {
            if let article {
                HighlightsSheet(scope: article) { _, mark in
                    revealHighlight = mark.id
                }
            }
        })
        .overlay { definitionCard }
        .modifier(AmberItemPresentation(isCompact: isCompact,
                                        item: sheetPanel,
                                        isCard: \.isDefinition) { panel in
            switch panel {
            case .define(let term):
                definition(for: term, drawsOwnFace: false)
                    // The card sizes itself in height — see `entryWindow` — so all the
                    // sheet owes it is a width. 420 as an ideal as well as a ceiling: a
                    // bare ceiling lets a fitted sheet shrink the card to the
                    // dictionary's own idea of a width, which is 320 — narrow enough
                    // that the panel changes its layout underneath us.
                    .frame(idealWidth: 420, maxWidth: 420)
            case .ask(let passage, let title):
                AskAISheet(passage: passage, title: title)
            }
        })
    }

    /// What is handed to a sheet. On a phone a definition is not — see `definitionCard`
    /// — and this binding is where that one decision lives, so the panel state can stay
    /// single: the sheet is simply not asked about a definition it will not be showing.
    private var sheetPanel: Binding<ReaderPanel?> {
        Binding(get: { panel.flatMap { isCompact && $0.isDefinition ? nil : $0 } },
                set: { panel = $0 })
    }

    /// A definition on a phone: a card over the page, the way a mark's card is.
    ///
    /// Not a sheet, because a sheet on a phone has to be full screen — a card
    /// presentation there brings the system's own furniture with it — and a screen of
    /// glass under a small card is a screen the reader loses for a word. The page it was
    /// read on stays where it was, a scrim under the card, and the word a few lines away.
    ///
    /// A wide screen keeps the sheet: there it can be fitted to the card, and the card
    /// floats over the page already.
    @ViewBuilder
    private var definitionCard: some View {
        if isCompact, case .define(let term)? = panel {
            ZStack {
                AmberScrim { closePanel() }
                definition(for: term, drawsOwnFace: true)
                    .frame(maxWidth: 420)
                    .padding(.horizontal, 20)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func definition(for term: String, drawsOwnFace: Bool) -> some View {
        DefinitionCard(term: term,
                       drawsOwnFace: drawsOwnFace,
                       onSearch: {
                           closePanel()
                           onOpenLink(searchURL(for: term))
                       },
                       onClose: closePanel)
    }

    private func closePanel() {
        withAnimation(.easeOut(duration: 0.16)) { panel = nil }
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
            // Animated for the phone's card, which has a transition to run. A sheet
            // brings its own and does not mind.
            if let word = selection.singleWord {
                withAnimation(.easeOut(duration: 0.16)) { panel = .define(word) }
            }
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

    /// What brings the drawer out. On a phone the drawer is the whole screen and the
    /// front page is where you came from, so the button is a way back; on a wide panel
    /// the drawer slides over the page, and the button says so.
    private var drawerSymbol: String { isCompact ? "chevron.left" : "sidebar.left" }

    private func chrome(for article: SavedArticle) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                AmberIconButton(symbol: drawerSymbol) {
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
        case .ready where library.isDownloading(article):
            // Saved on another device, and iCloud has not brought it here yet. Reading a
            // placeholder would hold the app until it did — see `ArticleStore.isReadable`
            // — so the page waits visibly instead, and is redrawn when the file lands.
            VStack(spacing: 18) {
                AmberSpinner()
                Text("Fetching from iCloud…")
                    .font(.system(size: 15, design: .serif))
                    .foregroundStyle(amber.inkMuted)
                Text(article.sourceLabel)
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.6)
                    .foregroundStyle(amber.inkFaint)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

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
            } else {
                articleContent(for: article)
            }

        case .pending:
            settingType(for: article)

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

    /// An article's page, from the text held for it — see `Library.LoadedBody`.
    ///
    /// Held rather than read here. This view is redrawn on every scroll report, which
    /// is every frame of a scroll, and reading the file on each of them was a novel's
    /// worth of bytes per frame. The text is read once, off this thread, and again only
    /// when its stamp moves — the file rewritten, or the article read again.
    @ViewBuilder
    private func articleContent(for article: SavedArticle) -> some View {
        let stamp = library.bodyStamp(for: article)
        ZStack {
            if let loaded = loadedBody, loaded.stamp == stamp {
                if let body = loaded.text {
                    articlePage(for: article, body: body)
                } else {
                    message(icon: "doc.questionmark",
                            title: "The saved text went missing.",
                            detail: "Read it again to fetch a fresh copy.") {
                        Button("Read it again") { library.retry(article) }
                            .buttonStyle(AmberButtonStyle(kind: .solid))
                    }
                }
            } else {
                settingType(for: article)
            }
        }
        .task(id: stamp) {
            loadedBody = await library.loadBody(for: article, stamp: stamp)
        }
    }

    private func settingType(for article: SavedArticle) -> some View {
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
    }

    private func articlePage(for article: SavedArticle, body: String) -> some View {
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
                onHighlightBreaks: { found in highlights.setBreaks(found, in: article) },
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
                AmberIconButton(symbol: drawerSymbol) {
                    withAnimation(.drawer) { showLibrary = true }
                }
                Spacer()
            }
            .padding(12)

            Spacer()
            // The couplet is set to the glass it is on: at 40pt its first line needs more
            // width than a phone has, and the line breaks are the whole point of it — so
            // the type gives way rather than the wrap.
            Text("Soft on the eyes,\nwarmth for the soul.")
                .font(.system(size: isCompact ? 27 : 40, weight: .regular, design: .serif))
                .multilineTextAlignment(.center)
                .lineSpacing(isCompact ? 4 : 6)
                .foregroundStyle(amber.inkStrong)
                .padding(.horizontal, isCompact ? 26 : 40)
            Text("Pick something from the front page, or add a link.")
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
