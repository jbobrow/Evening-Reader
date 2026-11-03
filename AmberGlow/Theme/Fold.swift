import SwiftUI

/// The iPhone Duo's fold, while the glass is bent enough for it to matter.
///
/// Opened flat, the crease is there but a page reads straight across it, and nothing
/// moves on its account. Bent, the two halves face different ways: held like a book, the
/// crease is a spine between a left page and a right one; stood up like a laptop, it is
/// the hinge between a screen and a desk. Either way it is no place to put anything that
/// has to be read whole.
struct Fold: Equatable {
    /// The band the fold takes, margins and all, in the space of the view it was read in.
    var frame: CGRect

    /// A spine: the crease runs top to bottom.
    var isVertical: Bool { frame.height > frame.width }
}

/// How an iPhone Duo is being held, for the few views that lay themselves out
/// differently on one. `.none` on anything that does not fold, which is every other
/// device the app runs on — and those are left exactly as they were.
enum DuoPose: Equatable {
    /// A phone or a tablet that does not fold.
    case none
    /// Folded shut, on the outer screen: a phone held in one hand, the thumb along its
    /// right-hand edge.
    case closed
    /// Open, on the inner screen — flat, held like a book, or stood up like a laptop.
    case open
}

/// The band down the right-hand edge of the iPhone Duo's outer screen, folded shut.
///
/// The system keeps it out of the safe area for the whole height of the glass, though
/// only its top is taken — the camera, and the plateau it sits on. The rest is glass
/// with nothing on it, under the thumb that holds the phone. So the app uses it: the
/// buttons of whatever is on the glass stand in a rail down the band, below the camera,
/// and the page keeps to the safe area beside them. Or, expanded, the page runs the full
/// width under the band, the rail goes, and the buttons go back into the bar — which
/// keeps clear of the band, since the camera is there.
struct CameraStrip: Equatable {
    /// How wide the band is.
    var width: CGFloat
    /// What is really taken, in the safe area's own space: the camera and its plateau,
    /// at the top of the band.
    var occluded: CGRect
    /// The page runs the full width, and the rail is away.
    var expanded: Bool

    /// The band holds the buttons.
    var rails: Bool { !expanded }
}

extension EnvironmentValues {
    @Entry var duoPose: DuoPose = .none
    /// The camera band, on the Duo's outer screen; nil on every other screen.
    @Entry var cameraStrip: CameraStrip? = nil
    /// Expands the page under the band, or brings the rail back.
    @Entry var toggleCameraStrip: () -> Void = {}

    /// Whether a bar's buttons all gather at its trailing end: the page expanded under
    /// the camera band on glass held in one hand, where the thumb rests along the
    /// right-hand edge and a button on the far left of the bar is a reach across the
    /// glass. (With the rail up, the bar has no buttons at all.)
    var controlsTrailing: Bool { cameraStrip?.expanded == true }
    /// Whether the buttons stand in the rail, and the bar holds only its title.
    var controlsRailed: Bool { cameraStrip?.rails == true }
}

/// The rail: a screen's buttons, down the camera band, below the camera. At its foot,
/// the way to expand the page over it.
struct CameraStripRail<Buttons: View>: View {
    @Environment(\.toggleCameraStrip) private var toggle
    let strip: CameraStrip
    @ViewBuilder var buttons: Buttons

