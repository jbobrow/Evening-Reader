import Foundation

/// The body of an article's note: the article as Markdown, below the front matter that
/// `NoteFile` writes.
///
/// The reader never renders this. It is there so the library is worth something outside
/// this app — opened as an Obsidian vault, in any editor, or read years from now by
/// something that has never heard of Evening Reader.
///
/// The Markdown itself comes from Defuddle. What is changed here is the picture links: an
/// image already pulled onto the device is pointed at the copy in the article's
/// attachments folder, by a relative path, so the note carries its own illustrations
/// wherever the library goes.
enum MarkdownSidecar {

    /// `assetsPath` is the link from the note to the article's pictures, as
    /// `ArticleStore.assetsLinkPath` gives it. Nil when there is no text to keep.
    static func body(article: SavedArticle, markdown: String,
                     assets: [String: String], assetsPath: String) -> String? {
        let body = localizeImages(in: markdown, article: article, assets: assets, assetsPath: assetsPath)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body + "\n"
    }

    // MARK: - Pictures

    /// Repoints `![alt](https://…)` at `<assetsPath>/<file>` for every picture already stored
    /// on disk. Anything not stored — too big, too many, or simply not fetched — keeps
    /// its remote URL, which is the honest thing for a link that only resolves online.
    static func localizeImages(in markdown: String, article: SavedArticle,
                               assets: [String: String], assetsPath: String) -> String {
        guard !assets.isEmpty else { return markdown }
        var byIdentity: [String: String] = [:]
        for (remote, name) in assets { byIdentity[imageIdentity(remote)] = name }
        var out = ""
        var i = markdown.startIndex

        while let bang = markdown.range(of: "![", range: i..<markdown.endIndex) {
            out += markdown[i..<bang.lowerBound]
            // An escaped `\!` is literal text, not the start of an image.
            if bang.lowerBound > markdown.startIndex,
               markdown[markdown.index(before: bang.lowerBound)] == "\\" {
                out += markdown[bang.lowerBound..<bang.upperBound]
                i = bang.upperBound
                continue
            }
            guard let close = closingBracket(in: markdown, from: bang.upperBound),
                  markdown.index(after: close) < markdown.endIndex,
                  markdown[markdown.index(after: close)] == "(",
                  let link = destination(in: markdown, from: markdown.index(close, offsetBy: 2))
            else {
                out += markdown[bang.lowerBound..<bang.upperBound]
                i = bang.upperBound
                continue
            }

            out += markdown[bang.lowerBound..<link.range.lowerBound]
            out += replacement(for: link.url, article: article,
                               assets: assets, byIdentity: byIdentity, assetsPath: assetsPath)
            i = link.range.upperBound
        }
        out += markdown[i...]
        return out
    }

    private static func replacement(for destination: String, article: SavedArticle,
                                    assets: [String: String],
                                    byIdentity: [String: String], assetsPath: String) -> String {
        // Turndown escapes parentheses in a destination; the map is keyed by the real URL.
        let bare = destination
            .replacingOccurrences(of: "\\(", with: "(")
            .replacingOccurrences(of: "\\)", with: ")")
        guard let resolved = URL(string: bare, relativeTo: article.url)?.absoluteURL else {
            return destination
        }
        let address = resolved.absoluteString
        guard let name = assets[address] ?? byIdentity[imageIdentity(address)] else {
            return destination
        }
        return "\(assetsPath)/\(name)"
    }

    /// What identifies a picture, as opposed to which copy of it was asked for.
    ///
    /// A publisher's image CDN wraps the picture's own address inside its own:
    /// `…/fetch/w_1456,f_webp/https%3A%2F%2Fmedia.example.com%2Fcat.png`. The two passes
    /// over a page pick different wrappers — one takes the `<img src>`, the other the
    /// `<picture>` source that offers WebP — while naming the same picture, and matching
    /// the wrappers letter for letter would find nothing. What survives the wrapper is
    /// the address the picture actually has.
    ///
    /// A URL with no wrapper is left as it is, minus a query string: on the CDNs that
    /// don't wrap, the requested width and format are what live there.
    private static func imageIdentity(_ url: String) -> String {
        let decoded = url.removingPercentEncoding ?? url
        var inner = decoded
        if let wrapped = decoded.range(of: "http", options: .backwards),
           wrapped.lowerBound != decoded.startIndex {
            inner = String(decoded[wrapped.lowerBound...])
        }
        if let query = inner.firstIndex(of: "?") { inner = String(inner[..<query]) }
        return inner.lowercased()
    }

    /// The `]` that closes an image's alt text, skipping over any nested brackets — an
    /// alt text is allowed to contain a link of its own.
    private static func closingBracket(in text: String, from start: String.Index) -> String.Index? {
        var depth = 1
        var i = start
        while i < text.endIndex {
            let c = text[i]
            if c == "\\" {
                i = text.index(after: i)
                if i < text.endIndex { i = text.index(after: i) }
                continue
            }
            if c == "[" { depth += 1 }
            if c == "]" {
                depth -= 1
                if depth == 0 { return i }
            }
            i = text.index(after: i)
        }
        return nil
    }

    /// The URL inside `(…)`, and the range it occupies. Handles the two forms Markdown
    /// allows: bare, and wrapped in angle brackets when the URL contains a space.
    private static func destination(in text: String,
                                    from start: String.Index) -> (url: String, range: Range<String.Index>)? {
        guard start <= text.endIndex else { return nil }
        var i = start
        if i < text.endIndex, text[i] == "<" {
            i = text.index(after: i)
            guard let end = text[i...].firstIndex(of: ">") else { return nil }
            return (String(text[i..<end]), i..<end)
        }
        var depth = 0
        while i < text.endIndex {
            let c = text[i]
            if c == "\\" {
                i = text.index(after: i)
                if i < text.endIndex { i = text.index(after: i) }
                continue
            }
            if c == "(" { depth += 1 }
            if c == ")" {
                if depth == 0 { return (String(text[start..<i]), start..<i) }
                depth -= 1
            }
            // A title follows the URL: `![alt](url "title")`.
            if c.isWhitespace { return (String(text[start..<i]), start..<i) }
            i = text.index(after: i)
        }
        return nil
    }
}
