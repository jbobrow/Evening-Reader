import SwiftUI

/// The front page. What the drawer opens on: the reading you were in the middle of, the
/// thing you last saved, the library, your sites, and one field for anything else.
///
/// Five quiet things rather than a list. The library is one tap away, pushed in over
/// this pane; the sites and the field are the two ways out of it.
struct HomePane: View {
    @Environment(Library.self) private var library
    @Environment(Sites.self) private var sites
    @Environment(DisplaySettings.self) private var settings
    @Environment(\.amber) private var amber

    @Binding var scope: Library.Scope
    @Binding var search: String
    @Binding var selection: SavedArticle.ID?
    /// Whether the drawer this pane fills is out. The pane goes back to its front page
    /// once the drawer has been put away, so it always comes out on the front page.
    var isOpen: Bool

    var onAdd: () -> Void
    var onHighlights: () -> Void
    /// Present only where there is page beside the drawer to close it onto.
    var onClose: (() -> Void)?
    var onOpened: () -> Void
    var onGlow: () -> Void
    var panelOpen: Bool
    var onRequestDelete: (SavedArticle) -> Void
    var onBrowse: (URL) -> Void
    var onAddSite: () -> Void
    var onEditSite: (Site) -> Void

    /// The library list, pushed in over the front page.
    @State private var showingList = false
    /// The field is the whole pane while it is in use.
    @State private var searching = false
    @State private var query = ""
    @State private var queryFocused = false
    /// Which tile's menu is open, and where in the pane it should hang.
    @State private var tileMenu: (site: Site, y: CGFloat)?
    @State private var tileFrames: [Site.ID: CGRect] = [:]

