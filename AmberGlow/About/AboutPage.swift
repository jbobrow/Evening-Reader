import SwiftUI

/// The About page, on the whole glass like the highlights: the page all of
/// Jon's apps share, dressed in the amber ink and surfaces this app paints
/// everything else with.
struct AboutPage: View {
    @Environment(\.amber) private var amber
    /// Puts the page away. It is drawn over the page rather than presented (see
    /// `PageCover`), so the environment's `dismiss` has nothing to dismiss.
    var onClose: () -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// The tour, or a version's news, opened over this page.
    @State private var showTour = false
    @State private var whatsNew: WhatsNew?

    private var isCompact: Bool { sizeClass == .compact }
    private let measure: CGFloat = 560

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            AboutView(app: .eveningReader) {
                AboutRow(title: "How it works", systemImage: "questionmark.circle") {
                    showTour = true
                }
                if let latest = WhatsNew.latest {
                    AboutRow(title: "What's new in \(latest.version)", systemImage: "sparkles") {
                        whatsNew = latest
                    }
                }
            }
                .frame(maxWidth: measure)
                .frame(maxWidth: .infinity)
                .environment(\.aboutStyle, AboutStyle(
                    ink: amber.ink,
                    secondaryInk: amber.inkMuted,
                    faintInk: amber.inkFaint,
                    // Outlined cards with the glow showing through them, rather than
                    // solid ones: a flat face stood in front of the lamp, and its edge
                    // came and went with the bloom behind it. Only a breath of the
                    // brightest amber inside, so the rows still read as a group.
                    rowBackground: amber.color(1.0, opacity: 0.18),
                    separator: amber.rule,
                    // Opaque, as the lines between rows lie along it at the top.
                    cardOutline: amber.color(0.66)))
                .tint(amber.ink)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // No ground of its own: it comes up over the page on the page's own lamp.
        .statusBarHidden(true)
        .modifier(PageCover(isPresented: $showTour) {
            OnboardingSheet()
        })
        .modifier(PageCover(isPresented: Binding(
            get: { whatsNew != nil },
            set: { if !$0 { whatsNew = nil } })) {
            if let release = whatsNew ?? WhatsNew.latest { WhatsNewSheet(release: release) }
        })
    }

    private var header: some View {
        HStack {
            Text("About")
                .font(.system(size: isCompact ? 22 : 26, weight: .semibold, design: .serif))
                .foregroundStyle(amber.inkStrong)
            Spacer(minLength: 12)
            AmberIconButton(symbol: "xmark", action: onClose)
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
