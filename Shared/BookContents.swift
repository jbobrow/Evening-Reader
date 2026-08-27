import Foundation

/// Reads and writes a book's table of contents as the `contents.json` sidecar.
///
/// Kept out of `SavedArticle` itself: a densely-sectioned book can carry several hundred
/// entries, and `article.json` is pretty-printed, read on every library scan, and synced —
/// none of which a TOC benefits from sharing. It is written once, at import, and never
/// touched again.
enum BookContents {
    static let sidecarName = "contents.json"

    static func write(_ chapters: [BookChapter], for article: SavedArticle, store: ArticleStore) {
        guard let data = try? JSONEncoder().encode(chapters) else { return }
        store.writeSidecar(data, named: sidecarName, for: article)
    }

    static func read(for article: SavedArticle, store: ArticleStore) -> [BookChapter] {
        guard let data = store.readSidecar(named: sidecarName, for: article),
              let chapters = try? JSONDecoder().decode([BookChapter].self, from: data) else { return [] }
        return chapters
    }
}
