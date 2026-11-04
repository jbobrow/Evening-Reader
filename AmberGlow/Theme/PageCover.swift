import SwiftUI

/// A page that comes up over the whole glass from the bottom, drawn by the app.
///
/// The system's full-screen cover slides its own view, lamp and all: the bloom rode up
/// with it, so the page arriving was a different colour from the page under it at
/// every point of the glass until it came to rest, and the system laid its own shading
/// over what it was covering. Here the lamp does not move. It is the page's own
/// `GlowSurface`, still, and the arriving page is a window onto it whose top edge
/// rises — so the two are the same colour everywhere. On the way up the page beneath
/// dims as it is covered and a soft shadow runs along the rising edge; on the way down
/// there is neither, so nothing brightens as the page goes — it simply slides away.
/// At rest the edge is off the top of the glass.
///
/// A short page stops partway, as tall as the page says it is (`PageCoverHeight`), with
/// the page it came up over left showing above it and undimmed — the display settings,
/// set against the real page rather than a sample of it. Dragged up, or asked to with
/// `expandPage`, it opens the rest of the way; dragged down it goes, as does a tap on
/// the page showing above it.
///
/// The page's content draws no ground of its own; this supplies it.
struct PageCover<Page: View>: ViewModifier {
    @Binding var isPresented: Bool
    /// Whether the page first comes up short. See above.
    var short: Bool = false
    /// Whether the page's content runs the glass's full width, past the side bands of
    /// the safe area — the display settings on the iPhone Duo folded shut, which would
    /// otherwise stop short of the camera band and leave a strip of nothing beside
    /// them. The page keeps its own controls clear of the camera.
    var fullWidth: Bool = false
    @ViewBuilder var page: () -> Page

    @Environment(\.amber) private var amber

    private enum Rest { case gone, short, full }

    /// Whether the page is in the hierarchy: it stays after `isPresented` goes false
    /// until it has finished going down.
    @State private var mounted = false
    @State private var rest: Rest = .gone
    /// Going down: no dimming and no edge, only the slide.
    @State private var leaving = false
    /// How far a finger has the page from where it rests, down positive.
    @State private var drag: CGFloat = 0
    /// How tall the short page says it is. A guess until it has been laid out.
    @State private var shortHeight: CGFloat = 300

    func body(content: Content) -> some View {
        content
            .overlay {
                if mounted {
                    GeometryReader { geo in
                        cover(in: geo)
                    }
                }
            }
            .onChange(of: isPresented, initial: true) { _, show in
                if show {
                    mounted = true
                    leaving = false
                    rest = .gone
                    drag = 0
                    // On the next turn, so the page is laid out off the glass first and
                    // has somewhere to come up from.
                    DispatchQueue.main.async {
                        withAnimation(.drawer) { rest = short ? .short : .full }
                    }
                } else if mounted {
                    leaving = true
                    withAnimation(.drawer) { rest = .gone; drag = 0 } completion: {
                        if !isPresented { mounted = false }
                    }
                }
            }
    }

