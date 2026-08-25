import UIKit
import SwiftUI
import UniformTypeIdentifiers

/// "Save to Amber Glow" in the share sheet — the supported way to get a page out of
/// Safari (including one opened from the Reading List) and into the library.
final class ShareViewController: UIViewController {

    private var phase: SavePhase = .working {
        didSet { host?.rootView = SaveCard(phase: phase, palette: palette) }
    }

    private var host: UIHostingController<SaveCard>?

    /// Follow whatever warmth the user last set in the app.
    private lazy var palette: AmberPalette = {
        let defaults = UserDefaults(suiteName: ArticleStore.appGroupID) ?? .standard
        let warmth = defaults.object(forKey: "display.warmth") as? Double ?? 0.62
        let glow = defaults.object(forKey: "display.glow") as? Double ?? 0.85
        let polarity = AmberPalette.Polarity(
            rawValue: defaults.string(forKey: "display.polarity") ?? "") ?? .paper
        return AmberPalette(warmth: warmth, glow: glow, contrast: 0.5, polarity: polarity)
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        let controller = UIHostingController(rootView: SaveCard(phase: phase, palette: palette))
        controller.view.backgroundColor = .clear
        addChild(controller)
        view.addSubview(controller.view)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            controller.view.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            controller.view.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            controller.view.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor)
        ])
        controller.didMove(toParent: self)
        host = controller

        Task { await save() }
    }

    private func save() async {
        guard let (url, title) = await resolveSharedLink() else {
            phase = .failed("Nothing to save from here.")
            finish(after: 1.5)
            return
        }

        var article = SavedArticle(url: url, title: title ?? "")
        if article.title.isEmpty {
            article.title = url.host?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString
        }
        article.siteName = url.host?.replacingOccurrences(of: "www.", with: "")
        article.state = .pending
        ArticleStore.shared.append(article)

        phase = .saved(article.title)
        finish(after: 1.1)
    }

    private func resolveSharedLink() async -> (URL, String?)? {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return nil }
        let sharedTitle = items.compactMap { $0.attributedContentText?.string }
            .first { !$0.isEmpty && URL(string: $0) == nil }

        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL,
                   url.scheme?.hasPrefix("http") == true {
                    return (url, sharedTitle)
                }
            }
            // Safari sometimes hands over the page as text; find a link inside it.
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
                   let url = Self.firstLink(in: text) {
                    return (url, sharedTitle)
                }
            }
        }
        return nil
    }

    private static func firstLink(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = detector?.firstMatch(in: text, options: [], range: range),
              let url = match.url, url.scheme?.hasPrefix("http") == true else { return nil }
        return url
    }

    private func finish(after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }
}

// MARK: - Card

enum SavePhase: Equatable {
    case working
    case saved(String)
    case failed(String)

    var symbol: String {
        switch self {
        case .working: return "text.viewfinder"
        case .saved: return "checkmark.circle"
        case .failed: return "exclamationmark.circle"
        }
    }

    var headline: String {
        switch self {
        case .working: return "Saving…"
        case .saved: return "Saved to Amber Glow"
        case .failed(let message): return message
        }
    }

    var detail: String? {
        switch self {
        case .saved(let title): return title
        case .working: return nil
        case .failed: return "Try sharing the page itself."
        }
    }
}

private struct SaveCard: View {
    let phase: SavePhase
    let palette: AmberPalette

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: phase.symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(palette.color(0.10))
            Text(phase.headline)
                .font(.system(size: 17, weight: .medium, design: .serif))
                .foregroundStyle(palette.color(0.02))
                .multilineTextAlignment(.center)
            if let detail = phase.detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.color(0.34))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 28)
        .frame(minWidth: 280)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(palette.color(0.88))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(palette.color(0.62), lineWidth: 1)
                )
                .shadow(color: palette.color(0.95, opacity: 0.5), radius: 30)
        )
        .padding(24)
    }
}
