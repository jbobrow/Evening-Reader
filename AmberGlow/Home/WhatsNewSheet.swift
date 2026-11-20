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

    /// A version, or just its major and minor, so that a 1.2.2 with no entry of its own
    /// still shows what 1.2 brought.
    let version: String
    /// Whether this release is the one that brought the tour, so the reader is offered it.
    var offersTour = false
    var items: [Item]

    var id: String { version }

    /// Every version with something to show, newest first. A version with no entry shows
    /// nothing. A point release's entry carries the news of the earlier releases of its
    /// minor version; see `gathered`.
    static let releases: [WhatsNew] = [
        WhatsNew(version: "1.2.1", items: [
            Item(symbol: "character.book.closed.zh",
                 title: String(localized: "In Traditional Chinese"),
                 body: String(localized: "When your iPhone reads in Traditional Chinese, so does Evening Reader: every menu, panel and page of it, the tour, and Save to Evening Reader in the share sheet. What you read stays in the language it was written in.")),
        ]),
        WhatsNew(version: "1.2", items: [
            Item(symbol: "sun.max",
                 title: String(localized: "The glow, over the page"),
                 body: String(localized: "Display settings come up short over the page you're reading, so a change is seen on the real thing. Pull up for everything, now in two tabs, Light and Type.")),
            Item(symbol: "folder",
                 title: String(localized: "Your library as notes"),
                 body: String(localized: "Each article is a Markdown note with its pictures and highlights beside it, so the library opens as an Obsidian vault.")),
            Item(symbol: "keyboard",
                 title: String(localized: "Accents and dictation"),
                 body: String(localized: "Hold a key for its accents, and tap the mic to speak instead of type.")),
            Item(symbol: "play.rectangle",
                 title: String(localized: "Video, full screen"),
                 body: String(localized: "A video fills the glass in either orientation, with simple controls of its own.")),
            Item(symbol: "book",
                 title: String(localized: "iPhone Duo"),
                 body: String(localized: "Opened sideways, an article is set as a two-page spread. Folded shut, the buttons stand beside the camera, or the page takes the whole width.")),
        ]),
        WhatsNew(version: "1.1.1", offersTour: true, items: [
            Item(symbol: "book.pages",
                 title: String(localized: "A tour of Evening Reader"),
                 body: String(localized: "How a page gets here from Safari or any other app, how to set the glow, and how to keep a passage. Shown to new readers, and any time from About.")),
            Item(symbol: "signature",
                 title: String(localized: "About"),
                 body: String(localized: "The signature at the foot of the front page opens About, with the website, support, and the tour.")),
            Item(symbol: "globe",
                 title: String(localized: "Steadier sites"),
                 body: String(localized: "In the browser, the bar stays put on anything that isn't an article, and a site you keep as an app gets a single row with its name.")),
            Item(symbol: "doc.on.clipboard",
                 title: String(localized: "Paste on a tap"),
                 body: String(localized: "Tap into an empty field and Paste is offered right there.")),
        ]),
    ]

    static var currentVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    private static var currentIndex: Int? {
        guard let currentVersion else { return nil }
        return releases.firstIndex { currentVersion == $0.version || currentVersion.hasPrefix($0.version + ".") }
    }

    /// This version's entry, if it has one.
    static var current: WhatsNew? { currentIndex.map { gathered(from: $0) } }

    /// The newest entry, for About.
    static var latest: WhatsNew? { releases.isEmpty ? nil : gathered(from: 0) }

    private static let shownKey = "whatsNew.lastShown"

    /// This version's entry, if this device hasn't been shown it yet — with only what is
    /// new since the entry it was last shown.
    static var unseen: WhatsNew? {
        let shown = UserDefaults.standard.string(forKey: shownKey)
        guard let currentIndex, releases[currentIndex].version != shown else { return nil }
        return gathered(from: currentIndex, after: shown)
    }

    /// The entry at `index`, followed by the news of the earlier releases of its minor
    /// version, back to the one last `shown`. So 1.2.1 in About still has everything 1.2
    /// brought, and so does 1.2.1 for someone updating straight from 1.1, while someone
    /// who already read 1.2's news is told only what came after.
    private static func gathered(from index: Int, after shown: String? = nil) -> WhatsNew {
        var release = releases[index]
        for earlier in releases.dropFirst(index + 1) {
            guard minor(of: earlier.version) == minor(of: release.version),
                  earlier.version != shown else { break }
            release.items += earlier.items
            release.offersTour = release.offersTour || earlier.offersTour
        }
        return release
    }

    /// A version's major and minor: 1.2 for 1.2.1.
    private static func minor(of version: String) -> String {
        version.split(separator: ".").prefix(2).joined(separator: ".")
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

    /// How deep the page fades away above the footer.
    private let footFade: CGFloat = 36

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
                // As deep as the fade, so the last line comes clear of it at the end.
                .padding(.bottom, footFade)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            // What is still to come goes soft above the button, rather than being cut off.
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: footFade)
                }
            }

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
