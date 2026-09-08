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

    let initialURL: URL?
    var onSaved: (SavedArticle) -> Void

    @State private var model = BrowserModel()
    @State private var address = ""
    @State private var savedFlash = false
    @State private var addressFocused = false
    /// This site, on its way to the front page.
    @State private var siteDraft: SiteDraft?
    /// The display settings, over the page.
    @State private var glowOpen = false
    /// Height of the page area, so the scrubber can size its track to it.
    @State private var pageHeight: CGFloat = 0
    /// How much room the scrubber is taking, so the ground under it can match.
    @State private var scrubberHeight: CGFloat = 0

    var body: some View {
        // The page keeps the safe area it always had. Only the strip and its ground
        // reach into the band above it, and they are the one thing here that ignores
        // the inset.
        ZStack(alignment: .top) {
            pane
            if model.appMode, !model.chromeHidden {
                StripGround(height: Self.groundHeight)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .ignoresSafeArea(.container, edges: .top)
                    .transition(.opacity)
                appStrip
                    .frame(maxWidth: .infinity, alignment: .top)
                    .ignoresSafeArea(.container, edges: .top)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.22), value: model.chromeHidden)
        .animation(.easeOut(duration: 0.22), value: model.appMode)
        .background(GlowSurface(level: 0.88))
        .overlay {
            // The reader outside the condition, so it is the panel itself that comes
            // and goes — and the panel's own transition, up from the bottom on a phone,
            // is the one that plays. Conditional on the reader, the reader was what
            // appeared, and it only knows how to fade.
            GeometryReader { geo in
                if glowOpen {
                    GlowPanelOverlay(isCompact: isCompact, alignment: .topTrailing,
                                     top: 54, size: geo.size) {
                        withAnimation(.drawer) { glowOpen = false }
                    }
                }
            }
            .allowsHitTesting(glowOpen)
        }
        .statusBarHidden(true)
        .modifier(AmberItemPresentation(isCompact: isCompact, item: $siteDraft) { draft in
            NewSiteSheet(draft: draft)
        })
        .onAppear {
            model.applyTint(showGrid: settings.showTexture, isNight: isNight)
            if let initialURL {
                address = initialURL.absoluteString
                model.isAppSite = site(for: initialURL) != nil
                model.chromeHidden = model.isAppSite
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
            // The bar goes away as the page is read down and comes back as it is read
            // up, or on a tap — the same room the reader gives a page. On one of the
            // reader's own sites it is not the bar that comes back but the strip.
            if !model.chromeHidden, !model.appMode {
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
                            }
                        }
                    }
                    // Run to the physical bottom of the glass; otherwise the page stops at
                    // the home-indicator inset and leaves a ledge.
                    .ignoresSafeArea(.container, edges: .bottom)

                if model.pageCount > 1 {
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
    }

    /// What a site kept as an app gets on a tap: a way out, a way back when there is
    /// one, and the lamp — in the band above the page, so the page is never covered.
    ///
    /// Set beside the cutout, on the page itself, with the page's own surface solid
    /// behind the buttons and fading out beneath them, so they present on the content
    /// rather than cut into it — the same treatment the scrubber gets at the other
    /// corner.
    private var appStrip: some View {
        HStack(spacing: 4) {
            closeButton
            if model.canGoBack {
                AmberIconButton(symbol: "chevron.left") { model.web.goBack() }
            }
            Spacer()
            glowButton
        }
        // Well in from the corners, whose radius comes a long way down the glass.
        .padding(.horizontal, 18)
        .padding(.top, Self.stripTop)
    }

    /// Where the strip's buttons start. Level with the cutout's lower half on a phone,
    /// so they sit in the solid part of the ground with the fade running out below
    /// them; a little in from the edge on a glass with no cutout at all.
    private static var stripTop: CGFloat { max(topInset - 24, 14) }

    /// How far the ground reaches: solid behind the buttons, fading out beneath them.
    private static var groundHeight: CGFloat { max(topInset, 24) + 92 }

    /// How much of the top the cutout keeps clear, from the window itself. Read there
    /// rather than from the layout: what SwiftUI reports inside a presented cover has
    /// come back as zero on the way in, and the window always knows.
    private static var topInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.safeAreaInsets.top ?? 0
    }

    /// The site a page belongs to, if it is one of the reader's own.
    private func site(for url: URL) -> Site? {
        guard let host = url.host else { return nil }
        return sites.site(forHost: host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
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
        if isCompact {
            VStack(spacing: 8) {
                HStack(spacing: 4) {
                    closeButton
                    addressField
                    glowButton
                }
                HStack(spacing: 8) {
                    travelChip(symbol: "chevron.left", enabled: model.canGoBack) { model.web.goBack() }
                    travelChip(symbol: "chevron.right", enabled: model.canGoForward) { model.web.goForward() }
                    Spacer(minLength: 12)
                    if model.isSaveable {
                        saveButton
                        readButton
                    }
                }
            }
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

/// The ground under the app strip: the panel's own surface, fading out below the
/// buttons so they sit on the page the way the scrubber sits on it — presented gently
/// on top of the content, rather than a bar cut across it.
private struct StripGround: View {
    /// How far down the fade reaches, from the very top of the glass.
    var height: CGFloat

    var body: some View {
        GlowSurface()
            .compositingGroup()
            .mask(alignment: .top) {
                LinearGradient(stops: [
                    .init(color: .white, location: 0),
                    .init(color: .white, location: 0.5),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
                .frame(height: height)
            }
            .allowsHitTesting(false)
    }
}
