import SwiftUI

/// A minimal browser for finding things to read. Live pages are collapsed to luminance
/// and re-lit with the same amber ramp as the rest of the app.
struct BrowseScreen: View {
    @Environment(Library.self) private var library
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
    /// Height of the page area, so the scrubber can size its track to it.
    @State private var pageHeight: CGFloat = 0
    /// How much room the scrubber is taking, so the ground under it can match.
    @State private var scrubberHeight: CGFloat = 0

    var body: some View {
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
                                    actions: menuActions(for: selection)
                                ) { action in
                                    WebEditor.perform(action, on: model, selection: selection,
                                                      search: { model.submit($0) })
                                    model.selection = nil
                                }
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
        .background(GlowSurface(level: 0.88))
        .statusBarHidden(true)
        .onAppear {
            model.applyTint(showGrid: settings.showTexture)
            if let initialURL {
                address = initialURL.absoluteString
                model.load(initialURL)
            } else {
                addressFocused = true
            }
        }
        .onChange(of: settings.showTexture) { _, grid in
            model.applyTint(showGrid: grid)
            WebKeyboardBridge.shared.refresh(palette: settings.palette, showsTexture: grid)
        }
        .onChange(of: settings.palette) { _, palette in
            WebKeyboardBridge.shared.refresh(palette: palette, showsTexture: settings.showTexture)
        }
        .onChange(of: model.currentURL) { _, url in
            guard !addressFocused, let url else { return }
            address = url.absoluteString
        }
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

    /// Seven controls and an address field do not fit across a phone. On a narrow panel
    /// the row splits in two: the field gets the top line to itself, and the travel and
    /// save controls sit under it, pushed to the ends they belong to.
    @ViewBuilder
    private var bar: some View {
        if isCompact {
            VStack(spacing: 8) {
                HStack(spacing: 4) {
                    closeButton
                    addressField
                }
                HStack(spacing: 4) {
                    backButton
                    forwardButton
                    Spacer(minLength: 12)
                    saveButton
                    readButton
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        } else {
            HStack(spacing: 4) {
                closeButton
                backButton
                forwardButton
                addressField
                saveButton
                readButton
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    private var closeButton: some View {
        AmberIconButton(symbol: "xmark") { dismiss() }
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
        HStack(spacing: 8) {
            Image(systemName: model.isLoading ? "arrow.triangle.2.circlepath" : "lock")
                .font(.system(size: 11))
                .foregroundStyle(amber.inkFaint)
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
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
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
