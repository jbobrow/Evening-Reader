import SwiftUI

/// The lit panel itself: flat amber, a soft backlight wash, and a faint pixel grid.
struct GlowSurface: View {
    @Environment(\.amber) private var amber
    @Environment(DisplaySettings.self) private var settings

    var level: Double = 0.88
    var bloomStrength: Double = 0.5

    var body: some View {
        ZStack {
            amber.color(level)

            BacklightBloom(level: level, strength: bloomStrength)

            if settings.showTexture {
                PixelGrid()
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// The backlight itself. Pulled out of `GlowSurface` because it belongs to the panel
/// rather than to any one view: browse mode paints it *over* the web view, since an
/// arbitrary page is opaque and would otherwise hide the lamp entirely.
struct BacklightBloom: View {
    @Environment(\.amber) private var amber
    @Environment(DisplaySettings.self) private var settings

    var level: Double = 0.88
    var strength: Double = 0.5

    var body: some View {
        if settings.showBloom {
            RadialGradient(
                colors: [amber.color(min(level + 0.09, 1.0), opacity: strength), .clear],
                center: .center,
                startRadius: 0,
                endRadius: 620
            )
            .blendMode(.plusLighter)
            .opacity(0.55)
            .allowsHitTesting(false)
        }
    }
}

/// A tiled one-device-pixel grid. Subtle at rest, obvious if you lean in — the thing
/// that keeps a flat fill from looking like paper.
struct PixelGrid: View {
    var opacity: Double = 0.07

    var body: some View {
        Image(uiImage: PixelGrid.tile)
            .resizable(resizingMode: .tile)
            .opacity(opacity)
            .blendMode(.multiply)
            .allowsHitTesting(false)
    }

    /// 64pt tile carrying a 3-device-pixel lattice, so the whole screen costs ~2k tiles.
    static let tile: UIImage = {
        let side: CGFloat = 64
        let scale: CGFloat = 3
        let step: CGFloat = 3 / scale     // 3 device pixels expressed in points
        let hair: CGFloat = 1 / scale     // one device pixel
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        return renderer.image { ctx in
            let c = ctx.cgContext
            c.setFillColor(UIColor.black.cgColor)
            var x: CGFloat = 0
            while x < side {
                c.fill(CGRect(x: x, y: 0, width: hair, height: side))
                x += step
            }
            var y: CGFloat = 0
            while y < side {
                c.fill(CGRect(x: 0, y: y, width: side, height: hair))
                y += step
            }
        }
    }()
}

extension View {
    /// Standard page background for a full screen.
    func glowPage(level: Double = 0.88) -> some View {
        background(GlowSurface(level: level))
    }
}


/// The face of a card that floats over the glass: a page a shade brighter than the
/// surface behind it, the grid over that, a hairline round the edge.
///
/// A card would normally draw this itself, and on a phone it does. It is a view of its
/// own so that a sheet fitted around such a card can be given the same face — a fitted
/// sheet comes out about five points taller than what it was fitted to, and any other
/// fill in those five points reads as a second, lighter edge above and below the card,
/// with corners of its own. See `AmberItemPresentation`.
struct CardFace: View {
    @Environment(\.amber) private var amber
    @Environment(DisplaySettings.self) private var settings

    /// Where a white page lands on the ramp. Shared with `AmberInk`, so that a rendering
    /// the app did not draw and the card it is set into are the same colour with no seam.
    static let level = 0.93
    static let cornerRadius: CGFloat = 20

    var body: some View {
        ZStack {
            amber.color(Self.level)
            if settings.showTexture { PixelGrid() }
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(amber.color(0.62, opacity: 0.5), lineWidth: 1)
        }
    }
}

/// Puts a surface the app did not draw onto the ramp.
///
/// A few things arrive already rendered, in somebody else's colours: a PDF's pages, the
/// system dictionary's card. There is no stylesheet to reach into and no appearance API
/// to set, so they are treated as photographs of a page rather than as views. Grayscale
/// strips the colour, contrast maps black-and-white onto ink-and-page, and the multiply
/// lands what is left on the glow. At night the contrast goes negative, which is the same
/// flip the whole app makes — the page becomes ink and the ink becomes page.
struct AmberInk: ViewModifier {
    @Environment(\.amber) private var amber

    /// Where a white page lands. 0.88 is what every other surface in the app calls paper.
    var pageLevel: Double = 0.88
    var isNight: Bool

    /// Where black lands, on paper. The same level as body type.
    private let inkFloor = 0.045

    private var sign: Double { isNight ? -1 : 1 }
    private var tint: Color { isNight ? amber.color(0.0) : amber.color(pageLevel) }
    private var floor: Double {
        guard isNight else { return inkFloor }
        let ink = amber.rgb(0.0).0
        let page = amber.rgb(pageLevel).0
        return ink > 0 ? min(1, page / ink) : inkFloor
    }

    func body(content: Content) -> some View {
        content
            .grayscale(1)
            .contrast(sign * (1 - floor))
            .brightness(floor / 2)
            .colorMultiply(tint)
    }
}

extension View {
    func amberInk(pageLevel: Double = 0.88, isNight: Bool) -> some View {
        modifier(AmberInk(pageLevel: pageLevel, isNight: isNight))
    }
}
