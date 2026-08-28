import Foundation
import Observation

/// Everything the reader has marked, across the library.
///
/// A companion to `Library` rather than part of it. Highlights are read from a different
/// file, on a different schedule — nothing needs them until a page is open or the list is
/// asked for — and folding them into `Library.articles` would put a passage of prose into
/// the record that is rewritten every time a page is scrolled.
///
/// The cache is per article and filled on first ask. `forget()` drops it, which is what
/// happens when iCloud brings something new down: a folder is only ever written whole, so
/// what arrived is right and what is held is stale.
@MainActor
@Observable
final class Highlights {
    private let store: ArticleStore
    private var cache: [UUID: [Highlight]] = [:]

    init(store: ArticleStore = .shared) {
        self.store = store
    }

    // MARK: - Reading

    /// One article's marks, in the order they appear on the page.
    func list(for article: SavedArticle) -> [Highlight] {
        if let held = cache[article.id] { return held }
        let found = HighlightsFile.read(for: article, store: store).sorted(by: Self.inPageOrder)
        cache[article.id] = found
        return found
    }

    func count(for article: SavedArticle) -> Int { list(for: article).count }

    /// Everything, newest first, each paired with the article it came out of. Walks the
    /// whole library, so it is asked for when the highlights list opens and not before.
    func all(in articles: [SavedArticle]) -> [(article: SavedArticle, highlight: Highlight)] {
        articles
            .flatMap { article in list(for: article).map { (article: article, highlight: $0) } }
            .sorted { $0.highlight.createdAt > $1.highlight.createdAt }
    }

    func highlight(_ id: UUID, in article: SavedArticle) -> Highlight? {
        list(for: article).first { $0.id == id }
    }

    // MARK: - Writing

    @discardableResult
    func add(_ highlight: Highlight, to article: SavedArticle) -> Highlight {
        var all = list(for: article)
        all.append(highlight)
        commit(all, for: article)
        return highlight
    }

    func setNote(_ note: String?, on id: UUID, in article: SavedArticle) {
        var all = list(for: article)
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        all[i].note = (trimmed?.isEmpty ?? true) ? nil : trimmed
        commit(all, for: article)
    }

    func remove(_ id: UUID, from article: SavedArticle) {
        let all = list(for: article).filter { $0.id != id }
        commit(all, for: article)
    }

    /// Drops what is held so the next ask reads the folder again.
    func forget() { cache.removeAll() }

    private func commit(_ all: [Highlight], for article: SavedArticle) {
        let ordered = all.sorted(by: Self.inPageOrder)
        cache[article.id] = ordered
        HighlightsFile.write(ordered, for: article, store: store)
    }

    /// Down the page, then by when they were made — which is the order they are drawn in
    /// and the order the contents-style list reads best in.
    private static func inPageOrder(_ a: Highlight, _ b: Highlight) -> Bool {
        let left = a.offset ?? a.pageIndex ?? 0
        let right = b.offset ?? b.pageIndex ?? 0
        if left != right { return left < right }
        return a.createdAt < b.createdAt
    }
}
