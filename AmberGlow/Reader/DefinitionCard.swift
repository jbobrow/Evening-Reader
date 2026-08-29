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

/// What the panel's own layout comes to, which is not the same everywhere.
///
/// The bar above the entry, and the margin down its left, belong to the dictionary
/// rather than to the app, and the process that draws them has changed its mind about
/// both — the bar is a different height on iOS 26 than it was on 17, and was a different
/// height again on an iPad than on an iPhone before that. Nothing on this side of the
/// process boundary reports either measure, so they are constants.
///
/// They are measured constants, not guesses: each was read off the running panel at two
/// text sizes and two card widths, on the OS named. To re-measure after an OS that moves
/// them again, set `DefinitionCard.topCrop` to 0 and its window to `layoutHeight`, and
/// see where the headword's line box lands under the card's own hairline.
///
/// What is *not* here is anything for iOS 18 through 25, which were not measured. They
/// take the older shape, which is a guess for them, and the way it would show is the
/// window opening a line off the headword — the same thing that prompted all this.
private struct PanelMetrics {
    /// The height above the entry that does not move with the reader's text size: the
    /// panel's bar, and the rule under its "Dictionary" label. What sits between them —
    /// the label itself — does move, and is counted separately, in lines.
    let chrome: CGFloat

    /// The panel's own left margin. The card sets its header on 20, so the difference is
    /// what the entry has to be nudged by to sit on the same left. This one follows the
    /// ordinary UIKit rule and has not moved: 16 in a phone-width card, 20 in a wider one.
    let margin: CGFloat

