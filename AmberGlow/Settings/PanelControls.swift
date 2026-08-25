import SwiftUI

/// The panel. Everything about the light first — warmth, glow, contrast, polarity, the
/// lattice and the bloom, and the glows kept from them — then, past a rule, the type the
/// page is set in.
struct PanelControls: View {
    @Environment(DisplaySettings.self) private var settings
    @Environment(\.amber) private var amber
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// The column runs from 600 to 860 points, and a phone is narrower than either — the
    /// text already fills the glass, so the control would be a slider that does nothing.
    /// It comes back the moment there is a page wide enough for it to bite on.
    private var showsColumn: Bool { sizeClass != .compact }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ramp

                group("Glow") {
                    labelled("Warmth",
                             value: settings.palette.warmthName) {
                        AmberSlider(value: Binding(get: { settings.warmth },
                                                   set: { settings.warmth = $0 }),
                                    leadingSymbol: "lightbulb",
                                    trailingSymbol: "flame",
                                    trackGradient: warmthTrack)
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
                    AmberSegmented(selection: Binding(get: { settings.polarity },
                                                      set: { settings.polarity = $0 }),
                                   options: AmberPalette.Polarity.allCases,
                                   label: \.label,
                                   symbol: { $0.symbol })

                    // The lattice and the bloom are part of what the panel is lit like,
                    // not a category of their own — under their own "Panel" heading they
                    // read as a third thing the app does.
                    AmberToggle(isOn: Binding(get: { settings.showTexture },
                                              set: { settings.showTexture = $0 }),
                                title: "Pixel grid")
                    AmberToggle(isOn: Binding(get: { settings.showBloom },
                                              set: { settings.showBloom = $0 }),
                                title: "Backlight bloom")
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

                // The one division worth drawing. Everything above is the glow — the
                // lamp, its texture, and the glows kept from it; below is what the page
                // is set in. A rule and a wider gap say that, where four evenly spaced
                // headings said only that there were four of them.
                Hairline()
                    .padding(.vertical, 8)

                group("Type") {
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
                    AmberSegmented(selection: Binding(get: { settings.typeface },
                                                      set: { settings.typeface = $0 }),
                                   options: DisplaySettings.Typeface.allCases,
                                   label: \.label)
                }
            }
            .padding(22)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Pieces

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

    private var warmthTrack: LinearGradient {
        // Show the choice itself: the same page level rendered across the warmth range.
        let stops = stride(from: 0.0, through: 1.0, by: 0.1).map { t -> Color in
            var probe = settings.palette
            probe.warmth = t
            return probe.color(0.86)
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
