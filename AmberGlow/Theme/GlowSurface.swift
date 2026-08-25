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