    static var current: PanelMetrics {
        let margin: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 20 : 16
        // Measured on 26.5: the same bar on both idioms, where 17 had two.
        if #available(iOS 26.0, *) {
            return PanelMetrics(chrome: 94, margin: margin)
        }
        // Measured on 17.0.
        return PanelMetrics(chrome: UIDevice.current.userInterfaceIdiom == .pad ? 88 : 76,
                            margin: margin)
    }
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
    /// Whether the card is floating on the whole glass or is itself the presentation.
    /// Told rather than read: inside a sheet that sizes itself to its content, the size
    /// class is an answer to the question this decides.
    let isCompact: Bool
    /// Nothing in the dictionary. The word can still be looked up on the web.
    var onSearch: () -> Void
    var onClose: () -> Void

    private var hasEntry: Bool {
        UIReferenceLibraryViewController.dictionaryHasDefinition(forTerm: term)
    }

    // MARK: - Where the panel is cut

    /// One line of the entry's text, which the dictionary sets in the system body size.
    ///
    /// The lines of an entry are counted in it, and so is the part of the panel's chrome
    /// that grows with the reader's text size. Not all of the chrome does — see
    /// `topCrop`, which is where an earlier reading of this went wrong.
    private var line: CGFloat { UIFont.preferredFont(forTextStyle: .body).lineHeight }

    /// Down to the headword: past the dictionary's own bar, and past the "Dictionary"
    /// label and the rule under it. What is left at the top of the window is the word
    /// itself, its pronunciation and its part of speech.
    ///
    /// The bar and the rule do not move with the reader's text size — they are a fixed
    /// height, drawn by a process that does not take the app's type scale — and only the
    /// label between them grows, by one line. Counting the whole preamble in lines, as
    /// this did, slid the window a line and a half down the entry at large text sizes and
    /// cut the headword off the top of its own definition. The fixed part is not the same
    /// height on every device either; see `PanelMetrics`.
    ///
    /// Measured against the running panel at Large and at xxLarge, on both idioms, and
    /// lands within a point of the headword's line box in each. A point is leading, not
    /// letters.
    private var topCrop: CGFloat { round(metrics.chrome + line) }

    /// The gap the dictionary leaves between the last line of an entry and the rows it
    /// puts under it. Measured at about 50pt and near enough flat across the type scale;
    /// held to 44 here so the window errs on the near side of them.
    private let rowGap: CGFloat = 44

    /// How many whole lines of entry the window can show.
    ///
    /// The rows — "Search Web", "Manage Dictionaries" — do not sit at the foot of the
    /// panel: they follow the entry, `rowGap` below wherever it ends, with the unused
    /// height falling below *them*. So the window has to stop short of where they would
    /// land under the shortest entry there is, which is three lines: a headword, one line
    /// of sense, and the dictionary's name.
    ///
    /// Whole lines, so the cut falls in the leading between two of them rather than
    /// through the letters of one. That is what the fade at the foot of `entry` is for
    /// too, and why it only has to be a few points deep.
    private var visibleLines: Int { 3 + Int(rowGap / line) }

    /// The whole lines, and the fade under them — which lands in the leading below the
    /// last of them, where there is nothing to ghost. An entry longer than the window has
    /// its next line caught by the fade instead, and dissolves rather than ends.
    ///
    /// A short entry leaves the rest of the window as air, and both it and a faded edge
    /// read as the card rather than as a hole, because the panel's own page is mapped to
    /// exactly the level the card is filled with. See `pageLevel`.
    private var entryWindow: CGFloat { round(line * CGFloat(visibleLines) + fade) }

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
    private let pageLevel = CardFace.level

    /// How much the last line softens over, when there is one to soften.
    private let fade: CGFloat = 6

    private let metrics = PanelMetrics.current

    /// What the panel's own margin is short of the card's, which is what the entry has to
    /// be padded by to sit on the header's left.
    private var textInset: CGFloat { 20 - metrics.margin }

    // MARK: - Body

    /// On a phone the surface behind the card is the whole glass, and the card floats in
    /// the middle of it, wearing its own face. On a wide screen the card *is* the
    /// presentation: it is handed to a sheet that sizes itself to what it is given, and
    /// asking for the whole screen there would build a sheet the size of the screen with
    /// a small card adrift in it.
    ///
    /// On that path the face is the sheet's — see `AmberItemPresentation`. The sheet
    /// comes out a few points larger than the card whatever it is given, so the card
    /// cannot draw its own edge without a second one appearing outside it. What it draws
    /// instead is nothing: the sheet is filled, rounded and bordered as a card, and this
    /// is only what goes inside.
    var body: some View {
        if isCompact {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                contents
                    .background(CardFace())
                    // Clipped before the shadow, and not only for the corners: an
                    // unflattened view hands the shadow down to each layer inside it,
                    // and the entry is a layer — it was casting the card's shadow onto
                    // the card, a hand's width of dusk under the last line.
                    .clipShape(RoundedRectangle(cornerRadius: CardFace.cornerRadius,
                                                style: .continuous))
                    .shadow(color: amber.color(0.0, opacity: 0.24), radius: 26, y: 8)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            contents
        }
    }

    private var contents: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            if hasEntry { entry } else { missing }
        }
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
            // The panel's page is a page of this display like any other, so it takes the
            // same grid the card around it is drawn with. Matching the level is not
            // enough on its own: the grid costs the card about four levels, and without
            // it here the entry reads as a paler block set into the card — the one seam
            // the level matching does not close.
            .overlay { if settings.showTexture { PixelGrid() } }
            // An entry longer than the window is let go of rather than sliced: the line
            // that would not fit softens into the card instead of arriving on a cut
            // edge. Only a few points deep, and sitting in the leading under the last
            // whole line — see `entryWindow` — so the line that did fit stays readable
            // rather than ghosted, and a short entry has nothing down there to fade.
            .mask {
                LinearGradient(stops: [.init(color: .black, location: 0),
                                       .init(color: .black, location: 1 - fade / entryWindow),
                                       .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            // The panel keeps a margin of its own, a few points narrower than the card's.
            // Making up the difference sets the headword on the same left as the word in
            // the header above it, which is the only place the two renderings meet.
            .padding(.horizontal, textInset)
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
