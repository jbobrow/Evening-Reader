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

    private var fullScreen: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Display settings")
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                    .foregroundStyle(amber.inkStrong)
                Spacer()
                AmberIconButton(symbol: "xmark", action: onClose)
            }
            .padding(.leading, 22)
            .padding(.trailing, 14)
            .padding(.top, 12)
            .padding(.bottom, 14)

            Hairline()

            PanelControls()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                amber.color(0.93)
                if settings.showTexture { PixelGrid() }
            }
            .ignoresSafeArea()
        }
        // Up over the page, the way the drawer comes in from the side. Sliding rather
        // than fading keeps it a thing that arrived and can be sent away again.
        .transition(.move(edge: .bottom))
    }

    private var card: some View {
        let width = min(380, size.width - 24)
        return ZStack(alignment: alignment) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)

            PanelControls()
                .frame(width: width)
                // As tall as the glass allows, so the panel is not cut mid-control
                // when there is room to show the whole thing.
                .frame(maxHeight: max(320, size.height - top - 24))
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