    @ViewBuilder
    private func cover(in geo: GeometryProxy) -> some View {
        let top = geo.safeAreaInsets.top
        // The whole glass, so the page leaves it entirely; the page's own content keeps
        // to the safe area, and the lamp and its edge run past it.
        let glass = geo.size.height + top + geo.safeAreaInsets.bottom
        let shortTravel = max(0, glass - shortHeight - geo.safeAreaInsets.bottom)
        let base: CGFloat = switch rest {
        case .gone: glass
        case .short: shortTravel
        case .full: 0
        }
        // Where the edge is, down from the top of the glass.
        let travel = min(glass, max(0, base + drag))
        // The page beneath goes down only as it is covered past the short page, so the
        // page a short one is set against is seen as it is.
        let dimFrom = short ? shortTravel : glass
        let dim = dimFrom > 0 ? 0.28 * max(0, 1 - travel / dimFrom) : 0
        // A short page's content starts at its edge; a full one keeps clear of the island.
        let contentTop = rest == .full || !short ? top : 0
        // The glass's width, bands and all. The page's content keeps to the safe area,
        // but its lamp and its ground run to the edges — on the iPhone Duo folded shut
        // that is the camera band, where the rail beneath would otherwise show beside
        // the page, and could be used under it.
        let side = geo.safeAreaInsets.leading + geo.safeAreaInsets.trailing
        let shift = (geo.safeAreaInsets.trailing - geo.safeAreaInsets.leading) / 2

        ZStack(alignment: .top) {
            if !leaving {
                amber.color(0.02, opacity: dim)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            // The page showing above a short one: a tap there puts it away.
            if short && rest == .short && !leaving {
                Color.clear
                    .contentShape(Rectangle())
                    .frame(height: max(0, travel - top))
                    .ignoresSafeArea(.container, edges: .horizontal)
                    .onTapGesture { isPresented = false }
            }
            GlowSurface()
                // The lamp's frame starts below the island, as the page's does, though
                // it draws to every edge; the edge is measured from the top of the glass,
                // and the window runs the whole glass below it.
                .mask(alignment: .top) {
                    Rectangle()
                        .frame(width: geo.size.width + side, height: glass)
                        .offset(x: shift, y: travel - top)
                }
                .allowsHitTesting(false)
            // The ground under the page, bands included: nothing beneath is reached
            // through it. Taller than this stack is laid out, and kept from saying so: the
            // stack would take that height and hand it to the page, and whatever the page
            // stands at its foot would go off the bottom of the glass.
            Color.clear
                .contentShape(Rectangle())
                .frame(height: max(0, glass - travel))
                .frame(height: geo.size.height, alignment: .top)
                .offset(y: travel - top)
                .ignoresSafeArea(.container, edges: .horizontal)
            // The edge. Above the page, on the page it is coming over.
            if !leaving {
                LinearGradient(colors: [amber.color(0.0, opacity: 0),
                                        amber.color(0.0, opacity: 0.2)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 14)
                    .offset(y: travel - top - 14)
                    .ignoresSafeArea(.container, edges: .horizontal)
                    .allowsHitTesting(false)
            }
            page()
                .environment(\.closePage, { isPresented = false })
                .environment(\.pageIsShort, short && rest != .full)
                .environment(\.expandPage, short ? { withAnimation(.drawer) { rest = .full } } : nil)
                .environment(\.pagePull, short ? pull(shortTravel: shortTravel) : nil)
                .onPreferenceChange(PageCoverHeight.self) { h in
                    guard h > 0, abs(h - shortHeight) > 0.5 else { return }
                    withAnimation(.drawer) { shortHeight = h }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea(.container, edges: fullWidth ? .horizontal : [])
                .contentShape(Rectangle())
                .offset(y: travel - (top - contentTop))
                // The ground of the page; a slider or a scroll inside takes its own drags
                // first, and a button passes them on (`pullsPage()`).
                .gesture(pull(shortTravel: shortTravel).gesture, isEnabled: short)
        }
    }

    /// Up to open, down to go.
    private func pull(shortTravel: CGFloat) -> PagePull {
        PagePull(
            changed: { drag = $0 },
            ended: { flung in
                withAnimation(.drawer) {
                    drag = 0
                    switch rest {
                    case .short:
                        if flung < -80 { rest = .full }
                        else if flung > 80 { isPresented = false }
                    case .full:
                        // Most of the way down goes; a little way down comes back short.
                        if flung > shortTravel * 0.75 + 80 { isPresented = false }
                        else if flung > 80 { rest = .short }
                    case .gone:
                        break
                    }
                }
            })
    }
}

/// What a finger moving a short page cover does, handed to the page so a control on it
/// can pass a drag on to the cover (see `pullsPage()`).
struct PagePull {
    /// How far the finger has gone, down positive.
    var changed: (CGFloat) -> Void
    /// Where it was flung to on lifting.
    var ended: (CGFloat) -> Void

    var gesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { changed($0.translation.height) }
            .onEnded { ended($0.predictedEndTranslation.height) }
    }
}

extension View {
    /// Lets a drag that starts on a button here move the page cover it is on, as a drag
    /// on the page's ground does. A button takes its touches before the page sees them,
    /// so without this a row of buttons is a dead patch in the middle of something that
    /// otherwise lifts. A tap is still a tap: the drag only claims a touch once it has
    /// moved. Not for a slider, whose drag is its own.
    func pullsPage() -> some View { modifier(PullsPage()) }
}

private struct PullsPage: ViewModifier {
    @Environment(\.pagePull) private var pull

    func body(content: Content) -> some View {
        if let pull {
            content.highPriorityGesture(pull.gesture)
        } else {
            content
        }
    }
}

/// How tall a short page is, from its top edge to the bottom of its content.
struct PageCoverHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension EnvironmentValues {
    /// Puts away the page cover a view is on, or nil when it is not on one. A page that
    /// is sometimes presented by the system and sometimes drawn over the page uses it
    /// in place of `dismiss`, which has nothing to dismiss on a cover — and leaves its
    /// own ground off when it is set, since the cover supplies the lamp.
    @Entry var closePage: (() -> Void)? = nil
    /// Whether the page cover is resting short, over the page it came up on.
    @Entry var pageIsShort: Bool = false
    /// Opens a short page cover the rest of the way, or nil when it is not a short one.
    @Entry var expandPage: (() -> Void)? = nil
    /// Moves a short page cover with a finger, or nil when it is not a short one.
    @Entry var pagePull: PagePull? = nil
}
