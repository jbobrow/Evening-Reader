import SwiftUI

/// A minimal browser for finding things to read. Live pages are collapsed to luminance
/// and re-lit with the same amber ramp as the rest of the app.
struct BrowseScreen: View {
    @Environment(Library.self) private var library
    @Environment(Sites.self) private var sites
    @Environment(DisplaySettings.self) private var settings
    @Environment(\.amber) private var amber
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.controlsTrailing) private var controlsTrailing
    @Environment(\.controlsRailed) private var controlsRailed
    @Environment(\.cameraStrip) private var cameraStrip

    let initialURL: URL?
    /// Leaving for the drawer: the browser goes, and the front page is what is left.
    var onShowDrawer: () -> Void = {}
    var onSaved: (SavedArticle) -> Void

    @State private var model = BrowserModel()
    @State private var address = ""
    @State private var savedFlash = false
    @State private var addressFocused = false
    /// The address, called up in place of the page's name on an app's bar.
    @State private var editingAddress = false
    /// This site, on its way to the front page.
    @State private var siteDraft: SiteDraft?
    /// The display settings, over the page.
    @State private var glowOpen = false
    /// Height of the page area, so the scrubber can size its track to it.
    @State private var pageHeight: CGFloat = 0
    /// How much room the scrubber is taking, so the ground under it can match.
    @State private var scrubberHeight: CGFloat = 0
    /// The phone was turned sideways for a video, and goes back upright after it.
    /// Turned by hand in the meantime, the video simply fits itself to the glass
    /// either way; only the exit button, or the page, takes it out of fullscreen.
    @State private var turnedForVideo = false
    /// The video went fullscreen because the phone was turned sideways while it played,
    /// so turning it back upright is the way out — as the phone's own players have it.
    /// One put into fullscreen by its button stays in, whichever way it is held.
    @State private var fullscreenByTurning = false

    var body: some View {
        pane
            .animation(.easeOut(duration: 0.22), value: model.chromeHidden)
            .animation(.easeOut(duration: 0.22), value: model.appMode)
            .animation(.easeOut(duration: 0.22), value: model.videoFullscreen)
            .background {
                // Behind a fullscreen video, the glass the page does not reach — round
                // the island and the home indicator — is the video's own black, as the
                // tint draws it, rather than a lit page framing it.
                if model.videoFullscreen {
                    amber.color(0.0).ignoresSafeArea()
                } else {
                    GlowSurface(level: 0.88)
                }
            }
            .overlay {
                // The reader outside the condition, so it is the panel itself that comes
                // and goes — and the panel's own transition, up from the bottom on a phone,
                // is the one that plays. Conditional on the reader, the reader was what
                // appeared, and it only knows how to fade.
                GeometryReader { geo in
                    if glowOpen && !isCompact {
                        GlowPanelOverlay(isCompact: isCompact, alignment: .topTrailing,
                                         top: 54, size: geo.size) {
                            withAnimation(.drawer) { glowOpen = false }
                        }
                    }
                }
                .allowsHitTesting(glowOpen && !isCompact)
            }
            // On a phone the display settings are a page of their own, up over this one.
            .modifier(PageCover(isPresented: Binding(
                get: { isCompact && glowOpen },
                set: { if !$0 { glowOpen = false } }), short: true) {
                GlowPanelOverlay(isCompact: true, size: .zero) { glowOpen = false }
            })
            .statusBarHidden(true)
            .modifier(videoFullscreenHandling)
            .modifier(AmberItemPresentation(isCompact: isCompact, item: $siteDraft) { draft in
                NewSiteSheet(draft: draft)
            })
            .onAppear {
                model.applyTint(showGrid: settings.showTexture, isNight: isNight)
                if let initialURL {
                    address = initialURL.absoluteString
                    model.isAppSite = site(for: initialURL) != nil
                    model.load(initialURL)
                } else {
                    addressFocused = true
                }
            }
            // The page goes with the browser: stopped, and let go of. Left to the view's
            // own release it would never have gone — see `BrowserModel.retire`.
            .onDisappear { model.retire() }
            .onChange(of: settings.showTexture) { _, grid in
                model.applyTint(showGrid: grid, isNight: isNight)
                WebKeyboardBridge.shared.refresh(palette: settings.palette, showsTexture: grid)
            }
            .onChange(of: settings.polarity) { _, polarity in
                model.applyTint(showGrid: settings.showTexture, isNight: polarity == .night)
            }
            .onChange(of: settings.palette) { _, palette in
                WebKeyboardBridge.shared.refresh(palette: palette, showsTexture: settings.showTexture)
            }
            .onChange(of: addressFocused) { _, focused in
                if !focused { editingAddress = false }
            }
            .onChange(of: model.currentURL) { _, url in
                model.isAppSite = url.flatMap(site(for:)) != nil
                guard !addressFocused, let url else { return }
                address = url.absoluteString
            }
            // Pinning the site you are on makes it one of the apps from here on.
            .onChange(of: pinnedSite?.id) { _, id in
                model.isAppSite = id != nil
            }
    }

    /// The bar, the page and the scrubber: everything below the band.
    private var pane: some View {
        VStack(spacing: 0) {
            // On an article the bar goes away as the page is read down and comes back as
            // it is read up, or on a tap — the same room the reader gives a page.
            // Anywhere else it stays (see `BrowserModel.chromeStays`).
            if !model.chromeHidden && !model.videoFullscreen {
                VStack(spacing: 0) {
                    bar
                    if model.isLoading {
                        GeometryReader { geo in
                            Rectangle()
                                .fill(amber.color(0.30))
                                .frame(width: geo.size.width * model.progress, height: 2)
                        }
                        .frame(height: 2)
                    } else {
                        Hairline()
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            // Same split as the reader: the page runs to the bezel, the scrubber stays
            // inside the safe area so it is not sitting on the home indicator.
            ZStack(alignment: .bottomTrailing) {
                BrowserWebViewHost(model: model,
                                   palette: settings.palette,
                                   showsTexture: settings.showTexture)
                    // The one rule of the panel is that nothing introduces a second hue.
                    // Doing this natively rather than with a CSS filter is what makes that
                    // a guarantee: page elements on their own compositing layer escape a
                    // filter on `<html>`, but nothing in the page can escape a filter on
                    // the rendered view. Luminance first, then squeezed into the ink..page
                    // span so text lands on the ramp's ink rather than pure black, then
                    // multiplied onto the emitter color.
                    .grayscale(1)
                    // Night flips the page over. A web page is written for a light ground,
                    // so left alone its white becomes the darkest thing on screen and its
                    // black text disappears into the panel. A negative contrast is an
                    // inversion, so the flip folds into the same mapping rather than needing
                    // a `.colorInvert()` that would change the view's identity — and
                    // rebuilding the web view on every polarity change would drop the page.
                    .contrast(tintSign * (1 - tintFloor))
                    .brightness(tintFloor / 2)
                    .colorMultiply(tintColor)
                    // Expanded under the camera band, the page keeps a soft corner clear
                    // of the lens — the paper shows there instead.
                    .cutAroundCamera(cameraStrip)
                    // The page is opaque and covers the panel's own surface, so the lamp is
                    // painted back on over the top — otherwise browsing is a flat field
                    // while everything else in the app is lit.
                    .overlay { BacklightBloom(level: isNight ? 0.0 : pageLevel) }
                    // The scrubber's ground. On the page rather than on the control, so
                    // it can be the page — see `ScrubberGround`.
                    .overlay {
                        if model.pageCount > 1, isCompact, scrubberHeight > 0 {
                            ScrubberGround(height: scrubberHeight)
                                .transition(.opacity.animation(.easeOut(duration: 0.22)))
                        }
                    }
                    // App-drawn edit callout; the system one is suppressed because it is
                    // presented in its own window and cannot be given a colour.
                    .overlay {
                        GeometryReader { geo in
                            // Under the callout, which keeps its room clear of them. Nothing
                            // in the browser has to stand aside while one is held.
                            SelectionGrips(selection: model.selection, web: model,
                                           isGripping: .constant(false))
                            if let selection = model.selection {
                                AmberEditMenuOverlay(
                                    selection: selection,
                                    container: geo.size,
                                    actions: menuActions(for: selection),
                                    perform: { action in
                                        WebEditor.perform(action, on: model, selection: selection,
                                                          search: { model.submit($0) })
                                        model.selection = nil
                                    },
                                    onPaste: { text in
                                        WebEditor.paste(text, on: model)
                                        model.selection = nil
                                    }
                                )
                            } else if let field = model.pasteOffer, UIPasteboard.general.hasStrings {
                                // Tapped into an empty field with something to paste:
                                // Paste alone, over the field, as the system would offer.
                                AmberEditMenuOverlay(
                                    selection: WebSelection(text: "", rect: field, isEditable: true),
                                    container: geo.size,
                                    actions: [.paste],
                                    perform: { _ in },
                                    onPaste: { text in
                                        WebEditor.paste(text, on: model)
                                        model.pasteOffer = nil
                                    }
                                )
                            }
                        }
                    }
                    // Run to the physical bottom of the glass; otherwise the page stops at
                    // the home-indicator inset and leaves a ledge. A video in fullscreen
                    // has the whole of the glass.
                    .ignoresSafeArea(.container, edges: model.videoFullscreen ? .all : .bottom)

                if model.pageCount > 1 && !model.videoFullscreen {
                    PageScrubber(page: model.page,
                                 total: model.pageCount,
                                 percent: model.percent,
                                 style: Binding(get: { settings.progressStyle },
                                                set: { settings.progressStyle = $0 }),
                                 available: pageHeight) { velocity in
                        model.autoScroll(velocity)
                    }
                    .padding(.trailing, 16)
                    .padding(.bottom, 18)
                }
            }
            .background { HeightReader(height: $pageHeight) }
            .onPreferenceChange(ScrubberFootprint.self) { scrubberHeight = $0 }
        }
        // Folded shut, the page expanded runs under the camera band, and otherwise
        // the buttons stand in the band beside it — see `CameraStrip`.
        .ignoresSafeArea(.container, edges: cameraStrip?.expanded == true ? .trailing : [])
        .cameraStripRail { railButtons }
    }

    /// The bar's buttons, for the rail down the camera band: the way out first, then
    /// travel, the lamp, and — on a page worth keeping — Save and Read as glyphs.
    @ViewBuilder
    private var railButtons: some View {
        if showsAppBar { drawerButton } else { closeButton }
        backButton
        forwardButton
        glowButton
        if model.isSaveable {
            AmberIconButton(symbol: savedFlash ? "checkmark" : "square.and.arrow.down") {
                save(openReader: false)
            }
            .disabled(model.currentURL == nil)
            .accessibilityLabel("Save")
            AmberIconButton(symbol: "doc.plaintext") { save(openReader: true) }
                .disabled(model.currentURL == nil)
                .accessibilityLabel("Read")
        }
    }

    /// Out of a fullscreen video, in the order that keeps its picture: the phone back
    /// upright first, if it was turned for the video, and the video let go of into the
    /// page only once the glass has finished turning. Let go of mid-turn, a playing
    /// video can be left drawing nothing at all.
    /// Everything a fullscreen video asks of the screen, gathered in one place.
    private var videoFullscreenHandling: VideoFullscreenHandling {
        VideoFullscreenHandling(
            model: model,
            onLeave: { leaveVideoFullscreen() },
            onFullscreenChange: { on in
                turnForVideo(on)
                if !on { fullscreenByTurning = false }
            },
            onTurn: followTurn)
    }

    private func leaveVideoFullscreen(glassTurning: Bool = false) {
        guard model.videoFullscreen else { return }
        let turnedBack = turnUpright() || glassTurning
        Task {
            if turnedBack { try? await Task.sleep(for: .milliseconds(700)) }
            model.releaseVideoFullscreen()
        }
    }

    /// A phone turned with a video on the page: sideways while one plays puts it in
    /// fullscreen, and back upright takes it out again if that is how it went in.
    private func followTurn(_ held: UIDeviceOrientation) {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        if held.isLandscape, !model.videoFullscreen {
            Task {
                guard await model.enterPlayingVideoFullscreen() else { return }
                fullscreenByTurning = true
            }
        } else if held == .portrait, model.videoFullscreen, fullscreenByTurning {
            leaveVideoFullscreen(glassTurning: true)
        }
    }

    /// Puts the glass back upright, if it was turned for the video. Says whether it did.
    private func turnUpright() -> Bool {
        guard turnedForVideo, let scene = activeScene else { return false }
        turnedForVideo = false
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        return true
    }

    private var activeScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }

    /// A phone held upright turns sideways for a fullscreen video, the way a video is
    /// watched, and back upright when the video comes out of it. One already held
    /// sideways is left as it is, and so is an iPad, where a video fills either way.
    private func turnForVideo(_ on: Bool) {
        guard UIDevice.current.userInterfaceIdiom == .phone, let scene = activeScene else { return }
        if on {
            guard scene.effectiveGeometry.interfaceOrientation.isPortrait else { return }
            turnedForVideo = true
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
        } else {
            // Gone some other way than through `leaveVideoFullscreen` — the page
            // navigated, say — and still sideways.
            _ = turnUpright()
        }
    }

    /// The site a page belongs to, if it is one of the reader's own.
    private func site(for url: URL) -> Site? {
        guard let host = url.host else { return nil }
        return sites.site(forHost: host)
    }

    /// Where a white page lands on the ramp — the same level the app's own surfaces use,
    /// so a page sits flush with the chrome around it.
    private let pageLevel = 0.88
    /// Where black ink lands, as a fraction of the page level.
    private let inkFloor = 0.045

    private var isCompact: Bool { sizeClass == .compact }

    private var isNight: Bool { settings.polarity == .night }

    /// Negative inverts, which is what night needs.
    private var tintSign: Double { isNight ? -1 : 1 }

    /// The colour the page is multiplied onto: the emitter on paper, the ink at night —
    /// at night the bright end of the ramp is the ink, not the page.
    private var tintColor: Color { isNight ? amber.color(0.0) : amber.color(pageLevel) }

    /// Where the dark end of the mapping lands, as a fraction of `tintColor`. On paper
    /// that is the ink floor; at night it is how dark the page sits next to the ink, so
    /// a white page comes to rest on the page colour instead of on black.
    private var tintFloor: Double {
        guard isNight else { return inkFloor }
        let ink = amber.rgb(0.0).0
        let page = amber.rgb(pageLevel).0
        return ink > 0 ? min(1, page / ink) : inkFloor
    }

    /// On a phone the bar is two lines: close, the address and the lamp; then travel at
    /// one end and, when the page turns out to be an article, Save and Read at the
    /// other. On a shelf or a feed there is nothing to keep, and a button that would
    /// save nothing is a button that says the app has not looked.
    @ViewBuilder
    private var bar: some View {
        if showsAppBar {
            appBar
        } else if controlsRailed {
            // The buttons are in the rail down the camera band; the bar is the address.
            addressField
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        } else if isCompact {
            // Held in one hand (`controlsTrailing`), every button keeps to the
            // right-hand end of its row, under the thumb; the address takes the rest.
            VStack(spacing: 8) {
                HStack(spacing: 4) {
                    if !controlsTrailing { closeButton }
                    addressField
                    glowButton
                    if controlsTrailing {
                        closeButton
                        CameraStripCollapse()
                    }
                }
                HStack(spacing: 8) {
                    if !controlsTrailing {
                        travelChip(symbol: "chevron.left", enabled: model.canGoBack) { model.web.goBack() }
                        travelChip(symbol: "chevron.right", enabled: model.canGoForward) { model.web.goForward() }
                    }
                    Spacer(minLength: 12)
                    if model.isSaveable {
                        saveButton
                        readButton
                    }
                    if controlsTrailing {
                        travelChip(symbol: "chevron.left", enabled: model.canGoBack) { model.web.goBack() }
                        travelChip(symbol: "chevron.right", enabled: model.canGoForward) { model.web.goForward() }
                    }
                }
            }
            .clearOfCameraStrip(cameraStrip)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .animation(.easeOut(duration: 0.22), value: model.isSaveable)
        } else {
            HStack(spacing: 4) {
                closeButton
                backButton
                forwardButton
                addressField
                glowButton
                if model.isSaveable {
                    saveButton
                    readButton
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .animation(.easeOut(duration: 0.22), value: model.isSaveable)
        }
    }

    /// Whether the page gets the bar one of the reader's own sites gets.
    private var showsAppBar: Bool {
        model.appMode && !editingAddress
    }

    /// The bar for one of the reader's own sites — a web app kept on the front page,
    /// like Kindle's reader. It stays put (see `BrowserModel.chromeStays`), so it is
    /// kept to a single row: an app's page is its own furniture, and wants the room.
    /// The address gives way to the name on the site's tile, since an app's addresses
    /// are its own business and say little; a tap on the name brings the address back
    /// for going somewhere else. There is no pin, the site being pinned already; Save
    /// and Read join the row when the page is an article worth keeping. And
    /// the way out is the drawer — the app is somewhere you went from the front page,
    /// not a page you are done with.
    private var appBar: some View {
        HStack(spacing: 4) {
            if !controlsTrailing && !controlsRailed {
                drawerButton
                backButton
                forwardButton
            }
            Button {
                address = model.currentURL?.absoluteString ?? address
                editingAddress = true
                addressFocused = true
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(appName)
                        .font(.system(size: 13, weight: .semibold, design: .serif))
                        .foregroundStyle(amber.ink)
                    if let host = bareHost, host != appName {
                        Text(host)
                            .font(.system(size: 11))
                            .foregroundStyle(amber.inkFaint)
                    }
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !controlsRailed {
                if model.isSaveable {
                    saveButton
                    readButton
                        .padding(.trailing, 2)
                }
                glowButton
            }
            if controlsTrailing {
                backButton
                forwardButton
                drawerButton
                CameraStripCollapse()
            }
        }
        .clearOfCameraStrip(cameraStrip)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .animation(.easeOut(duration: 0.22), value: model.isSaveable)
    }

    /// Out to the front page, the browser going with it.
    private var drawerButton: some View {
        AmberIconButton(symbol: "sidebar.left") {
            addressFocused = false
            AmberKeyboardInstaller.putAway()
            onShowDrawer()
            dismiss()
        }
    }

    /// What the app is called: its tile's name, or what the page calls itself if the
    /// tile cannot be found.
    private var appName: String {
        if let site = pinnedSite { return site.name }
        guard let host = model.currentURL?.host else { return model.pageTitle }
        return Self.siteName(from: model.pageTitle, host: host)
    }

    private var bareHost: String? {
        guard let host = model.currentURL?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Back and forward as chips, in the row the chips live in.
    private func travelChip(symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 14)
        }
        .buttonStyle(AmberButtonStyle(kind: .outline, size: 13))
        .opacity(enabled ? 1 : 0.3)
        .disabled(!enabled)
    }

    private var glowButton: some View {
        AmberIconButton(symbol: "sun.max", isActive: glowOpen) {
            withAnimation(.drawer) { glowOpen.toggle() }
        }
    }

    private var closeButton: some View {
        AmberIconButton(symbol: "xmark") {
            // Let go of the keyboard before the cover goes, so it is seen to go down
            // rather than found still standing over whatever is underneath.
            addressFocused = false
            AmberKeyboardInstaller.putAway()
            // An address called up from an app's bar is put back, not the browser: the
            // bar it came from is still there to go back to.
            if editingAddress {
                address = model.currentURL?.absoluteString ?? address
                return
            }
            dismiss()
        }
    }

    private var backButton: some View {
        AmberIconButton(symbol: "chevron.left") { model.web.goBack() }
            .opacity(model.canGoBack ? 1 : 0.3)
            .disabled(!model.canGoBack)
    }

    private var forwardButton: some View {
        AmberIconButton(symbol: "chevron.right") { model.web.goForward() }
            .opacity(model.canGoForward ? 1 : 0.3)
            .disabled(!model.canGoForward)
    }

    /// Whether the site this page is on already has a tile on the front page.
    private var pinnedSite: Site? {
        model.currentURL.flatMap(site(for:))
    }

    /// Keep a door to this site: a tile on the front page, as against the page itself,
    /// which Save keeps. It sits at the head of the address, where the site is named,
    /// and fills once there is a tile — after which it has nothing more to do. While a
    /// page is on its way the same spot shows that instead.
    private var siteMark: some View {
        let pinned = pinnedSite != nil
        let symbol = model.isLoading ? "arrow.triangle.2.circlepath" : (pinned ? "pin.fill" : "pin")
        return Button {
            guard let url = model.currentURL, let host = url.host,
                  let root = URL(string: "\(url.scheme ?? "https")://\(host)") else { return }
            siteDraft = SiteDraft(name: Self.siteName(from: model.pageTitle, host: host),
                                  address: root.absoluteString)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(pinned || model.isLoading ? amber.inkFaint : amber.ink)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(pinned || model.isLoading || model.currentURL == nil)
    }

    /// A name for a site, from what the page calls itself. Titles put the site last,
    /// after a dash or a bar; failing that, the host's own name will do.
    static func siteName(from title: String, host: String) -> String {
        for separator in [" | ", " — ", " – ", " - ", " · ", " • "] {
            if let last = title.components(separatedBy: separator).last,
               last != title {
                let candidate = last.trimmingCharacters(in: .whitespaces)
                if !candidate.isEmpty, candidate.count <= 28 { return candidate }
            }
        }
        if !title.isEmpty, title.count <= 28 { return title }
        var bare = host
        if bare.hasPrefix("www.") { bare.removeFirst(4) }
        let labels = bare.split(separator: ".")
        let name = labels.count >= 2 ? labels[labels.count - 2] : (labels.first ?? Substring(bare))
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    private var saveButton: some View {
        Button(savedFlash ? "Saved" : "Save") { save(openReader: false) }
            .buttonStyle(AmberButtonStyle(kind: .outline, size: 13))
            .disabled(model.currentURL == nil)
    }

    private var readButton: some View {
        Button("Read") { save(openReader: true) }
            .buttonStyle(AmberButtonStyle(kind: .solid, size: 13))
            .disabled(model.currentURL == nil)
    }

    private var addressField: some View {
        HStack(spacing: 6) {
            siteMark
            AmberTextField(text: $address,
                           isFocused: $addressFocused,
                           placeholder: "Search or enter address",
                           palette: settings.palette,
                           showsTexture: settings.showTexture,
                           showsDotCom: true,
                           goLabel: "Go",
                           monospaced: true,
                           fontSize: 13,
                           onSubmit: { model.submit(address) })
                .frame(maxWidth: .infinity)
                .frame(height: 18)
            if model.isLoading {
                Button { model.web.stopLoading() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(amber.inkFaint)
                }
                .buttonStyle(.plain)
            } else if model.currentURL != nil {
                Button { model.web.reload() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundStyle(amber.inkFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(amber.color(0.79))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(amber.rule, lineWidth: 1))
        )
    }

    private func menuActions(for selection: WebSelection) -> [EditAction] {
        var actions: [EditAction] = selection.isEditable ? [.cut, .copy] : [.copy]
        if selection.isEditable, UIPasteboard.general.hasStrings { actions.append(.paste) }
        actions.append(.search)
        return actions
    }

    private func save(openReader: Bool) {
        guard let url = model.currentURL else { return }
        let article = library.add(url: url, title: model.pageTitle.isEmpty ? nil : model.pageTitle)
        if openReader {
            onSaved(article)
            dismiss()
        } else {
            savedFlash = true
            Task {
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                savedFlash = false
            }
        }
    }
}

/// The fullscreen video's side of the screen: its controls over the page, the home
/// indicator put away, and what to do as it comes and goes and as the phone turns.
private struct VideoFullscreenHandling: ViewModifier {
    var model: BrowserModel
    var onLeave: () -> Void
    var onFullscreenChange: (Bool) -> Void
    var onTurn: (UIDeviceOrientation) -> Void

    func body(content: Content) -> some View {
        content
            .persistentSystemOverlays(model.videoFullscreen ? .hidden : .automatic)
            .overlay {
                if model.videoFullscreen {
                    VideoControls(model: model, onLeave: onLeave)
                        .transition(.opacity)
                }
            }
            .onChange(of: model.videoFullscreen) { _, on in onFullscreenChange(on) }
            .onChange(of: model.videoLeaveRequests) { _, _ in onLeave() }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                onTurn(UIDevice.current.orientation)
            }
    }
}

/// The controls over a fullscreen video. The site's own are hidden with the rest of its
/// page, so these stand in for them: a tap on the video brings them up — play or pause,
/// where you are, and the way out — and they go again after a few seconds of playing.
private struct VideoControls: View {
    @Environment(\.amber) private var amber
    var model: BrowserModel
    var onLeave: () -> Void

    @State private var shown = true
    @State private var hideTask: Task<Void, Never>?
    /// Where the scrubber is while a finger is on it, ahead of the video catching up.
    @State private var scrubbing: Double?
    @State private var seekTask: Task<Void, Never>?

    private var video: BrowserModel.VideoState? { model.video }

    var body: some View {
        ZStack {
            // The whole glass answers a tap, shown or not.
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { shown ? hide() : show() }
            if shown {
                amber.color(0.0, opacity: 0.35)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                controls
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.2), value: shown)
        .onAppear { show() }
        .onDisappear { hideTask?.cancel(); seekTask?.cancel() }
        .onChange(of: video?.paused) { _, _ in scheduleHide() }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(action: onLeave) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .foregroundStyle(amber.color(0.93))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Exit full screen")
            }
            Spacer()
            if let video {
                Button { model.toggleVideo(); show() } label: {
                    Image(systemName: video.paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .frame(width: 72, height: 72)
                        .foregroundStyle(amber.color(0.93))
                        .background(Circle().fill(amber.color(0.0, opacity: 0.45)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(video.paused ? "Play" : "Pause")
            }
            Spacer()
            if let video, video.duration > 0 {
                progress(video)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .safeAreaPadding(.all)
    }

    private func progress(_ video: BrowserModel.VideoState) -> some View {
        let time = scrubbing ?? video.time
        return HStack(spacing: 14) {
            Text(Self.clock(time))
                .frame(minWidth: 44, alignment: .trailing)
            VideoScrubber(fraction: video.duration > 0 ? time / video.duration : 0) { f in
                seek(to: f * video.duration)
            }
            Text(Self.clock(video.duration))
                .frame(minWidth: 44, alignment: .leading)
        }
        .font(.system(size: 13, weight: .medium).monospacedDigit())
        .foregroundStyle(amber.color(0.93))
    }

    /// The scrubber's place goes to the video as the finger moves, a few times a
    /// second, and once more where it comes to rest.
    private func seek(to time: Double) {
        let throttled = scrubbing != nil
        scrubbing = time
        show()
        if !throttled { model.seekVideo(to: time) }
        seekTask?.cancel()
        seekTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let at = scrubbing else { return }
            model.seekVideo(to: at)
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            scrubbing = nil
        }
    }

    private func show() {
        shown = true
        scheduleHide()
    }

    private func hide() {
        hideTask?.cancel()
        shown = false
    }

    /// Out of the way after a few seconds, while the video plays and nothing is being
    /// moved. A paused video keeps its controls up.
    private func scheduleHide() {
        hideTask?.cancel()
        guard shown, let video, !video.paused else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, scrubbing == nil else { return }
            shown = false
        }
    }

    private static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

/// Where the video is, as a player draws it: a thin rounded line, filled to here, and
/// a round handle. The whole line takes a touch — anywhere on it jumps there, and a
/// drag carries on from it — and the handle grows while it is held.
private struct VideoScrubber: View {
    @Environment(\.amber) private var amber
    var fraction: Double
    var onChange: (Double) -> Void

    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let f = min(max(fraction, 0), 1)
            let knob: CGFloat = dragging ? 18 : 12
            ZStack(alignment: .leading) {
                Capsule().fill(amber.color(0.93, opacity: 0.3))
                    .frame(height: dragging ? 6 : 4)
                Capsule().fill(amber.color(0.93))
                    .frame(width: max(width * f, 4), height: dragging ? 6 : 4)
                Circle().fill(amber.color(0.95))
                    .frame(width: knob, height: knob)
                    .offset(x: width * f - knob / 2)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragging = true
                        onChange(min(max(value.location.x / width, 0), 1))
                    }
                    .onEnded { _ in dragging = false }
            )
            .animation(.easeOut(duration: 0.12), value: dragging)
        }
        .frame(height: 32)
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue("\(Int((min(max(fraction, 0), 1) * 100).rounded())) percent")
    }
}
