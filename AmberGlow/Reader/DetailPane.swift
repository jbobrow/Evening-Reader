import SwiftUI

struct DetailPane: View {
    @Environment(Library.self) private var library
    @Environment(DisplaySettings.self) private var settings
    @Environment(\.amber) private var amber

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
                PDFReaderView(fileURL: library.documentURL(for: article))
                    .id(article.id)
            } else if let body = library.body(for: article) {
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
                .overlay(alignment: .bottomTrailing) {
                    if pageCount > 1 {
                        PageScrubber(page: page,
                                     total: pageCount,
                                     percent: percent,
                                     style: Binding(get: { settings.progressStyle },
                                                    set: { settings.progressStyle = $0 })) { velocity in
                            bridge.runJavaScript("window.__agPager && window.__agPager.autoScroll(\(velocity));")
                        }
                        .padding(.trailing, 16)
                        .padding(.bottom, 18)
                    }
                }
                // The callout is drawn by the app, over the page, because the system one
                // is presented in its own window and cannot be given a colour.
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
                // Run the page to the physical bottom of the glass. The web view is
                // otherwise inset by the home-indicator safe area, which used to leave a
                // visible ledge where the document's fill stopped.
                .ignoresSafeArea(.container, edges: .bottom)
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
        .padding(40)
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
            Text("When the lights go off,\nenjoy the amber glow.")
                .font(.system(size: 40, weight: .regular, design: .serif))
                .multilineTextAlignment(.center)
                .lineSpacing(6)
                .foregroundStyle(amber.inkStrong)
                .padding(.horizontal, 40)
            Text("Pick something from the library, or add a link.")
                .font(.system(size: 14))
                .foregroundStyle(amber.inkFaint)
                .padding(.top, 22)
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
