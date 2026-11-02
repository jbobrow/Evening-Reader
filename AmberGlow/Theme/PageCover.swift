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
/// The page's content draws no ground of its own; this supplies it.
struct PageCover<Page: View>: ViewModifier {
    @Binding var isPresented: Bool
    @ViewBuilder var page: () -> Page

    @Environment(\.amber) private var amber
    /// Whether the page is in the hierarchy: it stays after `isPresented` goes false
    /// until it has finished going down.
    @State private var mounted = false
    /// How far down the glass the page's top edge is: 0 up, 1 gone.
    @State private var drop: CGFloat = 1
    /// Going down: no dimming and no edge, only the slide.
    @State private var leaving = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if mounted {
                    GeometryReader { geo in
                        // The whole glass, so the page leaves it entirely; the page's
                        // own content keeps to the safe area, and the lamp and its edge
                        // run past it.
                        let glass = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
                        let travel = drop * glass
                        ZStack(alignment: .top) {
                            // The page beneath, going down as it is covered.
                            if !leaving {
                                amber.color(0.02, opacity: 0.28 * (1 - drop))
                                    .ignoresSafeArea()
                                    .allowsHitTesting(false)
                            }
                            GlowSurface()
                                .mask(alignment: .top) {
                                    Rectangle().ignoresSafeArea().offset(y: travel)
                                }
                            // The edge. Above the page, on the page it is coming over.
                            if !leaving {
                                LinearGradient(colors: [amber.color(0.0, opacity: 0),
                                                        amber.color(0.0, opacity: 0.2)],
                                               startPoint: .top, endPoint: .bottom)
                                    .frame(height: 14)
                                    .offset(y: travel - geo.safeAreaInsets.top - 14)
                                    .allowsHitTesting(false)
                            }
                            page()
                                .environment(\.closePage, { isPresented = false })
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                                .offset(y: travel)
                        }
                    }
                }
            }
            .onChange(of: isPresented, initial: true) { _, show in
                if show {
                    mounted = true
                    leaving = false
                    drop = 1
                    // On the next turn, so the page is laid out off the glass first and
                    // has somewhere to come up from.
                    DispatchQueue.main.async {
                        withAnimation(.drawer) { drop = 0 }
                    }
                } else if mounted {
                    leaving = true
                    withAnimation(.drawer) { drop = 1 } completion: {
                        if !isPresented { mounted = false }
                    }
                }
            }
    }
}

extension EnvironmentValues {
    /// Puts away the page cover a view is on, or nil when it is not on one. A page that
    /// is sometimes presented by the system and sometimes drawn over the page uses it
    /// in place of `dismiss`, which has nothing to dismiss on a cover — and leaves its
    /// own ground off when it is set, since the cover supplies the lamp.
    @Entry var closePage: (() -> Void)? = nil
}
