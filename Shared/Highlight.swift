import Foundation
import CoreGraphics

/// A passage the reader marked, and — if they said so — why.
///
/// Kept beside the article rather than inside it. `article.json` is read on every library
/// scan and rewritten on every scroll; a set of highlights is neither, and a passage of a
/// few hundred characters has no business travelling with the metadata. It lives in the
/// `highlights.json` sidecar, in the article's own folder, so it syncs and moves and is
/// deleted with the thing it belongs to and never contends with anything else.
struct Highlight: Codable, Identifiable, Hashable {
    var id = UUID()

    /// The passage, exactly as the document spells it — including whatever whitespace the
    /// saved HTML happens to carry between its elements. Verbatim because it is the
    /// anchor as well as the content: it has to match the document's own text character
    /// for character for `offset` to be checkable. Use `passage` to show it to anyone.
    var text: String

    /// What the reader wanted to remember about it. Nil until they write one.
    var note: String?

    var createdAt: Date = .now

    /// Where the passage starts, counted in characters through the document's text —
    /// the anchor for an article or a book.
    ///
    /// A character offset rather than a CSS selector or an XPath: the reader document is
    /// rebuilt from the same stored `body.html` on every open, so the text is stable, and
    /// an offset survives the things a selector does not — the emoji wrapping, the image
    /// classing, and the marks other highlights leave in the tree. It is also only a
    /// hint. If the body is ever re-extracted the offsets all shift, so the page looks
    /// for `text` and takes the occurrence nearest here rather than trusting it.
    var offset: Int?

    /// Where the passage crosses from one block of the document into the next — one
    /// paragraph into another, a paragraph into a heading — as positions in `text`,
    /// counted in UTF-16 units the way the page counts them.
    ///
    /// Needed because `text` cannot say it. It holds only what the document's text
    /// nodes spell, and a paragraph's break is not a character but the edge of an
    /// element: two paragraphs saved with nothing between their tags come out as
    /// "…the end.The next…", with neither a space nor a return to be found. Nil for a
    /// passage marked before these were kept, until the page it came off is next opened
    /// and works them out; and for a PDF, whose lines carry their own breaks.
    var breaks: [Int]?

    /// A PDF's anchor instead: the page it falls on, and the line boxes to paint, in that
    /// page's own coordinates. A PDF has no text of ours to count through.
    var pageIndex: Int?
    var boxes: [Box]?

    /// How far into the document it sits. Orders the list, and is what the library row's
    /// progress bar is measured in, so the two agree about where a passage is.
    var progress: Double = 0

    /// Which chapter it came out of, for a book — the one thing a title and a date can't
    /// say about a passage from a four-hundred-page novel.
    var chapterTitle: String?

    /// One line box of a PDF selection. `CGRect` is not `Codable` in a form that stays
    /// legible in a file meant to be read in Finder, so it is spelled out.
    struct Box: Codable, Hashable {
        var x: Double
        var y: Double
        var w: Double
        var h: Double

        init(_ r: CGRect) {
            x = r.minX; y = r.minY; w = r.width; h = r.height
        }

        var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    }

    var hasNote: Bool {
        !(note ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The passage as it should be read: a paragraph apart wherever it crossed into a new
    /// block, and within each, the document's own line breaks and indentation collapsed
    /// back into the single spaces they stood for.
    var passage: String {
        paragraphs.joined(separator: "\n\n")
    }

    /// The passage, cut at its `breaks`, each piece tidied and any left empty dropped.
    var paragraphs: [String] {
        let length = text.utf16.count
        var pieces: [Substring] = []
        var from = text.startIndex
        for cut in Set(breaks ?? []).sorted() where cut > 0 && cut < length {
            let at = text.utf16.index(text.startIndex, offsetBy: cut)
            guard at > from else { continue }
            pieces.append(text[from..<at])
            from = at
        }
        pieces.append(text[from...])
        return pieces
            .map { $0.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ") }
            .filter { !$0.isEmpty }
    }
}

/// Reads and writes an article's highlights as its `highlights.json` sidecar.
enum HighlightsFile {
    static let sidecarName = "highlights.json"

    static func read(for article: SavedArticle, store: ArticleStore) -> [Highlight] {
        guard let data = store.readSidecar(named: sidecarName, for: article) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Highlight].self, from: data)) ?? []
    }

    static func write(_ highlights: [Highlight], for article: SavedArticle, store: ArticleStore) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(highlights) else { return }
        store.writeSidecar(data, named: sidecarName, for: article)
    }
}
