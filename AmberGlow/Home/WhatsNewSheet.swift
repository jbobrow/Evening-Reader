import SwiftUI

/// What a version brings.
///
/// Most updates arrive on their own, overnight, so a reader who updated has no way of
/// hearing what changed unless the app tells them. It does, once: the first launch of a
/// version that has an entry here, and only for someone who was reading before it. A
/// new reader is given the tour instead, which already covers it. It can be asked for
/// again from About.
struct WhatsNew: Identifiable {
    struct Item: Identifiable {
        let symbol: String
        let title: String
        let body: String

        var id: String { title }
    }

    /// A version, or just its major and minor, so that a 1.2.1 still shows what 1.2
    /// brought.
    let version: String
    /// Whether this release is the one that brought the tour, so the reader is offered it.
    var offersTour = false
    let items: [Item]

    var id: String { version }

    /// Every version with something to show, newest first. A version with no entry shows
    /// nothing.
    static let releases: [WhatsNew] = [
        WhatsNew(version: "1.2", items: [
            Item(symbol: "sun.max",
                 title: "The glow, over the page",
                 body: "Display settings come up short over the page you're reading, so a change is seen on the real thing. Pull up for everything, now in two tabs, Light and Type."),
            Item(symbol: "folder",
                 title: "Your library as notes",
                 body: "Each article is a Markdown note with its pictures and highlights beside it, so the library opens as an Obsidian vault."),
            Item(symbol: "keyboard",
                 title: "Accents and dictation",
                 body: "Hold a key for its accents, and tap the mic to speak instead of type."),
            Item(symbol: "play.rectangle",
                 title: "Video, full screen",
                 body: "A video fills the glass in either orientation, with simple controls of its own."),
            Item(symbol: "book",
                 title: "iPhone Duo",
                 body: "Opened sideways, an article is set as a two-page spread. Folded shut, the buttons stand beside the camera, or the page takes the whole width."),
        ]),
        WhatsNew(version: "1.1.1", offersTour: true, items: [
            Item(symbol: "book.pages",
                 title: "A tour of Evening Reader",
                 body: "How a page gets here from Safari or any other app, how to set the glow, and how to keep a passage. Shown to new readers, and any time from About."),
            Item(symbol: "signature",
                 title: "About",
                 body: "The signature at the foot of the front page opens About, with the website, support, and the tour."),
            Item(symbol: "globe",
                 title: "Steadier sites",
                 body: "In the browser, the bar stays put on anything that isn't an article, and a site you keep as an app gets a single row with its name."),
            Item(symbol: "doc.on.clipboard",
                 title: "Paste on a tap",
                 body: "Tap into an empty field and Paste is offered right there."),
        ]),
    ]

    static var currentVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// This version's entry, if it has one.
    static var current: WhatsNew? {
        guard let currentVersion else { return nil }
        return releases.first { currentVersion == $0.version || currentVersion.hasPrefix($0.version + ".") }
    }

    /// The newest entry, for About.
    static var latest: WhatsNew? { releases.first }

    private static let shownKey = "whatsNew.lastShown"

    /// This version's entry, if this device hasn't been shown it yet.
    static var unseen: WhatsNew? {
        guard let current, current.version != UserDefaults.standard.string(forKey: shownKey) else { return nil }
        return current
    }

    /// Marks this version's entry as shown — when it is put up, so it never comes back
    /// however it is closed, or when the tour has been shown in its place. Kept per
    /// device, like the tour.
    static func markSeen() {
        guard let current else { return }
        UserDefaults.standard.set(current.version, forKey: shownKey)
    }
}

/// The version's news, on the whole glass like the tour, in the tour's type.
struct WhatsNewSheet: View {
    let release: WhatsNew

    @Environment(DisplaySettings.self) private var settings

    var body: some View {
        // The palette is set once at the root; see OnboardingSheet.
        WhatsNewPage(release: release)
            .environment(\.amber, settings.palette)
    }
}

private struct WhatsNewPage: View {
    let release: WhatsNew

    @Environment(\.amber) private var amber
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closePage) private var closePage
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Taking the tour swaps this page for it, so finishing the tour closes both.
    @State private var takingTour = false

    private var isCompact: Bool { sizeClass == .compact }

    var body: some View {
        ZStack {
            if takingTour {
                OnboardingSheet()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                news
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Its own ground only when the system presents it; see `OnboardingPages`.
        .background { if closePage == nil { GlowSurface(level: 0.9) } }
        .statusBarHidden(true)
    }

    private var news: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    AmberCaption(text: "Evening Reader \(release.version)")
                    Text("What's new")
                        .font(.system(size: isCompact ? 30 : 34, weight: .semibold, design: .serif))
                        .foregroundStyle(amber.inkStrong)
                        .padding(.top, 10)

                    VStack(alignment: .leading, spacing: 26) {
                        ForEach(release.items) { item in
                            row(item)
                        }
                    }
                    .padding(.top, isCompact ? 30 : 36)
                }
                .frame(maxWidth: 460, alignment: .leading)
                .padding(.horizontal, isCompact ? 26 : 32)
                .padding(.top, isCompact ? 46 : 80)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)

            footer
        }
    }

    private func row(_ item: WhatsNew.Item) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: item.symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(amber.ink)
                .frame(width: 30)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.system(size: 18, weight: .semibold, design: .serif))
                    .foregroundStyle(amber.inkStrong)
                Text(item.body)
                    .font(.system(size: 15, design: .serif))
                    .lineSpacing(3)
                    .foregroundStyle(amber.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        HStack {
            if release.offersTour {
                Button("Take the tour") {
                    withAnimation(.drawer) { takingTour = true }
                }
                .buttonStyle(AmberButtonStyle(kind: .outline))
            }
            Spacer()
            Button("Continue") { if let closePage { closePage() } else { dismiss() } }
                .buttonStyle(AmberButtonStyle(kind: .solid))
        }
        .frame(maxWidth: 460)
        .padding(.horizontal, isCompact ? 26 : 32)
        .padding(.bottom, 24)
        .padding(.top, 12)
        .frame(maxWidth: .infinity)
    }
}
