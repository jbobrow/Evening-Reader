import SwiftUI

/// One site on the front page: a tile, and its name under it.
struct SiteTile: View {
    @Environment(\.amber) private var amber

    let site: Site
    let icon: UIImage?
    var size: Double = 56

    var body: some View {
        VStack(spacing: 6) {
            SiteFace(site: site, icon: icon, size: size)
            Text(site.name.isEmpty ? site.host : site.name)
                .font(.system(size: 11, weight: .medium))
                .tracking(0.4)
                .lineLimit(1)
                .foregroundStyle(amber.inkMuted)
        }
        .frame(width: size + 4)
    }
}

/// The tile itself, at whatever size a row wants it: the reader's symbol if one was
/// chosen, else the site's own icon in the panel's ink, else the first letter.
struct SiteFace: View {
    @Environment(\.amber) private var amber

    let site: Site
    let icon: UIImage?
    var size: Double = 56

    private var radius: Double { size >= 48 ? 14 : 9 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(amber.color(0.78))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(amber.rule, lineWidth: 1))
            glyph
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private var glyph: some View {
        if let symbol = site.symbol {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .regular))
                .foregroundStyle(amber.inkStrong)
        } else if let icon {
            let side = (size * 0.62).rounded()
            Image(uiImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
                .modifier(InkTinted(level: 0.78))
        } else {
            Text(site.monogram)
                .font(.system(size: size * 0.4, weight: .semibold, design: .serif))
                .foregroundStyle(amber.inkStrong)
        }
    }
}

/// The dashed tile that adds one.
struct AddSiteTile: View {
    @Environment(\.amber) private var amber
    var size: Double = 56
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(amber.rule, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .frame(width: size, height: size)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(amber.inkFaint)
                    }
                Text("Add")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.4)
                    .foregroundStyle(amber.inkFaint)
            }
            .frame(width: size + 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A picture from outside, drawn in the panel's ink.
///
/// The same mapping the browser puts a whole page through — luminance, squeezed into the
/// ink..surface span, multiplied onto the emitter — so a site's icon lands on the ramp
/// the way its pages already do. `level` is the surface it sits on: white in the picture
/// becomes exactly that level, black becomes ink, and at night the two change places.
struct InkTinted: ViewModifier {
    @Environment(\.amber) private var amber
    @Environment(DisplaySettings.self) private var settings

    var level: Double

    private let inkFloor = 0.045

    private var isNight: Bool { settings.polarity == .night }
    private var sign: Double { isNight ? -1 : 1 }
    private var tint: Color { isNight ? amber.color(0.0) : amber.color(level) }

    private var floor: Double {
        guard isNight else { return inkFloor }
        let ink = amber.rgb(0.0).0
        let surface = amber.rgb(level).0
        return ink > 0 ? min(1, surface / ink) : inkFloor
    }

    func body(content: Content) -> some View {
        content
            .grayscale(1)
            .contrast(sign * (1 - floor))
            .brightness(floor / 2)
            .colorMultiply(tint)
    }
}
