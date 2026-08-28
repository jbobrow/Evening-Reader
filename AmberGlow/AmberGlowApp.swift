import SwiftUI

@main
struct AmberGlowApp: App {
    @State private var settings = DisplaySettings()
    @State private var library = Library()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(library)
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
    @Environment(\.amber) private var amber
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var selection: SavedArticle.ID?
    @State private var showLibrary = true
    @State private var scope: Library.Scope = .unread
    @State private var search = ""
    @State private var showAdd = false
    @State private var browseTarget: BrowseTarget?
    /// Set when a file opened from outside the app (Files, Mail, another app's "Open
    /// in…") turns out not to be a book Amber Glow can read — a lock the app cannot
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
        .fullScreenCover(item: $browseTarget) { target in
            BrowseScreen(initialURL: target.url) { saved in
                open(saved)
            }
            // Full-screen covers are hosted through a separate presentation path on Mac
            // (running the iPad build) and don't reliably inherit the window's environment
            // there, so `@Environment(Library.self)` / `@Environment(DisplaySettings.self)`
            // inside BrowseScreen would find no ancestor and SwiftUI would fatally assert.
            .environment(library)
            .environment(settings)
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
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { library.pickUpInbox() }
            if phase == .background { library.persist() }
        }
        .task {
            // Read off disk first: the library behind the veil is then already the one
            // the reader left, so lifting it is a cross-fade to the app rather than to an
            // empty shelf that fills in a moment later.
            library.refreshFromDisk()

            withAnimation(.easeIn(duration: 0.9)) { launchName = true }
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            withAnimation(.easeInOut(duration: 0.7)) { launching = false }

            // iCloud is asked for afterwards. It can take a minute to answer, and the
            // opening is not the place to wait for it — what it brings arrives in the
            // list, which is where it can be seen arriving.
            await library.startSync()
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

    @ViewBuilder
    private func libraryPane() -> some View {
        LibraryPane(
            scope: $scope,
            search: $search,
            selection: $selection,
            onAdd: { showAdd = true },
            onBrowse: { browseTarget = BrowseTarget(url: nil) },
            onClose: { withAnimation(.drawer) { showLibrary = false } },
            onOpened: { withAnimation(.drawer) { showLibrary = false } },
            onGlow: { toggleGlow(.library) },
            panelOpen: glowPanel == .library,
            onRequestDelete: { article in
                withAnimation(.easeOut(duration: 0.18)) { confirmDelete = article }
            }
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

    /// A book opened from outside the app turned out to be one Amber Glow can't read.
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

    /// Drawn by the app rather than presented as a popover. A system popover supplies its
    /// own white container behind the content, which shows through the rounded corners as
    /// a hairline and flashes white for a frame on dismissal — neither is survivable in a
    /// panel whose whole premise is that no second color exists.
    @ViewBuilder
    private func glowOverlay(in size: CGSize) -> some View {
        if glowPanel != nil, isCompact {
            glowPanelFullScreen
        } else if let anchor = glowPanel {
            glowPanelCard(anchor: anchor, in: size)
        }
    }

    /// On a phone the panel takes the whole glass.
    ///
    /// The card is 380pt wide and the screen is 402: what is left is an 11pt margin that
    /// reads as a mistake rather than as a frame. And the card has no close of its own —
    /// it relies on there being page beside it to tap on, which at that width there is
    /// not. Full screen gives the controls the room they were drawn for and puts the way
    /// out on the panel itself.
    private var glowPanelFullScreen: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Display settings")
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                    .foregroundStyle(amber.inkStrong)
                Spacer()
                AmberIconButton(symbol: "xmark") {
                    withAnimation(.drawer) { glowPanel = nil }
                }
            }
            .padding(.leading, 22)
            .padding(.trailing, 14)
            .padding(.top, 12)
            .padding(.bottom, 14)

            Hairline()

            PanelControls()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                amber.color(0.93)
                if settings.showTexture { PixelGrid() }
            }
            .ignoresSafeArea()
        }
        // Up over the page, the way the drawer comes in from the side. Sliding rather
        // than fading keeps it a thing that arrived and can be sent away again.
        .transition(.move(edge: .bottom))
    }

    @ViewBuilder
    private func glowPanelCard(anchor: PanelAnchor, in size: CGSize) -> some View {
        let top: CGFloat = chromeVisible ? 54 : 16
        let width = min(380, size.width - 24)
        ZStack(alignment: anchor == .library ? .topLeading : .topTrailing) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.drawer) { glowPanel = nil } }

            PanelControls()
                .frame(width: width)
                // As tall as the glass allows, so the panel is not cut mid-control
                // when there is room to show the whole thing.
                .frame(maxHeight: max(320, size.height - top - 24))
                .background {
                    ZStack {
                        amber.color(0.93)
                        if settings.showTexture { PixelGrid() }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(amber.color(0.62, opacity: 0.5), lineWidth: 1)
                }
                .shadow(color: amber.color(0.0, opacity: 0.22), radius: 26, y: 10)
                .padding(.top, top)
                .padding(.horizontal, 12)
                .transition(
                    .scale(scale: 0.96, anchor: anchor == .library ? .topLeading : .topTrailing)
                    .combined(with: .opacity)
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// amberglow://add?url=… and amberglow://read?url=… so Shortcuts can hand pages over
    /// — or a book, handed over as a file URL by Files, Mail, or another app's "Open in
    /// Amber Glow".
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
