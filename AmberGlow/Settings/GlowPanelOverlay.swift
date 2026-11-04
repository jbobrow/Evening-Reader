import SwiftUI

/// The display settings, over whatever is on the glass.
///
/// Drawn by the app rather than presented as a popover. A system popover supplies its
/// own white container behind the content, which shows through the rounded corners as
/// a hairline and flashes white for a frame on dismissal — neither is survivable in a
/// panel whose whole premise is that no second colour exists.
///
/// On a phone the panel takes the whole glass. The card is 380pt wide and the screen is
/// 402: what is left is an 11pt margin that reads as a mistake rather than as a frame.
/// And the card has no close of its own — it relies on there being page beside it to
/// tap on, which at that width there is not. Full screen gives the controls the room
/// they were drawn for and puts the way out on the panel itself.
struct GlowPanelOverlay: View {
    @Environment(DisplaySettings.self) private var settings
    @Environment(\.amber) private var amber
    @Environment(\.pageIsShort) private var pageIsShort
    @Environment(\.cameraStrip) private var cameraStrip

    var isCompact: Bool
    /// Which corner the card hangs from, on a wide panel: under the button that opened it.
    var alignment: Alignment = .topTrailing
    /// How far down the card sits — below the chrome, when there is chrome.
    var top: CGFloat = 54
    var size: CGSize
    var onClose: () -> Void

    var body: some View {
        if isCompact {
            fullScreen
        } else {
            card
        }
    }

    @ViewBuilder
    private var fullScreen: some View {
        // First short, over the page; then, opened the rest of the way, the whole panel.
        if pageIsShort {
            QuickPanel()
                .transition(.opacity)
        } else {
            wholePage
                .transition(.opacity)
        }
    }

    private var wholePage: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Display settings")
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                    .foregroundStyle(amber.inkStrong)
                Spacer()
                AmberIconButton(symbol: "xmark", action: onClose)
            }
            .padding(.leading, 22)
            // The page runs the full width of the Duo's outer screen, and the camera is
            // at the top of the band: the way out stands beside it, not under it.
            .padding(.trailing, 14 + (cameraStrip?.width ?? 0))
            .padding(.top, 12)
            .padding(.bottom, 14)

            Hairline()

            PanelControls()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // No ground, edge or transition of its own: on a phone it comes up over the
        // page on the page's own lamp (see `PageCover`), the same paper, with only a
        // shadow along its top edge while it moves.
    }

    private var card: some View {
        let width = min(380, size.width - 24)
        return ZStack(alignment: alignment) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)

            // As tall as what is in it, so tall glass gets no empty card under the
            // controls; past what the glass allows, the controls scroll.
            FitsContents(limit: max(320, size.height - top - 24)) {
                PanelControls()
                    .frame(width: width)
            }
            .background {
                ZStack {
                    amber.color(0.93)
                    if settings.showTexture { PixelGrid() }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(amber.color(0.62, opacity: 0.5), lineWidth: 1)
            }
            .shadow(color: amber.color(0.0, opacity: 0.22), radius: 26, y: 10)
            .padding(.top, top)
            .padding(.horizontal, 12)
            .transition(
                .scale(scale: 0.96, anchor: alignment == .topLeading ? .topLeading : .topTrailing)
                .combined(with: .opacity)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Its content's own height, up to a limit.
///
/// `frame(maxHeight:)` will not do: it takes the limit whether the content needs it or
/// not. And being a layout rather than a measurement kept in state, the height moves in
/// the same animation as whatever changed it — Advanced opening, the tabs changing.
private struct FitsContents: Layout {
    var limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let ideal = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: ideal.width, height: min(ideal.height, limit))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
