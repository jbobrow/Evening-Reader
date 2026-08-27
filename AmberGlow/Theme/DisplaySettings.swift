import SwiftUI
import UIKit
import Observation

/// A remembered glow. Only the panel settings — type and texture are separate concerns
/// the user is unlikely to want bundled into a lighting preset.
struct GlowPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var warmth: Double
    var glow: Double
    var contrast: Double
    var polarity: AmberPalette.Polarity
}

/// Everything the user can dial about the panel and the type, persisted immediately.
@Observable
final class DisplaySettings {

    /// How the reader reports where you are.
    enum ProgressStyle: String, Codable, CaseIterable, Identifiable {
        case percent, pages
        var id: String { rawValue }
        var label: String { self == .percent ? "Percent" : "Pages" }
    }

    enum Typeface: String, Codable, CaseIterable, Identifiable {
        case serif, sans, mono
        var id: String { rawValue }
        var label: String {
            switch self {
            case .serif: return "Serif"
            case .sans: return "Sans"
            case .mono: return "Mono"
            }
        }
        var design: Font.Design {
            switch self {
            case .serif: return .serif
            case .sans: return .default
            case .mono: return .monospaced
            }
        }
        /// The same face `design` selects, as a `UIFont`. The specimen needs it to know
        /// how tall a line of this face actually is — SwiftUI will not say.
        func uiFont(size: CGFloat) -> UIFont {
            switch self {
            case .sans: return .systemFont(ofSize: size)
            case .mono: return .monospacedSystemFont(ofSize: size, weight: .regular)
            case .serif:
                let base = UIFont.systemFont(ofSize: size)
                guard let serif = base.fontDescriptor.withDesign(.serif) else { return base }
                return UIFont(descriptor: serif, size: size)
            }
        }

        /// CSS stack used inside the reader.
        var cssStack: String {
            switch self {
            case .serif: return "ui-serif, 'New York', Georgia, 'Times New Roman', serif"
            case .sans: return "-apple-system, ui-sans-serif, 'Helvetica Neue', sans-serif"
            case .mono: return "ui-monospace, 'SF Mono', Menlo, monospace"
            }
        }
    }

    var warmth: Double { didSet { write(warmth, "warmth") } }
    var glow: Double { didSet { write(glow, "glow") } }
    var contrast: Double { didSet { write(contrast, "contrast") } }
    var polarity: AmberPalette.Polarity { didSet { write(polarity.rawValue, "polarity") } }

    var textScale: Double { didSet { write(textScale, "textScale") } }
    var lineHeight: Double { didSet { write(lineHeight, "lineHeight") } }
    var measure: Double { didSet { write(measure, "measure") } }
    var typeface: Typeface { didSet { write(typeface.rawValue, "typeface") } }

    /// The faint pixel grid that makes the page read as an emissive panel.
    var showTexture: Bool { didSet { write(showTexture, "showTexture") } }
    /// Backlight bloom in the corners of the page.
    var showBloom: Bool { didSet { write(showBloom, "showBloom") } }
    /// Percent read, or which screenful you are on.
    var progressStyle: ProgressStyle { didSet { write(progressStyle.rawValue, "progressStyle") } }

    /// Glows the user has kept, most recent first.
    var presets: [GlowPreset] { didSet { writePresets() } }

    private let defaults: UserDefaults
    private static let prefix = "display."

