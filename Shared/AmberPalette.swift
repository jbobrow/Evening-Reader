import SwiftUI

/// The whole app is drawn from a single one-dimensional ramp.
///
/// Every color in Amber Glow is produced by `AmberPalette.color(_:)` from a grayscale
/// *level* — 0 is ink, 1 is the brightest the panel emits. Nothing in the UI is allowed
/// to introduce a second hue, which is what makes the result read as a backlit amber
/// panel rather than a beige-tinted iPad app.
struct AmberPalette: Equatable {

    enum Polarity: String, Codable, CaseIterable, Identifiable {
        /// Dark ink on a glowing amber page — the Daylight default.
        case paper
        /// Amber ink on a near-black page, for a dark room.
        case night

        var id: String { rawValue }
        var label: String { self == .paper ? "Paper" : "Night" }
        var symbol: String { self == .paper ? "sun.max" : "moon" }
    }

    /// 0 = warm beige (yellow-leaning, desaturated), 1 = orange amber (saturated).
    var warmth: Double = 0.87
    /// Overall emission of the panel, 0.0 dim … 1.0 full.
    var glow: Double = 0.80
    /// Separation between ink and page, 0.0 soft … 1.0 crisp.
    var contrast: Double = 0.30
    var polarity: Polarity = .paper

    /// What to call the current warmth. Lives here rather than in the panel so that a
    /// saved preset can name itself the same way the slider does.
    var warmthName: String {
        switch warmth {
        case ..<0.2: return "Warm beige"
        case ..<0.45: return "Sand"
        case ..<0.7: return "Amber"
        case ..<0.88: return "Deep amber"
        default: return "Orange amber"
        }
    }

    // MARK: - The ramp

    /// Hue of the emitter: ~39° beige → ~26° amber.
    private var hue: Double { lerp(39.0 / 360.0, 25.5 / 360.0, warmth) }

    /// Saturation at mid-tone: beige is barely tinted, amber is nearly pure.
    private var baseSaturation: Double { lerp(0.24, 0.97, warmth) }

    /// Maps a UI level (0 ink … 1 brightest) through contrast, polarity and glow.
    private func luminance(_ level: Double) -> Double {
        let c = lerp(0.55, 1.55, contrast)
        var l = 0.5 + (clamp01(level) - 0.5) * c
        l = clamp01(l)
        switch polarity {
        case .paper:
            // Dim the panel without crushing the ink: the page falls, ink stays put.
            let ceiling = lerp(0.46, 1.0, glow)
            return pow(l, 1.06) * ceiling
        case .night:
            // Invert, then keep the whole range well under full brightness.
            let inverted = 1.0 - l
            let ceiling = lerp(0.30, 0.86, glow)
            return pow(inverted, 1.35) * ceiling
        }
    }

    /// The single color-producing function. `level`: 0 = ink, 1 = brightest emission.
    func color(_ level: Double) -> Color {
        let (r, g, b) = rgb(level)
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    func color(_ level: Double, opacity: Double) -> Color {
        let (r, g, b) = rgb(level)
        return Color(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }

    func rgb(_ level: Double) -> (Double, Double, Double) {
        let l = luminance(level)
        // Highlights bloom toward warm white instead of clipping into pure orange,
        // the way a diffused backlight actually behaves.
        let s = baseSaturation * (1.0 - 0.30 * pow(l, 2.4))
        return hsbToRGB(h: hue, s: clamp01(s), b: clamp01(l))
    }

    /// `#rrggbb` for the same level, for injecting into the reader's stylesheet.
    func hex(_ level: Double) -> String {
        let (r, g, b) = rgb(level)
        return String(format: "#%02x%02x%02x",
                      Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    // MARK: - Semantic tokens

    var page: Color { color(0.88) }          // the glowing sheet
    var pageDim: Color { color(0.80) }       // wells, inset fields
    var pageRaised: Color { color(0.955) }   // cards, sheets, popovers
    var bloom: Color { color(1.0) }          // backlight hot spot
    var bezel: Color { color(0.30) }         // frame around the panel

    var ink: Color { color(0.045) }          // body text
    var inkStrong: Color { color(0.0) }      // titles
    var inkMuted: Color { color(0.34) }      // secondary text
    var inkFaint: Color { color(0.52) }      // tertiary text, disabled
    var rule: Color { color(0.68) }          // hairlines
    var fill: Color { color(0.76) }          // control tracks
    var fillActive: Color { color(0.18) }    // selected control

    var pageHex: String { hex(0.88) }
    var inkHex: String { hex(0.045) }
    var inkMutedHex: String { hex(0.34) }
    var ruleHex: String { hex(0.68) }
    var pageRaisedHex: String { hex(0.955) }
    var pageDimHex: String { hex(0.80) }
    var inkStrongHex: String { hex(0.0) }
}

// MARK: - math helpers

func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }
func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * clamp01(t) }

func hsbToRGB(h: Double, s: Double, b: Double) -> (Double, Double, Double) {
    if s <= 0 { return (b, b, b) }
    let hh = (h - h.rounded(.down)) * 6.0
    let i = hh.rounded(.down)
    let f = hh - i
    let p = b * (1 - s)
    let q = b * (1 - s * f)
    let t = b * (1 - s * (1 - f))
    switch Int(i) % 6 {
    case 0: return (b, t, p)
    case 1: return (q, b, p)
    case 2: return (p, b, t)
    case 3: return (p, q, b)
    case 4: return (t, p, b)
    default: return (b, p, q)
    }
}
