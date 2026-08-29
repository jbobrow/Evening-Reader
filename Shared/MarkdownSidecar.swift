import Foundation

/// The portable copy of an article: `body.md`, written beside the reader's `body.html`.
///
/// The reader never opens this file. It is there so a folder in the library is worth
/// something outside this app — dropped into an Obsidian vault, opened in any editor,
/// or read years from now by something that has never heard of Amber Glow. The store
/// already treats a folder as the complete, portable thing; this is the part of it that
/// anything else can read.
///
/// The Markdown itself comes from Defuddle. What is added here is the frontmatter, and
/// the picture links: an image already pulled onto the device is pointed at the copy in
/// `assets/`, by a relative path, so the folder carries its own illustrations wherever
/// it goes.
enum MarkdownSidecar {

    static func document(article: SavedArticle, markdown: String,
                         assets: [String: String]) -> String? {
        let body = localizeImages(in: markdown, article: article, assets: assets)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return frontmatter(for: article) + "\n" + body + "\n"
    }

    // MARK: - Frontmatter

    private static func frontmatter(for article: SavedArticle) -> String {
        var lines = ["---"]
        lines.append("title: \(quoted(article.displayTitle))")
        lines.append("source: \(quoted(article.url.absoluteString))")
        if let byline = article.byline, !byline.isEmpty { lines.append("author: \(quoted(byline))") }
        if let site = article.siteName, !site.isEmpty { lines.append("site: \(quoted(site))") }
        if let published = article.publishedAt { lines.append("published: \(day(published))") }
        lines.append("saved: \(day(article.addedAt))")
        if article.wordCount > 0 { lines.append("words: \(article.wordCount)") }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n"
    }

    /// A double-quoted YAML scalar, which is the one form that needs to worry about
    /// nothing but backslashes and quotes — no leading-character rules, no colons, no
    /// guessing whether a title happens to look like a number or a date.
    private static func quoted(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }

    private static func day(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    // MARK: - Pictures

    /// Repoints `![alt](https://…)` at `assets/<file>` for every picture already stored
    /// on disk. Anything not stored — too big, too many, or simply not fetched — keeps
    /// its remote URL, which is the honest thing for a link that only resolves online.
    static func localizeImages(in markdown: String, article: SavedArticle,
                               assets: [String: String]) -> String {
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
                               assets: assets, byIdentity: byIdentity)
            i = link.range.upperBound
        }
        out += markdown[i...]
        return out
    }

    private static func replacement(for destination: String, article: SavedArticle,
                                    assets: [String: String],
                                    byIdentity: [String: String]) -> String {
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
        return "assets/\(name)"
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