    var body: some View {
        VStack(spacing: 6) {
            buttons
            Spacer(minLength: 12)
            AmberIconButton(symbol: "arrow.up.left.and.arrow.down.right", action: toggle)
                .accessibilityLabel("Use the full width")
        }
        .padding(.top, strip.occluded.height + 10)
        .padding(.bottom, 14)
        .frame(width: strip.width)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// The way back from the expanded page: the rail, and the page beside it.
struct CameraStripCollapse: View {
    @Environment(\.toggleCameraStrip) private var toggle

    var body: some View {
        AmberIconButton(symbol: "arrow.down.right.and.arrow.up.left", action: toggle)
            .accessibilityLabel("Keep the page beside the camera")
    }
}

extension View {
    /// Stands these buttons in the camera band beside this view, while the band holds
    /// the rail. This view keeps to the safe area; the rail is laid just past its
    /// trailing edge, which is where the band begins.
    func cameraStripRail<Buttons: View>(@ViewBuilder buttons: @escaping () -> Buttons) -> some View {
        modifier(CameraStripRailed(buttons: buttons))
    }

    /// Keeps a bar's contents out of the camera band when the page has expanded under
    /// it: the bar runs the full width, but nothing on it goes under the camera.
    func clearOfCameraStrip(_ strip: CameraStrip?) -> some View {
        padding(.trailing, strip?.expanded == true ? strip!.width : 0)
    }

    /// Cuts the camera's corner out of a page expanded under the band, softly, so what
    /// shows there is the paper rather than text under a lens.
    func cutAroundCamera(_ strip: CameraStrip?) -> some View {
        mask {
            ZStack(alignment: .topTrailing) {
                Color.black
                CameraCutout(strip: strip)
            }
            .compositingGroup()
        }
    }
}

/// The camera's corner, for a mask: black where the page shows, cut away under the
/// lens. Composed into a mask with `.destinationOut`, so it can join a mask that
/// already has a shape of its own — see `DetailPane.pageMask`.
struct CameraCutout: View {
    var strip: CameraStrip?

    var body: some View {
        if let strip, strip.expanded {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.black)
                .frame(width: strip.width + 6, height: strip.occluded.height + 6)
                .padding(.top, -12)
                .padding(.trailing, -12)
                .blur(radius: 5)
                .blendMode(.destinationOut)
        }
    }
}

private struct CameraStripRailed<Buttons: View>: ViewModifier {
    @Environment(\.cameraStrip) private var strip
    let buttons: () -> Buttons

    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            if let strip, strip.rails {
                CameraStripRail(strip: strip, buttons: buttons)
                    .offset(x: strip.width)
                    .transition(.opacity)
            }
        }
    }
}

extension View {
    /// Keeps `pose` current with the hinge: shut, open, or not there at all.
    func readsDuoPose(_ pose: Binding<DuoPose>) -> some View {
        modifier(DuoPoseReader(pose: pose))
    }
}

private struct DuoPoseReader: ViewModifier {
    @Binding var pose: DuoPose

    @ViewBuilder
    func body(content: Content) -> some View {
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, context in
                guard let hinge = context.hinge else { pose = .none; return }
                pose = hinge.status == .closed ? .closed : .open
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

extension GeometryProxy {
    /// Where the fold crosses this view, while the glass is bent. Nil on anything that
    /// does not fold, opened flat — and in a build made with an SDK older than iOS 27.1,
    /// which has no way to ask. That SDK's SwiftUI is the first at 8.0.85; checking for
    /// it keeps the app building with the Xcode before it, minus the fold.
    var fold: Fold? {
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            return reservedRegions(kind: .division)
                .first(where: \.isActive)
                .map { Fold(frame: $0.frame) }
        }
        #endif
        return nil
    }

    /// What is taken out of this view by the glass itself — the Duo's outer camera and
    /// its plateau, on the screen folded shut — in this view's space. Empty elsewhere.
    var occlusions: [CGRect] {
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            return reservedRegions(kind: .occlusion, options: .includeInactive).map(\.frame)
        }
        #endif
        return []
    }

    /// Where the crease crosses this view, bent or flat. The glass opened flat still has
    /// its crease, and a layout that can take it for a spine — the drawer as the
    /// left-hand page — is better off doing so whether or not the glass is bent at it.
    var crease: Fold? {
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            return reservedRegions(kind: .division, options: .includeInactive)
                .first
                .map { Fold(frame: $0.frame) }
        }
        #endif
        return nil
    }
}

extension View {
    /// Centres a dialog on the upright half of glass stood up like a laptop, rather than
    /// on the hinge, where it would be bent across the two halves. Anywhere else it is
    /// left where it was. `fold` must be in the space this view is laid out in.
    func centeredAboveFold(_ fold: Fold?) -> some View {
        modifier(AboveFold(fold: fold))
    }
}

private struct AboveFold: ViewModifier {
    let fold: Fold?

    func body(content: Content) -> some View {
        if let fold, !fold.isVertical {
            content
                .frame(maxWidth: .infinity, maxHeight: fold.frame.minY)
                .frame(maxHeight: .infinity, alignment: .top)
        } else {
            content
        }
    }
}
