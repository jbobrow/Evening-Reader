import SwiftUI

/// The panel, in two halves: the light the page is lit by, and the type it is set in.
///
/// One long column had both, a dozen controls with the type below the fold. Split, each
/// half fits the glass. The light leads with the one choice that changes everything —
/// paper or night — then the three that set the light itself, warmth, brightness and
/// contrast, and the glows kept from them; the panel's texture is folded away under
/// Advanced. The type leads with the face, then a sample of the page the sliders below
/// it are read against.
struct PanelControls: View {
    @Environment(DisplaySettings.self) private var settings
    @Environment(\.amber) private var amber
    @Environment(\.horizontalSizeClass) private var sizeClass

    enum Tab: String, CaseIterable, Identifiable {
        case light, type
        var id: String { rawValue }
        var label: String { self == .light ? "Light" : "Type" }
    }

    /// The half last looked at, so the panel opens on it again.
    @AppStorage("panel.tab") private var tab: Tab = .light
    @State private var showAdvanced = false

    /// Which line is in the window. Starts somewhere different each time the panel is
    /// opened, then walks the list in order, so "Show another" always gives another and
    /// the reader sees all ten before seeing any twice.
    @State private var quoteIndex = Int.random(in: 0..<SpecimenQuote.all.count)

    /// The column runs from 600 to 860 points, and a phone is narrower than either — the
    /// text already fills the glass, so the control would be a slider that does nothing.
    /// It comes back the moment there is a page wide enough for it to bite on.
    private var showsColumn: Bool { sizeClass != .compact }

