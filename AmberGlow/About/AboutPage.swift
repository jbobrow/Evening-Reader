import SwiftUI

/// The About page, on the whole glass like the highlights: the page all of
/// Jon's apps share, dressed in the amber ink and surfaces this app paints
/// everything else with.
struct AboutPage: View {
    @Environment(\.amber) private var amber
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var isCompact: Bool { sizeClass == .compact }
    private let measure: CGFloat = 560

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            AboutView(app: .eveningReader) {}
                .frame(maxWidth: measure)
                .frame(maxWidth: .infinity)
                .environment(\.aboutStyle, AboutStyle(
                    ink: amber.ink,
                    secondaryInk: amber.inkMuted,
                    faintInk: amber.inkFaint,
                    rowBackground: amber.pageRaised,
                    separator: amber.rule))
                .tint(amber.ink)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GlowSurface(level: 0.9))
        .statusBarHidden(true)
    }

    private var header: some View {
        HStack {
            Text("About")
                .font(.system(size: isCompact ? 22 : 26, weight: .semibold, design: .serif))
                .foregroundStyle(amber.inkStrong)
            Spacer(minLength: 12)
            AmberIconButton(symbol: "xmark") { dismiss() }
        }
        .frame(maxWidth: measure)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, isCompact ? 18 : 26)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }
}

extension AboutApp {
    static let eveningReader = AboutApp(
        name: "Evening Reader",
        icon: Image("AppIconImage"),
        description: "Save articles, books and PDFs, then read them on a single warm glow you "
            + "set yourself. Offline, in your own iCloud folders, for the last hour of the day.",
        website: URL(string: "https://eveningreader.jonbobrow.com"),
        support: URL(string: "https://eveningreader.jonbobrow.com/support.html"),
        privacy: URL(string: "https://eveningreader.jonbobrow.com/privacy.html"))
}
