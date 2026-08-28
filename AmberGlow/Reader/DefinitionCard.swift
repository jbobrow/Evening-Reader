import SwiftUI
import UIKit

/// The system dictionary, brought onto the ramp.
///
/// `UIReferenceLibraryViewController` is the only way to the dictionary on iOS, and it
/// arrives the way every other piece of system chrome in this app arrived: a white card
/// with no appearance API. The menu, the alert and the edit callout were each answered by
/// drawing the app's own version from the ramp, and that is not available here — the text
/// is the dictionary's and there is no way to read it out and set it ourselves.
///
/// So it is treated as a page rather than as a control, and put through exactly the
/// mapping `PDFReaderView` puts a PDF's pages through: white becomes the page, black
/// becomes ink, and at night the whole thing flips with everything else. The one surface
/// in the app that is somebody else's rendering, wearing the app's light.
private struct DictionaryView: UIViewControllerRepresentable {
    let term: String

    func makeUIViewController(context: Context) -> UIReferenceLibraryViewController {
        let controller = UIReferenceLibraryViewController(term: term)
        controller.view.backgroundColor = .white
        return controller
    }

    func updateUIViewController(_ controller: UIReferenceLibraryViewController, context: Context) {}
}

/// A short definition of one word, over the page it was read on.
///
/// What the dictionary hands over is more than a definition: a bar of its own carrying
/// the word and a close, and — under the entry — rows reading "Search Web" and "Manage
/// Dictionaries". None of it is the app's to take away. The whole controller is a
/// `_UIRemoteView` drawn by another process, so there is no view on this side to hide and
/// no API to decline any of it; the hierarchy was dumped to be sure rather than assumed.
///
/// What the app can do is choose which part of it to show. The card draws its own header
/// and then a window onto the middle of the panel, with both ends falling outside the
/// clip: the dictionary's bar and section label above, its rows below. See `topCrop` and
/// `entryWindow` for where the two cuts land, and what the lower one costs.
struct DefinitionCard: View {
    @Environment(\.amber) private var amber
    @Environment(DisplaySettings.self) private var settings

    let term: String
    /// Nothing in the dictionary. The word can still be looked up on the web.
    var onSearch: () -> Void
    var onClose: () -> Void

    private var hasEntry: Bool {
        UIReferenceLibraryViewController.dictionaryHasDefinition(forTerm: term)
    }

    // MARK: - Where the panel is cut

    /// One line of the system's body text.
    ///
    /// Everything in the panel is set in multiples of it — the bar, the section label,
    /// the headword, each line of sense — so both cuts are counted in it, and both move
    /// with the reader's text size rather than against it.
    private var line: CGFloat { UIFont.preferredFont(forTextStyle: .body).lineHeight }

    /// Down to the headword: past the dictionary's own bar, and past the "Dictionary"
    /// label and the rule under it. What is left at the top of the window is the word
    /// itself, its pronunciation and its part of speech.
    private var topCrop: CGFloat { round(line * 5.55) }

    /// The headword, and four lines under it.
    ///
    /// A ceiling rather than a preference. The rows the dictionary puts at the foot of an
    /// entry — "Search Web", "Manage Dictionaries" — do not sit at the bottom of the
    /// panel: they follow the entry, a fixed gap below wherever it ends, with the unused
    /// height falling below *them*. So the window has to stop short of where they would
    /// land for a one-line entry, which is the shortest there is, and that lands a little
    /// over five lines below the headword.
    ///
    /// Whole lines, so a cut falls between two of them rather than through one. A short
    /// entry leaves the rest as air, and a long one is faded out at the edge; both read
    /// as the card rather than as a hole, because the panel's own page is mapped to
    /// exactly the level the card is filled with. See `pageLevel`.
    private var entryWindow: CGFloat { round(line * 5) }

    /// What the dictionary is given to lay out in. Only has to be more than it needs.
    ///
    /// It cannot be asked for less, and the card cannot be sized to the entry, because
    /// nothing on this side of the process boundary knows how long the entry is. That was
    /// worth being sure about, so it was checked six ways: the view hierarchy holds one
    /// remote scene host and no scroll view; no view in it responds to `contentSize` at
    /// all; every view answers `sizeThatFits` with whatever height it was handed and
    /// `intrinsicContentSize` with none; `preferredContentSize` is a constant (320, 420)
    /// whatever the word; the layer tree is two `CALayerHost`s sized to the host, not to
    /// the content; and both `drawHierarchy` and `layer.render(in:)` come back fully
    /// transparent, so the content cannot even be measured from a bitmap. The one local
    /// view that looked promising — a `FloatingBarContainerView` measuring 72pt, about
    /// the height of the two rows — turned out to be an empty iOS 26 affordance: hiding
    /// it changes nothing on screen.
    private let layoutHeight: CGFloat = 460

    /// Where the panel's white page lands: the card's own fill, so there is no seam
    /// between the two and no edge to the cut. This is the whole of why the crop reads
    /// as a card with padding rather than as a window onto something else.
    private let pageLevel = 0.93

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            card
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var card: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            if hasEntry { entry } else { missing }
        }
        .background {
            ZStack {
                amber.color(pageLevel)
                if settings.showTexture { PixelGrid() }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(amber.color(0.62, opacity: 0.5), lineWidth: 1)
        }
        .shadow(color: amber.color(0.0, opacity: 0.24), radius: 26, y: 8)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(term)
                .font(.system(size: 20, weight: .semibold, design: .serif))
                .foregroundStyle(amber.inkStrong)
                .lineLimit(1)
            Spacer(minLength: 12)
            AmberIconButton(symbol: "xmark", action: onClose)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 10 }
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    /// The window onto the dictionary's own rendering.
    ///
    /// Touches are refused, and not only because scrolling would bring the rows back into
    /// view: nothing inside the window is the app's to offer. The one control it carried
    /// that was worth having — its close — the header above carries instead.
    private var entry: some View {
        DictionaryView(term: term)
            .id(term)
            .frame(height: layoutHeight)
            .offset(y: -topCrop)
            .frame(height: entryWindow, alignment: .top)
            .clipped()
            .allowsHitTesting(false)
            .amberInk(pageLevel: pageLevel, isNight: settings.polarity == .night)
            // An entry longer than the window is let go of rather than sliced: its last
            // line softens into the card instead of ending on a cut edge. Kept to a few
            // points, because the line that usually sits at the foot of the window is the
            // dictionary's own name and it should be readable, not ghosted. Under a short
            // entry there is nothing down there to fade.
            .mask {
                LinearGradient(stops: [.init(color: .black, location: 0),
                                       .init(color: .black, location: 0.94),
                                       .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .padding(.top, 6)
            .padding(.bottom, 16)
    }

    private var missing: some View {
        VStack(spacing: 14) {
            Image(systemName: "character.book.closed")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(amber.inkFaint)
            Text("Not in the dictionary.")
                .font(.system(size: 16, design: .serif))
                .foregroundStyle(amber.inkMuted)
            // A fitted sheet proposes the height it has rather than the height this
            // wants, and a paragraph offered one line's worth takes one line. It has to
            // say it will not be compressed.
            Text("iOS keeps its dictionaries per language, and downloads them on demand. If this looks like an ordinary word, the dictionary for it may not be on this device yet.")
                .font(.system(size: 12.5))
                .lineSpacing(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(amber.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
            Button("Look it up", action: onSearch)
                .buttonStyle(AmberButtonStyle(kind: .outline, size: 14))
                .padding(.top, 2)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 26)
    }
}
