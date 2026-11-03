import SwiftUI

/// The display settings as they first come up on a phone: short, over the page being
/// read, so a change is seen on the real page and not on a sample of it.
///
/// Only what is reached for while reading — paper or night, how warm, how bright, how
/// big — and nothing named that the control itself already shows. The rest is one drag
/// or one tap away, the same page opening the whole way.
struct QuickPanel: View {
    @Environment(DisplaySettings.self) private var settings
    @Environment(\.amber) private var amber
    @Environment(\.expandPage) private var expandPage

    /// One point of type a press. The slider on the full page runs from 0.8 to 1.9 of 17.
    private let sizeStep = 1.0 / 17.0
    private let sizeRange = 0.8...1.9

    var body: some View {
        VStack(spacing: 20) {
            Capsule()
                .fill(amber.rule)
                .frame(width: 36, height: 5)
                .padding(.top, 8)

            HStack(spacing: 12) {
                AmberSegmented(selection: Binding(get: { settings.polarity },
                                                  set: { p in withAnimation(.easeOut(duration: 0.25)) { settings.polarity = p } }),
                               options: AmberPalette.Polarity.allCases,
                               label: \.label,
                               symbol: { $0.symbol })
                sizeStepper
            }
            .pullsPage()

            // In the full panel's order, so a hand that knows one knows the other.
            AmberSlider(value: Binding(get: { settings.warmth },
                                       set: { settings.warmth = $0 }),
                        leadingSymbol: "lightbulb",
                        trailingSymbol: "flame",
                        trackGradient: PanelControls.warmthTrack(settings))
                .accessibilityLabel("Warmth")

            AmberSlider(value: Binding(get: { settings.glow },
                                       set: { settings.glow = $0 }),
                        range: 0.05...1,
                        leadingSymbol: "sun.min",
                        trailingSymbol: "sun.max")
                .accessibilityLabel("Brightness")

            Button {
                expandPage?()
            } label: {
                HStack {
                    Text("All settings")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(amber.ink)
                    Spacer()
                    Image(systemName: "chevron.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(amber.inkFaint)
                }
                .padding(.top, 14)
                .padding(.bottom, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .top) { Hairline() }
            .pullsPage()
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 8)
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { height = $0 }
        .preference(key: PageCoverHeight.self, value: height)
    }

    @State private var height: CGFloat = 0

    /// A smaller A and a larger one, the size between them.
    private var sizeStepper: some View {
        HStack(spacing: 0) {
            step("A", size: 13, by: -sizeStep, label: "Smaller text")
            Text(String(format: "%.0f", settings.bodyPointSize))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(amber.inkFaint)
                .frame(width: 26)
                .contentTransition(.numericText())
            step("A", size: 19, by: sizeStep, label: "Larger text")
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(amber.fill)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(amber.rule, lineWidth: 1)
                )
        )
    }

    private func step(_ glyph: String, size: CGFloat, by delta: Double, label: String) -> some View {
        let next = settings.textScale + delta
        let enabled = next >= sizeRange.lowerBound - 0.001 && next <= sizeRange.upperBound + 0.001
        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                settings.textScale = min(sizeRange.upperBound, max(sizeRange.lowerBound, next))
            }
        } label: {
            Text(glyph)
                .font(.system(size: size, weight: .medium, design: settings.typeface.design))
                .foregroundStyle(amber.ink)
                .frame(width: 40, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }
}