    /// Where the settings are kept: the shared suite when the app group is really there,
    /// and the app's own otherwise.
    ///
    /// The test has to be the container, not the suite. `UserDefaults(suiteName:)` hands
    /// back a usable object whether or not the group has been provisioned to this build,
    /// so `?? .standard` never fires — and when the group is not there, what comes back
    /// writes to somewhere the sandbox refuses. The settings then hold for as long as the
    /// app is running and are gone by the next launch, with nothing anywhere to say why.
    ///
    /// `containerURL(forSecurityApplicationGroupIdentifier:)` is what actually answers
    /// the question, and is the test the store has always made — which is why a library
    /// survived a build with no group and the glow it was read in did not.
    ///
    /// The suite is still preferred where it exists: the share extension draws its card
    /// from these same values, so that it arrives in the glow the reader set.
    static func store() -> UserDefaults {
        guard FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: ArticleStore.appGroupID) != nil,
              let shared = UserDefaults(suiteName: ArticleStore.appGroupID)
        else { return .standard }
        return shared
    }

    init(defaults: UserDefaults = DisplaySettings.store()) {
        self.defaults = defaults
        func d(_ key: String, _ fallback: Double) -> Double {
            defaults.object(forKey: Self.prefix + key) as? Double ?? fallback
        }
        warmth = d("warmth", Self.defaultWarmth)
        glow = d("glow", Self.defaultGlow)
        contrast = d("contrast", Self.defaultContrast)
        polarity = AmberPalette.Polarity(
            rawValue: defaults.string(forKey: Self.prefix + "polarity") ?? ""
        ) ?? .paper
        textScale = d("textScale", 1.0)
        lineHeight = d("lineHeight", 1.62)
        measure = d("measure", Self.defaultMeasure)
        typeface = Typeface(
            rawValue: defaults.string(forKey: Self.prefix + "typeface") ?? ""
        ) ?? .serif
        showTexture = defaults.object(forKey: Self.prefix + "showTexture") as? Bool ?? true
        showBloom = defaults.object(forKey: Self.prefix + "showBloom") as? Bool ?? true
        progressStyle = ProgressStyle(
            rawValue: defaults.string(forKey: Self.prefix + "progressStyle") ?? ""
        ) ?? .percent
        presets = (defaults.data(forKey: Self.prefix + "presets"))
            .flatMap { try? JSONDecoder().decode([GlowPreset].self, from: $0) } ?? []
    }

    private func writePresets() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: Self.prefix + "presets")
    }

    private func write(_ value: Any, _ key: String) {
        defaults.set(value, forKey: Self.prefix + key)
    }

    var palette: AmberPalette {
        AmberPalette(warmth: warmth, glow: glow, contrast: contrast, polarity: polarity)
    }

    /// Body point size the reader and the lists share.
    var bodyPointSize: Double { 17.0 * textScale }

    /// Reader column width in points, from ~34em to ~52em of comfortable measure.
    var readerColumnPoints: Double { lerp(600, 860, measure) }

    // MARK: - Defaults

    static let defaultWarmth = 0.87    // the top of "Deep amber"
    static let defaultGlow = 0.80
    static let defaultContrast = 0.30
    /// Yields a 680pt default column, in the 600–860 range `readerColumnPoints` maps.
    static let defaultMeasure = (680.0 - 600.0) / (860.0 - 600.0)

    /// True when the panel is already sitting on the shipped defaults.
    var isDefaultPanel: Bool {
        abs(warmth - Self.defaultWarmth) < 0.005
            && abs(glow - Self.defaultGlow) < 0.005
            && abs(contrast - Self.defaultContrast) < 0.005
            && polarity == .paper
    }

    func resetPanel() {
        warmth = Self.defaultWarmth
        glow = Self.defaultGlow
        contrast = Self.defaultContrast
        polarity = .paper
    }

    // MARK: - Presets

    /// Names itself the way the slider describes itself, so a saved glow is recognisable
    /// without the user having to type anything.
    var suggestedPresetName: String {
        var parts = [palette.warmthName, "\(Int((glow * 100).rounded()))%"]
        if polarity == .night { parts.append("Night") }
        return parts.joined(separator: " · ")
    }

    var currentIsSaved: Bool {
        presets.contains { matches($0) }
    }

    func matches(_ preset: GlowPreset) -> Bool {
        abs(preset.warmth - warmth) < 0.005
            && abs(preset.glow - glow) < 0.005
            && abs(preset.contrast - contrast) < 0.005
            && preset.polarity == polarity
    }

    func savePreset() {
        guard !currentIsSaved else { return }
        var name = suggestedPresetName
        // Two glows can describe themselves identically; keep the names distinguishable.
        if presets.contains(where: { $0.name == name }) {
            var n = 2
            while presets.contains(where: { $0.name == "\(name) (\(n))" }) { n += 1 }
            name = "\(name) (\(n))"
        }
        presets.insert(GlowPreset(name: name, warmth: warmth, glow: glow,
                                  contrast: contrast, polarity: polarity), at: 0)
    }

    func apply(_ preset: GlowPreset) {
        warmth = preset.warmth
        glow = preset.glow
        contrast = preset.contrast
        polarity = preset.polarity
    }

    func delete(_ preset: GlowPreset) {
        presets.removeAll { $0.id == preset.id }
    }
}

// MARK: - Environment

private struct AmberPaletteKey: EnvironmentKey {
    static let defaultValue = AmberPalette()
}

extension EnvironmentValues {
    var amber: AmberPalette {
        get { self[AmberPaletteKey.self] }
        set { self[AmberPaletteKey.self] = newValue }
    }
}
