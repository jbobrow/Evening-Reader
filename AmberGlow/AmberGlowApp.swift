import SwiftUI

@main
struct AmberGlowApp: App {
    @State private var settings = DisplaySettings()
    @State private var library = Library()
    @State private var highlights = Highlights()
    @State private var sites = Sites()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(library)
                .environment(highlights)
                .environment(sites)
                .environment(\.amber, settings.palette)
                .tint(settings.palette.ink)
                .preferredColorScheme(.light)   // we paint every surface ourselves
                .statusBarHidden(true)          // no clock, no wifi, no battery — just the panel
                .persistentSystemOverlays(.hidden)
        }
    }
}

extension Animation {
    /// One curve for every drawer and panel move, so the app has a single sense of weight.
    static let drawer = Animation.interpolatingSpring(stiffness: 420, damping: 38)
}

struct RootView: View {
    @Environment(DisplaySettings.self) private var settings
    @Environment(Library.self) private var library
    @Environment(Highlights.self) private var highlights
    @Environment(Sites.self) private var sites
    @Environment(\.amber) private var amber
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var selection: SavedArticle.ID?
    @State private var showLibrary = true
    @State private var scope: Library.Scope = .unread
    @State private var search = ""
    @State private var showAdd = false
    @State private var showHighlights = false
    /// A marked passage the reader picked out of the highlights list, on its way to the
    /// page it came off. Cleared by the reader once it has been reached.
    @State private var revealHighlight: UUID?
    @State private var browseTarget: BrowseTarget?
    /// A site being added or changed.
    @State private var siteDraft: SiteDraft?
    /// Set when a file opened from outside the app (Files, Mail, another app's "Open
    /// in…") turns out not to be a book Evening Reader can read — a lock the app cannot
    /// open, or something that isn't an EPUB at all.
    @State private var bookImportProblem: EpubGuard.Problem?

    /// Chrome hides on a tap so a page can be read with nothing else on the glass.
    @State private var chromeVisible = true
    /// Which button opened the glow panel, or nil when it is closed.
    @State private var glowPanel: PanelAnchor?
    /// Live finger travel while the drawer is being dragged.
    @State private var drawerDrag: CGFloat = 0
    /// True once a touch has committed to moving the drawer rather than scrolling.
    @State private var drawerTracking = false
    /// Article awaiting a delete confirmation.
    @State private var confirmDelete: SavedArticle?
    /// The opening. `launching` is the black itself; `launchName` is the name on it.
    @State private var launching = true
    @State private var launchName = false

    enum PanelAnchor { case library, reader }

    /// Identity for the full-screen browser; `url` nil means "start at the address bar".
    struct BrowseTarget: Identifiable {
        let id = UUID()
        let url: URL?
    }

    /// A phone, or a window narrow enough to behave like one: the drawer takes the whole
    /// width instead of leaving a sliver of the page beside it, and the panels that float
    /// over the page stop being fixed-width cards.
    private var isCompact: Bool { sizeClass == .compact }

    private var selected: SavedArticle? {
        guard let selection else { return nil }
        return library.articles.first { $0.id == selection }
    }