    var body: some View {
        ZStack(alignment: .topLeading) {
            if showingList {
                LibraryPane(
                    scope: $scope,
                    search: $search,
                    selection: $selection,
                    onAdd: onAdd,
                    onBack: { withAnimation(.drawer) { showingList = false } },
                    onOpened: onOpened,
                    onRequestDelete: onRequestDelete
                )
                .transition(.move(edge: .trailing))
            } else {
                front
                    .transition(.move(edge: .leading))
            }
        }
        // Clipped so the list slides in behind the drawer's edge rather than over the
        // page beside it — but with a mask that runs into the safe-area bands, so a
        // scrim put up over the pane can still cover the whole glass.
        .mask { Rectangle().ignoresSafeArea() }
        .onChange(of: isOpen) { _, open in
            guard !open else { return }
            // The drawer is leaving for a page; a keyboard raised for the search has
            // nothing to type into there and goes down with it.
            if queryFocused { queryFocused = false }
            AmberKeyboardInstaller.putAway()
            // After the drawer has finished leaving, so the swap is never seen.
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !isOpen else { return }
                showingList = false
            }
        }
    }

    // MARK: - The front page

    private var front: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            if searching {
                searchBar
                Hairline()
                results
            } else {
                ScrollView {
                    page
                }
                .scrollIndicators(.hidden)
            }
        }
        .coordinateSpace(name: "homePane")
        .overlay { tileMenuOverlay }
    }

    private var header: some View {
        HStack(spacing: 2) {
            Text("EVENING READER")
                .font(.system(size: 13, weight: .bold, design: .default))
                .tracking(2.6)
                .lineLimit(1)
                .foregroundStyle(amber.inkStrong)
            Spacer()
            AmberIconButton(symbol: "highlighter", action: onHighlights)
            AmberIconButton(symbol: "sun.max", isActive: panelOpen, action: onGlow)
            if let onClose {
                AmberIconButton(symbol: "sidebar.left", action: onClose)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 32) {
            if let current = library.continueReading {
                continueBlock(current)
            }
            if let newest = library.justSaved, newest.id != library.continueReading?.id {
                savedBlock(newest)
            }
            if library.articles.isEmpty {
                emptyBlock
            }
            libraryRow
            sitesBlock
            fieldFacade
        }
        .padding(.horizontal, 20)
        .padding(.top, 26)
        .padding(.bottom, 30)
    }

    private func continueBlock(_ article: SavedArticle) -> some View {
        Button { open(article) } label: {
            VStack(alignment: .leading, spacing: 10) {
                AmberCaption(text: "Continue")
                Text(article.displayTitle)
                    .font(.system(size: 26, weight: .medium, design: .serif))
                    .lineSpacing(3)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(amber.inkStrong)
                Text("\(article.sourceLabel) · \(article.remainingLabel ?? article.lengthLabel)")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.4)
                    .lineLimit(1)
                    .foregroundStyle(amber.inkFaint)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(amber.color(0.74)).frame(height: 2)
                        Rectangle().fill(amber.color(0.34))
                            .frame(width: geo.size.width * article.lastScroll, height: 2)
                    }
                }
                .frame(height: 2)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func savedBlock(_ article: SavedArticle) -> some View {
        Button { open(article) } label: {
            VStack(alignment: .leading, spacing: 8) {
                AmberCaption(text: "Just saved")
                Text(article.displayTitle)
                    .font(.system(size: 20, weight: .medium, design: .serif))
                    .lineSpacing(2)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(amber.inkStrong)
                Text("\(article.sourceLabel) · \(article.lengthLabel) · \(Self.when(article.addedAt))")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.4)
                    .lineLimit(1)
                    .foregroundStyle(amber.inkFaint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nothing to read yet.")
                .font(.system(size: 20, weight: .medium, design: .serif))
                .foregroundStyle(amber.inkStrong)
            Text("Share a page to Evening Reader from Safari, share a book from Files, or paste a link.")
                .font(.system(size: 13))
                .lineSpacing(2)
                .foregroundStyle(amber.inkFaint)
            Button("Add a link", action: onAdd)
                .buttonStyle(AmberButtonStyle(kind: .solid, size: 14))
                .padding(.top, 4)
        }
    }

    private var libraryRow: some View {
        Button {
            withAnimation(.drawer) { showingList = true }
        } label: {
            VStack(spacing: 0) {
                Hairline()
                HStack(spacing: 12) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(amber.ink)
                    Text("Library")
                        .font(.system(size: 17, weight: .medium, design: .serif))
                        .foregroundStyle(amber.inkStrong)
                    Spacer()
                    Text("\(library.count(scope: .unread)) unread")
                        .font(.system(size: 12, weight: .medium))
                        .tracking(0.4)
                        .foregroundStyle(amber.inkFaint)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(amber.inkFaint)
                }
                .padding(.vertical, 16)
                Hairline()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var sitesBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            AmberCaption(text: "Sites")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5),
                      alignment: .leading, spacing: 14) {
                ForEach(sites.sites) { site in
                    // A tap and a long press on a plain view, as the library's rows
                    // do. A button would take the touch for itself, and the press that
                    // opens the menu would never arrive.
                    SiteTile(site: site, icon: sites.icon(for: site))
                        .contentShape(Rectangle())
                        .onTapGesture { onBrowse(site.url) }
                    .overlay {
                        GeometryReader { geo in
                            let frame = geo.frame(in: .named("homePane"))
                            Color.clear
                                .onAppear { tileFrames[site.id] = frame }
                                .onChange(of: frame) { _, new in tileFrames[site.id] = new }
                        }
                        .allowsHitTesting(false)
                    }
                    .onLongPressGesture(minimumDuration: 0.4) {
                        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                        withAnimation(.easeOut(duration: 0.16)) {
                            tileMenu = (site, tileFrames[site.id]?.maxY ?? 0)
                        }
                    }
                }
                AddSiteTile(action: onAddSite)
            }
        }
    }

    /// Looks like the field, and is a button: tapping it turns the pane over to the real
    /// one. A text field that moved between two places in the layout would be rebuilt
    /// on the way and lose the keyboard.
    private var fieldFacade: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { searching = true }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(amber.inkFaint)
                Text("Search your library or the web")
                    .font(.system(size: 14))
                    .foregroundStyle(amber.inkFaint)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(amber.color(0.78))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(amber.rule, lineWidth: 1))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - The field

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(amber.inkFaint)
                AmberTextField(text: $query,
                               isFocused: $queryFocused,
                               placeholder: "Search your library or the web",
                               palette: settings.palette,
                               showsTexture: settings.showTexture,
                               goLabel: "Go",
                               fontSize: 14,
                               onSubmit: submitQuery)
                    .frame(height: 19)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(amber.inkFaint)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(amber.color(0.78))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(amber.color(0.34), lineWidth: 1))
            )
            Button("Cancel", action: leaveSearch)
                .buttonStyle(AmberButtonStyle(kind: .quiet, size: 14))
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 12)
        .onAppear { queryFocused = true }
    }

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                let q = trimmedQuery
                if q.isEmpty {
                    if !sites.sites.isEmpty {
                        sectionLabel("Sites")
                        ForEach(sites.sites) { site in siteRow(site) }
                    }
                } else {
                    let found = Array(library.list(scope: .all, search: q).prefix(8))
                    if !found.isEmpty {
                        sectionLabel("In your library")
                        ForEach(found) { article in articleRow(article) }
                    }
                    let matching = sites.sites.filter {
                        $0.name.lowercased().contains(q.lowercased())
                            || $0.host.lowercased().contains(q.lowercased())
                    }
                    if !matching.isEmpty {
                        sectionLabel("Sites")
                        ForEach(matching) { site in siteRow(site) }
                    }
                    // An address goes first, since what was typed is one; words are a
                    // search first and an address only if they could be one.
                    sectionLabel("On the web")
                    if let url = BrowserModel.url(from: q) {
                        resultRow(symbol: "globe", title: "Go to \(url.host ?? q)") {
                            go(to: url)
                        }
                    }
                    resultRow(symbol: "magnifyingglass", title: "Search the web for “\(q)”") {
                        go(to: BrowserModel.searchURL(for: q))
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func sectionLabel(_ text: String) -> some View {
        AmberCaption(text: text)
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 8)
    }

    private func articleRow(_ article: SavedArticle) -> some View {
        Button { open(article) } label: {
            HStack(spacing: 12) {
                Image(systemName: article.isBook ? "book.closed" : "doc.text")
                    .font(.system(size: 17))
                    .foregroundStyle(amber.inkMuted)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(article.displayTitle)
                        .font(.system(size: 16, weight: .medium, design: .serif))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(article.readAt == nil ? amber.inkStrong : amber.inkMuted)
                    Text("\(article.sourceLabel) · \(article.lengthLabel)")
                        .font(.system(size: 11, weight: .medium))
                        .tracking(0.4)
                        .foregroundStyle(amber.inkFaint)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Hairline(inset: 14) }
    }

    private func siteRow(_ site: Site) -> some View {
        Button { go(to: site.url) } label: {
            HStack(spacing: 12) {
                SiteFace(site: site, icon: sites.icon(for: site), size: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(site.name.isEmpty ? site.host : site.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(amber.inkStrong)
                    Text(site.host)
                        .font(.system(size: 11, weight: .medium))
                        .tracking(0.4)
                        .foregroundStyle(amber.inkFaint)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Hairline(inset: 14) }
    }

    private func resultRow(symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(amber.inkMuted)
                    .frame(width: 34, height: 34)
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(amber.inkStrong)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Hairline(inset: 14) }
    }

    private func submitQuery() {
        let q = trimmedQuery
        guard !q.isEmpty else { return }
        go(to: BrowserModel.url(from: q) ?? BrowserModel.searchURL(for: q))
    }

    private func go(to url: URL) {
        leaveSearch()
        onBrowse(url)
    }

    private func leaveSearch() {
        queryFocused = false
        query = ""
        // Let go of the keyboard now, before the bar it belongs to is taken away — a
        // field removed while it still has the keyboard loses it without a transition.
        AmberKeyboardInstaller.putAway()
        withAnimation(.easeOut(duration: 0.18)) { searching = false }
    }

    // MARK: - Opening

    private func open(_ article: SavedArticle) {
        selection = article.id
        library.markRead(article)
        library.noteOpened(article)
        onOpened()
    }

    // MARK: - Tile menu

    @ViewBuilder
    private var tileMenuOverlay: some View {
        if let tileMenu {
            GeometryReader { geo in
                AmberScrim(opacity: 0.18) {
                    withAnimation(.easeOut(duration: 0.16)) { self.tileMenu = nil }
                }
                AmberMenu(items: [
                    AmberMenuItem(title: "Edit", symbol: "pencil") { onEditSite(tileMenu.site) },
                    AmberMenuItem(title: "Remove", symbol: "trash", isDestructive: true) {
                        sites.remove(tileMenu.site)
                    },
                ]) {
                    withAnimation(.easeOut(duration: 0.16)) { self.tileMenu = nil }
                }
                .fixedSize()
                .padding(.leading, 20)
                .offset(y: min(tileMenu.y + 6, max(0, geo.size.height - 130)))
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
            }
        }
    }

    /// "today", "yesterday", or the day.
    private static func when(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "today" }
        if calendar.isDateInYesterday(date) { return "yesterday" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}
