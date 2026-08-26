import SwiftUI

struct DetailPane: View {
    @Environment(Library.self) private var library
    @Environment(DisplaySettings.self) private var settings
    @Environment(\.amber) private var amber
    @Environment(\.horizontalSizeClass) private var sizeClass

    let article: SavedArticle?
    @Binding var showLibrary: Bool
    @Binding var chromeVisible: Bool
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
    }

    private var isCompact: Bool { sizeClass == .compact }

    private func searchURL(for text: String) -> URL {
        var components = URLComponents(string: "https://duckduckgo.com/")!
        components.queryItems = [URLQueryItem(name: "q", value: text)]
        return components.url!
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
                    Text(article.host)
                        .font(.system(size: 10, weight: .medium))
                        .tracking(0.5)
                        .foregroundStyle(amber.inkFaint)
                }
                .padding(.leading, 6)

                Spacer(minLength: 12)

                AmberIconButton(symbol: "sun.max", isActive: panelOpen, action: onGlow)
                AmberIconButton(symbol: "globe") { onOpenLink(article.url) }
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
                                  pageCount: article.pageCount,
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
                                  pager: pdfPager)
                        .id(article.id)
                        .task(id: article.id) { liveProgress = article.lastScroll }
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
                        onSelection: { found in
                            withAnimation(.easeOut(duration: 0.14)) { selection = found }
                        },
                        onPages: { page, total, percent in
                            self.page = page
                            self.pageCount = total
                            self.percent = percent
                        },
                        bridge: bridge
                    )
                    .id(article.id)
                    .task(id: article.id) { liveProgress = article.lastScroll }
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
                                    actions: [.copy, .search]
                                ) { action in
                                    WebEditor.perform(action, on: bridge, selection: selection,
                                                      search: { onOpenLink(searchURL(for: $0)) })
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
                Text("Setting the type…")
                    .font(.system(size: 15, design: .serif))
                    .foregroundStyle(amber.inkMuted)
                Text(article.host)
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.6)
                    .foregroundStyle(amber.inkFaint)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

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
