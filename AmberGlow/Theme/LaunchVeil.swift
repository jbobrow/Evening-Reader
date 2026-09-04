import SwiftUI

/// The opening: the name coming up out of the dark, and the dark then giving way to the
/// panel behind it.
///
/// The system's launch screen is a still — it can be given a colour and nothing else — so
/// it is black, and the app picks up from the same black and lights the name on it. There
/// is no seam to find between the two, because they are the same black; the only thing
/// that ever moves is the type.
///
/// Black rather than the ramp's own darkest, which is ink and not quite black. This is the
/// one moment the app is not yet a lit panel, and the name arriving is the panel coming on.
struct LaunchVeil: View {
    @Environment(DisplaySettings.self) private var settings
    @Environment(\.horizontalSizeClass) private var sizeClass

    var nameShowing: Bool

    var body: some View {
        ZStack {
            Color.black
            Text("Evening Reader")
                .font(.system(size: sizeClass == .compact ? 34 : 42,
                              weight: .regular, design: .serif))
                .tracking(1.2)
                .foregroundStyle(nameColor)
                .opacity(nameShowing ? 1 : 0)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// The brightest the panel emits, taken from whichever end of the ramp that is: on
    /// paper the top, and at night the ink, since night turns the ramp over. The top
    /// rather than the page level — on black this is the panel coming on, and it should
    /// arrive at full strength.
    ///
    /// Reading the palette rather than fixing a colour means the name comes up in the
    /// glow the reader last set, so the app opens as the thing they left.
    private var nameColor: Color {
        settings.palette.color(settings.polarity == .night ? 0.0 : 1.0)
    }
}