    var body: some View {
        VStack(spacing: 0) {
            AmberSegmented(selection: $tab, options: Tab.allCases, label: \.label)
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch tab {
                    case .light: light
                    case .type: type
                    }
                }
                .padding(22)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: - Light

    @ViewBuilder
    private var light: some View {
        HStack(spacing: 10) {
            ForEach(AmberPalette.Polarity.allCases) { polarityTile($0) }
        }
        labelled("Warmth", value: settings.palette.warmthName) {
            AmberSlider(value: Binding(get: { settings.warmth },
                                       set: { settings.warmth = $0 }),
                        leadingSymbol: "lightbulb",
                        trailingSymbol: "flame",
                        trackGradient: Self.warmthTrack(settings))
        }
        labelled("Brightness", value: percent(settings.glow)) {
            AmberSlider(value: Binding(get: { settings.glow },
                                       set: { settings.glow = $0 }),
                        range: 0.05...1,
                        leadingSymbol: "sun.min",
                        trailingSymbol: "sun.max")
        }
        labelled("Contrast", value: percent(settings.contrast)) {
            AmberSlider(value: Binding(get: { settings.contrast },
                                       set: { settings.contrast = $0 }),
                        leadingSymbol: "circle.righthalf.filled",
                        trailingSymbol: "circle.hexagongrid")
        }

        group("Saved glows") {
            if settings.presets.isEmpty {
                Text("Keep a glow you like and it will wait here.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(amber.inkFaint)
            } else {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(settings.presets) { preset in
                        PresetChip(preset: preset,
                                   isActive: settings.matches(preset),
                                   apply: { withAnimation(.easeOut(duration: 0.18)) {
                                       settings.apply(preset)
                                   } },
                                   remove: { withAnimation(.easeOut(duration: 0.18)) {
                                       settings.delete(preset)
                                   } })
                    }
                }
            }

            HStack(spacing: 10) {
                Button(settings.currentIsSaved ? "Saved" : "Save this glow") {
                    withAnimation(.easeOut(duration: 0.18)) { settings.savePreset() }
                }
                .buttonStyle(AmberButtonStyle(kind: .outline, size: 13))
                .disabled(settings.currentIsSaved)

                Spacer()

                AmberIconButton(symbol: "arrow.counterclockwise") {
                    withAnimation(.easeOut(duration: 0.18)) { settings.resetPanel() }
                }
                .opacity(settings.isDefaultPanel ? 0.35 : 1)
                .disabled(settings.isDefaultPanel)
                .accessibilityLabel("Reset to default")
            }
        }

        advanced
    }

    /// Paper or night, each drawn in its own colours: the choice shown rather than named.
    private func polarityTile(_ polarity: AmberPalette.Polarity) -> some View {
        var probe = settings.palette
        probe.polarity = polarity
        let chosen = settings.polarity == polarity
        return Button {
            withAnimation(.easeOut(duration: 0.25)) { settings.polarity = polarity }
        } label: {
            VStack(spacing: 7) {
                Image(systemName: polarity.symbol)
                    .font(.system(size: 20, weight: .medium))
                Text(polarity.label)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(probe.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 78)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(probe.page))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(chosen ? amber.inkStrong : amber.rule, lineWidth: chosen ? 2 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    /// What is set once and rarely again — the panel's texture — folded away under one row.
    @ViewBuilder
    private var advanced: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { showAdvanced.toggle() }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Advanced")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(amber.ink)
                        Text("Pixel grid, backlight bloom")
                            .font(.system(size: 12))
                            .foregroundStyle(amber.inkFaint)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(amber.inkFaint)
                        .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                }
                .padding(.top, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .top) { Hairline() }

            if showAdvanced {
                VStack(alignment: .leading, spacing: 18) {
                    AmberToggle(isOn: Binding(get: { settings.showTexture },
                                              set: { settings.showTexture = $0 }),
                                title: "Pixel grid")
                    AmberToggle(isOn: Binding(get: { settings.showBloom },
                                              set: { settings.showBloom = $0 }),
                                title: "Backlight bloom")
                    ramp
                }
                .transition(.opacity)
            }
        }
    }

    // MARK: - Type

    @ViewBuilder
    private var type: some View {
        group("Typeface") {
            HStack(spacing: 8) {
                ForEach(DisplaySettings.Typeface.allCases) { faceTile($0) }
            }
        }
        specimen
        labelled("Size", value: String(format: "%.0f pt", settings.bodyPointSize)) {
            AmberSlider(value: Binding(get: { settings.textScale },
                                       set: { settings.textScale = $0 }),
                        range: 0.8...1.9,
                        ticks: 7,
                        leadingSymbol: "textformat.size.smaller",
                        trailingSymbol: "textformat.size.larger")
        }
        labelled("Leading", value: String(format: "%.2f", settings.lineHeight)) {
            AmberSlider(value: Binding(get: { settings.lineHeight },
                                       set: { settings.lineHeight = $0 }),
                        range: 1.25...2.05,
                        leadingSymbol: "arrow.up.and.down.text.horizontal",
                        trailingSymbol: "arrow.up.and.down")
        }
        if showsColumn {
            labelled("Column", value: String(format: "%.0f pt", settings.readerColumnPoints)) {
                AmberSlider(value: Binding(get: { settings.measure },
                                           set: { settings.measure = $0 }),
                            leadingSymbol: "arrow.right.and.line.vertical.and.arrow.left",
                            trailingSymbol: "arrow.left.and.line.vertical.and.arrow.right")
            }
        }
    }

    /// Each face shown in itself.
    private func faceTile(_ face: DisplaySettings.Typeface) -> some View {
        let chosen = settings.typeface == face
        return Button {
            withAnimation(.easeOut(duration: 0.18)) { settings.typeface = face }
        } label: {
            VStack(spacing: 2) {
                Text("Ag")
                    .font(.system(size: 24, design: face.design))
                Text(face.label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(amber.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(chosen ? amber.color(0.93, opacity: 0.6) : .clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(chosen ? amber.inkStrong : amber.rule, lineWidth: chosen ? 2 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    // MARK: - Pieces

    /// A window onto the page, under the controls that set it.
    ///
    /// The panel covers the page it is describing — on a phone entirely — so "17 pt" and
    /// "1.62" have nothing to refer to while they are being moved. This is the page in
    /// miniature: the same ramp, the same size, leading and face, so a change can be read
    /// here rather than guessed at and checked once the panel is out of the way.
    ///
    /// It answers to the glow controls as well as the type ones, since every colour in it
    /// comes from the same palette. That is worth having and costs nothing.
    private var specimen: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                AmberCaption(text: "Sample")
                Spacer()
                Button("Show another") {
                    withAnimation(.easeOut(duration: 0.2)) {
                        quoteIndex = (quoteIndex + 1) % SpecimenQuote.all.count
                    }
                }
                .buttonStyle(AmberButtonStyle(kind: .quiet, size: 12))
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(quote.text)
                    .font(.system(size: settings.bodyPointSize,
                                  design: settings.typeface.design))
                    .lineSpacing(specimenLineSpacing)
                    .foregroundStyle(amber.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    // Four lines is enough to judge a face and its leading, and keeps the
                    // window a window: the longest of these at 32pt runs to eight, which
                    // is no longer a sample of the page so much as a page.
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, minHeight: specimenTextHeight,
                           alignment: .topLeading)
                    .contentTransition(.opacity)

                // Set the way the reader sets a byline, so the window reads as a small
                // page rather than as a swatch with a caption.
                Text(quote.credit)
                    .font(.system(size: 10, weight: .medium))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(amber.inkMuted)
                    .contentTransition(.opacity)
            }
            .padding(16)
            .background {
                ZStack {
                    amber.color(0.88)
                    if settings.showTexture { PixelGrid() }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(amber.rule, lineWidth: 1)
            }
        }
    }

    private var quote: SpecimenQuote { SpecimenQuote.all[quoteIndex] }

    /// Four lines of the face at its current size, held whatever the quote is. The lines
    /// run from two to four, and a pane that resizes every time it is refilled is not a
    /// window.
    private var specimenTextHeight: CGFloat {
        let font = settings.typeface.uiFont(size: settings.bodyPointSize)
        return font.lineHeight * 4 + specimenLineSpacing * 3
    }

    /// SwiftUI's `lineSpacing` is the gap *added* between lines; the reader's CSS
    /// `line-height` is the whole line box. Taking the face's own line height off the one
    /// gives the other, so the specimen is leaded like the page rather than merely near
    /// it — which matters, since leading is one of the things it is here to show.
    private var specimenLineSpacing: CGFloat {
        let size = settings.bodyPointSize
        let natural = settings.typeface.uiFont(size: size).lineHeight
        return max(0, size * settings.lineHeight - natural)
    }


    /// The whole palette, end to end — the ramp every color in the app comes from.
    private var ramp: some View {
        VStack(alignment: .leading, spacing: 8) {
            AmberCaption(text: "The ramp")
            HStack(spacing: 0) {
                ForEach(0..<13, id: \.self) { i in
                    amber.color(Double(i) / 12.0)
                        .frame(height: 34)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(amber.rule, lineWidth: 1))
            .overlay(alignment: .leading) {
                Text("ink")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(amber.color(0.85))
                    .padding(.leading, 7)
            }
            .overlay(alignment: .trailing) {
                Text("glow")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(amber.color(0.08))
                    .padding(.trailing, 7)
            }
        }
    }

    static func warmthTrack(_ settings: DisplaySettings) -> LinearGradient {
        // Show the choice itself: the glow rendered across the warmth range. The glow is
        // the page on paper and the type at night — at night the page is near black at
        // every warmth, and a track drawn from it was a black bar with nothing to choose.
        let level = settings.polarity == .night ? 0.0 : 0.86
        let stops = stride(from: 0.0, through: 1.0, by: 0.1).map { t -> Color in
            var probe = settings.palette
            probe.warmth = t
            return probe.color(level)
        }
        return LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing)
    }

    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    @ViewBuilder
    private func group<Content: View>(_ title: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            AmberCaption(text: title)
            content()
        }
    }

    @ViewBuilder
    private func labelled<Content: View>(_ title: String, value: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(amber.ink)
                Spacer()
                Text(value)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(amber.inkFaint)
            }
            content()
        }
    }
}

/// The lines the specimen is set in.
///
/// This is the one piece of writing in the app that is the app's own choice rather than
/// the reader's, so it should be worth meeting: ten that lift rather than merely fill the
/// space. All are from women whose work is long out of copyright, which is what makes
/// them ours to ship — the tempting modern ones are not.
struct SpecimenQuote {
    let text: String
    let credit: String

    static let all: [SpecimenQuote] = [
        SpecimenQuote(
            text: "Lock up your libraries if you like; but there is no gate, no lock, no bolt that you can set upon the freedom of my mind.",
            credit: "Virginia Woolf · A Room of One's Own"),
        SpecimenQuote(
            text: "Isn't it nice to think that tomorrow is a new day with no mistakes in it yet?",
            credit: "L. M. Montgomery · Anne of Green Gables"),
        SpecimenQuote(
            text: "There are two ways of spreading light: to be the candle or the mirror that reflects it.",
            credit: "Edith Wharton · Vesalius in Zante"),
        SpecimenQuote(
            text: "If you look the right way, you can see that the whole world is a garden.",
            credit: "Frances Hodgson Burnett · The Secret Garden"),
        SpecimenQuote(
            text: "I am not afraid of storms, for I am learning how to sail my ship.",
            credit: "Louisa May Alcott · Little Women"),
        SpecimenQuote(
            text: "I am no bird; and no net ensnares me: I am a free human being with an independent will.",
            credit: "Charlotte Brontë · Jane Eyre"),
        SpecimenQuote(
            text: "What do we live for, if it is not to make life less difficult to each other?",
            credit: "George Eliot · Middlemarch"),
        SpecimenQuote(
            text: "That is happiness; to be dissolved into something complete and great.",
            credit: "Willa Cather · My Ántonia"),
        SpecimenQuote(
            text: "She was becoming herself and daily casting aside that fictitious self which we assume like a garment with which to appear before the world.",
            credit: "Kate Chopin · The Awakening"),
        SpecimenQuote(
            text: "I declare after all there is no enjoyment like reading! How much sooner one tires of any thing than of a book!",
            credit: "Jane Austen · Pride and Prejudice")
    ]
}