    var body: some View {
        GeometryReader { geo in
            // On a phone the drawer is the screen. At 86% it would leave a 55pt ribbon of
            // the page down the right edge — too narrow to read and too wide to ignore,
            // and the reader behind it is a different article from the one you are
            // choosing. Full width makes it a push instead of a peek.
            let drawerWidth = isCompact ? geo.size.width : min(380, geo.size.width * 0.86)
            // -drawerWidth is fully closed, 0 is fully open; the drag rides in between.
            let offset = min(0, max(-drawerWidth,
                                    (showLibrary ? 0 : -drawerWidth) + drawerDrag))
            let progress = 1 + offset / drawerWidth

            ZStack(alignment: .topLeading) {
                GlowSurface()

                DetailPane(
                    article: selected,
                    showLibrary: $showLibrary,
                    chromeVisible: $chromeVisible,
                    revealHighlight: $revealHighlight,
                    panelOpen: glowPanel == .reader,
                    onOpenLink: { browseTarget = BrowseTarget(url: $0) },
                    onDismissArticle: { selection = nil },
                    onGlow: { toggleGlow(.reader) }
                )

                edgeAffordance(width: drawerWidth, progress: progress)

                // Dimming the page behind the drawer, in step with how far it is out.
                //
                // Always mounted, and taken out of the way by hit testing rather than by
                // being removed. It carries a drawer gesture, and a closing drag ends at
                // exactly the moment its own progress reaches zero: removed there, the
                // gesture is destroyed in mid-flight and never ends, and the travel it
                // was holding is left behind on the drawer for good — added to every
                // position asked for afterwards, which is a drawer that will not open
                // however it is asked.
                amber.color(0.02, opacity: 0.28 * progress)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.drawer) { showLibrary = false } }
                    // Pushing the page left puts the drawer away too, so the drawer
                    // can be dismissed from the side you are already reading on.
                    .gesture(drawerDragGesture(width: drawerWidth))
                    .allowsHitTesting(progress > 0.001)
                    .zIndex(1)

                libraryPane()
                    .frame(width: drawerWidth)
                    .frame(maxHeight: .infinity)
                    .offset(x: offset)
                    .simultaneousGesture(drawerDragGesture(width: drawerWidth))
                    .zIndex(2)

                glowOverlay(in: geo.size)
                    .zIndex(3)

                confirmDeleteOverlay
                    .zIndex(4)

                bookImportProblemOverlay
                    .zIndex(4)

                if launching {
                    LaunchVeil(nameShowing: launchName)
                        .transition(.opacity)
                        .zIndex(5)
                }
            }
        }
        .statusBarHidden(true)
        .modifier(AddLinkPresentation(isCompact: isCompact, isPresented: $showAdd) {
            AddLinkSheet { url in
                open(library.add(url: url))
            }
        })
        .modifier(AmberItemPresentation(isCompact: isCompact, item: $siteDraft) { draft in
            NewSiteSheet(draft: draft)
        })
        .modifier(AmberFullScreenPresentation(isPresented: $showHighlights) {
            HighlightsSheet { article, mark in
                open(article)
                // `open` only puts the drawer away on a phone, where it is the whole
                // screen. Here it goes either way: this is a request to see one
                // particular passage, and on a wide panel the drawer is over the page
                // it is on.
                withAnimation(.drawer) { showLibrary = false }
                revealHighlight = mark.id
            }
        })
        .fullScreenCover(item: $browseTarget) { target in
            BrowseScreen(initialURL: target.url) { saved in
                open(saved)
            }
            .environment(highlights)
            // Full-screen covers are hosted through a separate presentation path on Mac
            // (running the iPad build) and don't reliably inherit the window's environment
            // there, so `@Environment(Library.self)` / `@Environment(DisplaySettings.self)`
            // inside BrowseScreen would find no ancestor and SwiftUI would fatally assert.
            .environment(library)
            .environment(settings)
            .environment(sites)
        }
        .onOpenURL(perform: handle)
        // Whatever moved the drawer, any drag that was in flight is finished with. A
        // gesture that is interrupted rather than ended keeps its travel, and that travel
        // goes on being added to the drawer's position — so it is cleared here as well as
        // in the gesture, where an interruption is the one case that never reaches.
        .onChange(of: showLibrary) { _, _ in
            drawerDrag = 0
            drawerTracking = false
        }
        // The sites live beside the library, and move into iCloud with it.
        .onChange(of: library.syncState) { _, _ in
            sites.refreshFromDisk()
            reclaimSettings()
        }
        .onChange(of: scenePhase) { _, phase in
            // What came down from iCloud arrived as whole folders, so what is held about
            // any of them is stale. The library re-reads itself; the marks are told to.
            if phase == .active {
                library.pickUpInbox()
                sites.refreshFromDisk()
                highlights.forget()
                library.checkClipboard()
                reclaimSettings()
            }
            if phase == .background { library.persist() }
        }
        .task {
            let opened = ContinuousClock.now
            withAnimation(.easeIn(duration: 0.9)) { launchName = true }
            library.checkClipboard()

            // The shelf is read while the name is coming up, so lifting the veil is a
            // cross-fade to the library the reader left rather than to an empty one
            // that fills in a moment later. The reading is off this thread and never
            // waits on iCloud — see `ArticleStore.isReadable` — and the veil is not
            // held for it past a point either: a second is the opening, and it is held
            // for that whether or not the shelf is in; three is a problem the reader
            // should be looking at the app for.
            let shelf = Task {
                await library.reload()
                await sites.reload()
            }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await shelf.value }
                group.addTask { try? await Task.sleep(for: .seconds(3)) }
                await group.next()
                group.cancelAll()
            }
            let elapsed = ContinuousClock.now - opened
            if elapsed < .seconds(1) { try? await Task.sleep(for: .seconds(1) - elapsed) }
            withAnimation(.easeInOut(duration: 0.7)) { launching = false }

            // iCloud is asked for afterwards. It can take a minute to answer, and the
            // opening is not the place to wait for it — what it brings arrives in the
            // list, which is where it can be seen arriving.
            await library.startSync()
        }
    }

    /// Gives the settings back what an earlier build lost to iCloud. Asked on each
    /// return as well as once the library is in iCloud: the file may still have been on
    /// its way down the first time, and after it has been taken there is nothing to find.
    private func reclaimSettings() {
        Task {
            if let stray = await library.reclaimStrayPreferences() {
                settings.recover(from: stray)
            }
        }
    }

    /// Show an article.
    ///
    /// Selecting from the list already puts the drawer away, but a selection made
    /// anywhere else — saving a link, or reading a page found in the browser — has to do
    /// it too. On a phone the drawer is the whole screen, so leaving it open lands the
    /// reader on the article and then covers it with the library, which reads as nothing
    /// having happened at all. A wide panel shows the article beside the drawer, so there
    /// it stays put.
    private func open(_ article: SavedArticle) {
        selection = article.id
        // Opened to read is read, whichever way it was opened — the same as picking it
        // from the list.
        library.markRead(article)
        library.noteOpened(article)
        guard isCompact else { return }
        withAnimation(.drawer) { showLibrary = false }
    }

    // MARK: - Drawer

    private func drawerDragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                // Decide once, at the start, whether this touch belongs to the drawer or
                // to the list underneath it, then stay with that decision — re-testing
                // every frame would drop tracking the moment a sideways pull drifted.
                if !drawerTracking {
                    guard abs(value.translation.width) > abs(value.translation.height),
                          abs(value.translation.width) > 4 else { return }
                    drawerTracking = true
                }
                drawerDrag = value.translation.width
            }
            .onEnded { value in
                guard drawerTracking else { drawerDrag = 0; return }
                drawerTracking = false
                let predicted = value.predictedEndTranslation.width
                let opened = showLibrary
                    ? predicted > -width * 0.4      // a small pull leaves it open
                    : predicted > width * 0.3       // a decisive pull brings it out
                withAnimation(.drawer) {
                    showLibrary = opened
                    drawerDrag = 0
                }
            }
    }

    /// The left edge when the drawer is away: a strip that catches the pull-out swipe,
    /// carrying the small handle that says there is something to pull. Both live on one
    /// view so the handle cannot swallow the touch before the strip sees it.
    @ViewBuilder
    private func edgeAffordance(width: CGFloat, progress: Double) -> some View {
        ZStack(alignment: .leading) {
            Color.clear
            Capsule()
                .fill(amber.color(0.42, opacity: 0.55))
                .frame(width: 5, height: 48)
                .padding(.leading, 5)
                .opacity(1 - progress)
        }
        .frame(width: 30)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(drawerDragGesture(width: width))
        .onTapGesture { withAnimation(.drawer) { showLibrary = true } }
        .allowsHitTesting(!showLibrary)
        .zIndex(1)
    }

    /// The drawer's contents: the front page, with the library a push away inside it.
    @ViewBuilder
    private func libraryPane() -> some View {
        HomePane(
            scope: $scope,
            search: $search,
            selection: $selection,
            isOpen: showLibrary,
            onAdd: { showAdd = true },
            onHighlights: { showHighlights = true },
            // On a phone the drawer is the screen; there is no page beside it to close
            // onto, and the front page is the place to be rather than a thing to put away.
            onClose: isCompact ? nil : { withAnimation(.drawer) { showLibrary = false } },
            onOpened: { withAnimation(.drawer) { showLibrary = false } },
            onGlow: { toggleGlow(.library) },
            panelOpen: glowPanel == .library,
            onRequestDelete: { article in
                withAnimation(.easeOut(duration: 0.18)) { confirmDelete = article }
            },
            onBrowse: { browseTarget = BrowseTarget(url: $0) },
            onAddSite: { siteDraft = SiteDraft() },
            onEditSite: { siteDraft = SiteDraft(editing: $0) }
        )
        .background(GlowSurface(level: 0.83, bloomStrength: 0.25))
        .overlay(alignment: .trailing) { amber.rule.frame(width: 1) }
    }

    /// Destructive confirmation, drawn by the app — `UIAlertController` cannot be themed.
    @ViewBuilder
    private var confirmDeleteOverlay: some View {
        if let article = confirmDelete {
            ZStack {
                AmberScrim { dismissConfirm() }
                AmberConfirm(
                    title: "Remove this article?",
                    message: article.displayTitle,
                    confirmTitle: "Remove",
                    confirm: {
                        if selection == article.id { selection = nil }
                        library.delete(article)
                        dismissConfirm()
                    },
                    cancel: dismissConfirm
                )
                .padding(.horizontal, 20)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A book opened from outside the app turned out to be one Evening Reader can't read.
    /// An acknowledgement, not a choice — there is nothing to confirm or cancel.
    @ViewBuilder
    private var bookImportProblemOverlay: some View {
        if let problem = bookImportProblem {
            ZStack {
                AmberScrim { bookImportProblem = nil }
                AmberConfirm(
                    title: problem.title,
                    message: problem.detail,
                    confirmTitle: "OK",
                    cancelTitle: nil,
                    confirm: { bookImportProblem = nil }
                )
                .padding(.horizontal, 20)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func dismissConfirm() {
        withAnimation(.easeOut(duration: 0.18)) { confirmDelete = nil }
    }

    // MARK: - Glow panel

    private func toggleGlow(_ anchor: PanelAnchor) {
        withAnimation(.drawer) { glowPanel = (glowPanel == anchor) ? nil : anchor }
    }

    @ViewBuilder
    private func glowOverlay(in size: CGSize) -> some View {
        if let anchor = glowPanel {
            GlowPanelOverlay(isCompact: isCompact,
                             alignment: anchor == .library ? .topLeading : .topTrailing,
                             top: chromeVisible ? 54 : 16,
                             size: size) {
                withAnimation(.drawer) { glowPanel = nil }
            }
        }
    }

    /// amberglow://add?url=… and amberglow://read?url=… so Shortcuts can hand pages over
    /// — or a book, handed over as a file URL by Files, Mail, or another app's "Open in
    /// Evening Reader".
    private func handle(_ url: URL) {
        if url.isFileURL {
            importBookFile(at: url)
            return
        }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = comps.queryItems?.first(where: { $0.name == "url" })?.value,
              let target = URL(string: raw) else { return }
        let article = library.add(url: target)
        if comps.host == "read" || comps.path.contains("read") {
            open(article)
        }
    }

    /// A book opened directly as a file, rather than shared as a link. Runs the same
    /// guard the share extension runs — DRM and `.acsm` are refused here just as plainly
    /// — then hands the rest of the work to `Library`, exactly as a book that arrived
    /// through the share extension would.
    private func importBookFile(at url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            bookImportProblem = .notAnEpub
            return
        }

        do {
            let (_, package) = try EpubInspector.open(data: data)
            var article = SavedArticle(kind: .book,
                                       url: BookIdentity.url(package: package, fileData: data),
                                       title: package.title, state: .pending)
            article.byline = package.creator
            article.siteName = package.publisher
            let resolved = library.addBookFile(article, from: url)
            open(resolved)
        } catch let failure as EpubInspector.Failure {
            bookImportProblem = failure.problem
        } catch {
            bookImportProblem = .notAnEpub
        }

        // iOS copies a file opened this way into the app's own sandbox (Documents/Inbox)
        // unless it stayed in place at its owner's — the book's own copy lives in the
        // library folder now, so the Inbox copy is only ever debris.
        if url.path.contains("/Inbox/") {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
