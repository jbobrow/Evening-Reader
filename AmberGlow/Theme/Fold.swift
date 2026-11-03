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

extension EnvironmentValues {
    @Entry var duoPose: DuoPose = .none

    /// Whether a bar's buttons all gather at its trailing edge. Folded shut, the Duo is
    /// a wide phone held in one hand, and the thumb that holds it rests along the
    /// right-hand edge: a button on the far left of the bar is a reach across the
    /// glass, so every one of them moves over to where the thumb already is.
    var controlsTrailing: Bool { duoPose == .closed }
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
