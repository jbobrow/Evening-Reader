import UIKit
import SwiftUI
import UniformTypeIdentifiers

/// "Save to Evening Reader" in the share sheet — the supported way to get a page out of
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

    /// What was actually handed over: a web page (the extension's original and still
    /// primary job), or a book file, now that the activation rule accepts one.
    private enum Shared {
        case link(URL, title: String?)
        case book(URL)   // a temporary file URL; read before this run ends
    }

    private func save() async {
        guard let shared = await resolveShared() else {
            phase = .failed("Nothing to save from here.")
            finish(after: 1.5)
            return
        }

        switch shared {
        case .link(let url, let title):
            saveLink(url, title: title)
        case .book(let fileURL):
            await saveBook(fileURL)
        }
    }

    private func saveLink(_ url: URL, title: String?) {
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

    /// Reads only enough of the file to know whether it can be saved at all — the central
    /// directory and a couple of small package files — and says so plainly if not, rather
    /// than queuing something that can only fail later, silently, in the app.
    ///
    /// The extension deliberately goes no further than this: it has no iCloud entitlement
    /// and a tight memory budget, so the actual unpacking happens in the app, off the
    /// share sheet, once `drainInbox()` carries this item the rest of the way over.
    private func saveBook(_ fileURL: URL) async {
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            phase = .failed("Couldn't read that file.")
            finish(after: 1.6)
            return
        }

        do {
            let (_, package) = try EpubInspector.open(data: data)
            var article = SavedArticle(kind: .book,
                                       url: BookIdentity.url(package: package, fileData: data),
                                       title: package.title, state: .pending)
            article.byline = package.creator
            article.siteName = package.publisher
            let store = ArticleStore.shared
            store.append(article)
            guard store.adoptDocument(from: fileURL, for: article) else {
                phase = .failed("Couldn't save that book.")
                finish(after: 1.6)
                return
            }
            phase = .saved(article.title)
            finish(after: 1.1)
        } catch let failure as EpubInspector.Failure {
            phase = .failed(failure.problem.title, detail: failure.problem.detail)
            finish(after: 3.2)
        } catch {
            phase = .failed("That doesn't look like a book Evening Reader can open.")
            finish(after: 1.8)
        }
    }

    private func resolveShared() async -> Shared? {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return nil }
        let sharedTitle = items.compactMap { $0.attributedContentText?.string }
            .first { !$0.isEmpty && URL(string: $0) == nil }

        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.epub.identifier),
                   let fileURL = await Self.loadFile(provider, type: UTType.epub) {
                    return .book(fileURL)
                }
            }
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL,
                   url.scheme?.hasPrefix("http") == true {
                    return .link(url, title: sharedTitle)
                }
            }
            // Safari sometimes hands over the page as text; find a link inside it.
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
                   let url = Self.firstLink(in: text) {
                    return .link(url, title: sharedTitle)
                }
            }
        }
        return nil
    }

    /// `loadFileRepresentation` hands over a URL to a file that is deleted the moment the
    /// completion handler returns, so the copy has to happen inside it — there is no safe
    /// way to hop back to this scope first and read it later.
    private static func loadFile(_ provider: NSItemProvider, type: UTType) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { continuation.resume(returning: nil); return }
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(url.pathExtension)
                do {
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
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
    /// A headline and, for a book that was refused (locked, or a loan ticket rather than
    /// a book), the fuller explanation — too long to fit as the headline itself.
    case failed(String, detail: String? = nil)

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
        case .saved: return "Saved to Evening Reader"
        case .failed(let message, _): return message
        }
    }

    var detail: String? {
        switch self {
        case .saved(let title): return title
        case .working: return nil
        case .failed(_, let detail): return detail ?? "Try sharing the page itself."
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
                    .lineLimit(5)
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 28)
        .frame(minWidth: 280, maxWidth: 340)
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
