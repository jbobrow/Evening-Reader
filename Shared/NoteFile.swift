import Foundation

/// An article's note: `<Title>.md`, at the top of the library, beside the `Attachments`
/// folder that holds everything else the article needs.
///
///     The Worst Mistake in the History of the Human Race.md
///     Attachments/
///         The Worst Mistake in the History of the Human Race/
///             state.json      the app's own record of the article
///             body.html       what the reader renders
///             highlights.json
///             assets/         pictures, linked from the note by relative path
///
/// The note is the part of the library meant for people and for other apps — Obsidian
/// first among them. So it is ordinary Markdown with YAML front matter, named after the
/// title, and once it has been written the app keeps out of it: after an article is
/// fetched only `status`, `title` and `tags`, and the highlights block between its two
/// markers, are ever written again. Anything else in the file is the reader's, and stays
/// as they left it.
///
/// What ties a note to its attachments is the id in its front matter, not its name. A
/// note renamed in Finder or Obsidian is still the same article; a note without the id
/// is someone's own and is left alone.
enum NoteFile {
    static let idKey = "evening-reader-id"

    static let highlightsStart = "<!-- evening-reader:highlights -->"
    static let highlightsEnd = "<!-- /evening-reader:highlights -->"

    // MARK: - Names

    /// A title as a file name: what Finder and Obsidian will both take, and what reads as
    /// the title rather than as a slug. Characters that cannot be in a file name, or that
    /// Obsidian treats as link syntax, are taken out; a colon becomes a dash, since "Foo:
    /// Bar" is the commonest shape of a title and "Foo Bar" loses the break.
    static func fileName(for title: String) -> String {
        var out = ""
        for ch in title {
            switch ch {
            case ":": out += " -"
            case "/", "\\", "|": out += "-"
            case "*", "?", "\"", "<", ">", "#", "^", "[", "]": out += " "
            default: out.append(ch.isNewline ? " " : ch)
            }
        }
        var name = out.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        while let first = name.first, first == "." || first == "-" || first == " " { name.removeFirst() }
        // Short enough for any file system, measured in bytes since that is what they count.
        while name.utf8.count > 180 { name.removeLast() }
        while let last = name.last, last == "." || last == " " { name.removeLast() }
        return name.isEmpty ? "Untitled" : name
    }

    /// Whether `name` is `base` itself or one of the numbered names given to a second
    /// article with the same title — "Title 2", "Title 3".
    static func name(_ name: String, isVariantOf base: String) -> Bool {
        guard name != base else { return true }
        guard name.hasPrefix(base + " ") else { return false }
        let suffix = name.dropFirst(base.count + 1)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }

    /// A relative link to something in the library, each part percent-encoded so a title
    /// with spaces or parentheses in it stays one link — `Attachments/My%20Title/assets`.
    static func linkPath(_ components: [String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return components
            .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }
            .joined(separator: "/")
    }

    static func attachmentsPath(_ folderName: String, _ rest: String...) -> String {
        linkPath([ArticleStore.attachmentsName, folderName] + rest)
    }

    // MARK: - Front matter

    /// Sets every field the app owns from `article`, keeping whatever else is there.
    static func apply(_ article: SavedArticle, to fm: inout FrontMatter) {
        fm.set("title", quoted(article.displayTitle))
        fm.set("source", quoted(article.url.absoluteString))
        if let byline = article.byline, !byline.isEmpty { fm.set("author", quoted(byline)) }
        if let site = article.siteName, !site.isEmpty { fm.set("site", quoted(site)) }
        if let published = article.publishedAt { fm.set("published", day(published)) }
        fm.set("saved", moment(article.addedAt))
        if let excerpt = article.excerpt, !excerpt.isEmpty { fm.set("description", quoted(excerpt)) }
        if article.isPDF {
            if let pages = article.pageCount, pages > 0 { fm.set("pages", String(pages)) }
        } else if article.wordCount > 0 {
            fm.set("words", String(article.wordCount))
        }
        if article.isBook, let chapters = article.chapterCount, chapters > 0 {
            fm.set("chapters", String(chapters))
        }
        fm.set("status", status(of: article))
        if let tags = article.tags, !tags.isEmpty { fm.setList("tags", tags) }
        fm.set(idKey, article.id.uuidString)
        fm.arrange(first: ownedKeys, last: [idKey])
    }

    /// The app's fields, in the order a note shows them. Anything else comes after them,
    /// as it was, and the id last of all.
    static let ownedKeys = ["title", "source", "author", "site", "published", "saved", "description",
                            "words", "pages", "chapters", "status", "tags"]

    /// The three fields that go both ways, as the app would write them — compared with what
    /// a note says to know whether it needs writing at all.
    static func signature(of article: SavedArticle) -> String {
        [article.displayTitle, status(of: article), (article.tags ?? []).joined(separator: "\u{1F}")]
            .joined(separator: "\u{1E}")
    }

    static func signature(of fm: FrontMatter) -> String {
        [fm.value("title") ?? "", fm.value("status") ?? "",
         (fm.list("tags") ?? []).joined(separator: "\u{1F}")]
            .joined(separator: "\u{1E}")
    }

    /// Brings a note's title, status and tags into line with `article`. Only the lines
    /// that differ are touched.
    static func sync(_ article: SavedArticle, into fm: inout FrontMatter) {
        if fm.value("title") != article.displayTitle { fm.set("title", quoted(article.displayTitle)) }
        let status = status(of: article)
        if fm.value("status") != status { fm.set("status", status) }
        let tags = article.tags ?? []
        if (fm.list("tags") ?? []) != tags { fm.setList("tags", tags.isEmpty ? nil : tags) }
    }

    /// What the reader has done with it, in the one word a note can carry.
    static func status(of article: SavedArticle) -> String {
        if article.isArchived { return "archived" }
        return article.readAt == nil ? "unread" : "read"
    }

    /// Takes back what the reader may have changed in the note — the title, the status and
    /// the tags. A status of `read` or `archived` with no date of its own takes the date
    /// the note was last changed, which is the nearest thing to when it was said.
    static func overlay(_ fm: FrontMatter, onto article: inout SavedArticle, changed: Date) {
        if let title = fm.value("title")?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            article.title = title
        }
        switch fm.value("status")?.lowercased() {
        case "unread":
            article.isArchived = false
            article.readAt = nil
        case "read":
            article.isArchived = false
            if article.readAt == nil { article.readAt = changed }
        case "archived":
            article.isArchived = true
            if article.readAt == nil { article.readAt = changed }
        default:
            break
        }
        let tags = (fm.list("tags") ?? [])
            .map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
            .filter { !$0.isEmpty }
        article.tags = tags.isEmpty ? nil : tags
    }

    /// An article made from a note alone, for a note whose attachments are missing — the
    /// folder deleted, or not here yet. Failed rather than pending: the page can still be
    /// opened from its source, and asking for it again is the reader's call, not something
    /// to do behind their back while the real folder may be on its way down.
    static func article(from fm: FrontMatter, id: UUID, changed: Date) -> SavedArticle? {
        guard let source = fm.value("source"), let url = URL(string: source) else { return nil }
        var article = SavedArticle(url: url, title: fm.value("title") ?? "", state: .failed)
        article.id = id
        article.byline = fm.value("author")
        article.siteName = fm.value("site")
        article.excerpt = fm.value("description")
        article.wordCount = fm.value("words").flatMap(Int.init) ?? 0
        article.pageCount = fm.value("pages").flatMap(Int.init)
        article.publishedAt = fm.value("published").flatMap(parseDay)
        article.addedAt = fm.value("saved").flatMap(parseMoment) ?? changed
        return article
    }

    // MARK: - Body

    /// What a note says below its front matter when there is no Markdown of the article's
    /// own: a PDF embeds its document, a book shows its cover and links its file.
    static func defaultBody(for article: SavedArticle, folderName: String) -> String {
        if article.isPDF {
            return "![](\(attachmentsPath(folderName, "document.pdf")))\n"
        }
        if article.isBook {
            var lines: [String] = []
            if let cover = article.coverAsset {
                lines.append("![Cover](\(attachmentsPath(folderName, "assets", cover)))")
                lines.append("")
            }
            lines.append("[Open the book](\(attachmentsPath(folderName, "book.epub")))")
            return lines.joined(separator: "\n") + "\n"
        }
        return ""
    }

    static func compose(_ fm: FrontMatter, body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .newlines)
        return fm.text + (trimmed.isEmpty ? "" : "\n" + trimmed + "\n")
    }

    // MARK: - Highlights

    /// The highlights, as the block that ends a note: each passage quoted, its chapter
    /// under it for a book, and the reader's note after it as a paragraph of its own.
    static func highlightsSection(_ highlights: [Highlight]) -> String? {
        guard !highlights.isEmpty else { return nil }
        var lines = [highlightsStart, "## Highlights", ""]
        for highlight in highlights {
            let quote = highlight.paragraphs.map { "> " + $0 }.joined(separator: "\n>\n")
            guard !quote.isEmpty else { continue }
            lines.append(quote)
            if let chapter = highlight.chapterTitle, !chapter.isEmpty {
                lines.append(">")
                lines.append("> — *\(chapter)*")
            }
            lines.append("")
            if highlight.hasNote, let note = highlight.note {
                lines.append(note.trimmingCharacters(in: .whitespacesAndNewlines))
                lines.append("")
            }
        }
        if lines.last == "" { lines.removeLast() }
        lines.append(highlightsEnd)
        return lines.joined(separator: "\n")
    }

    /// The block as it stands in a note, markers and all, or nil.
    static func highlightsBlock(in body: String) -> Substring? {
        guard let start = body.range(of: highlightsStart),
              let end = body.range(of: highlightsEnd, range: start.upperBound..<body.endIndex)
        else { return nil }
        return body[start.lowerBound..<end.upperBound]
    }

    /// `body` with its highlights block replaced by `section` — added at the end if there
    /// was none, taken out if `section` is nil. Nothing outside the markers is touched.
    static func replacingHighlights(in body: String, with section: String?) -> String {
        if let block = highlightsBlock(in: body) {
            var out = body
            out.replaceSubrange(block.startIndex..<block.endIndex, with: section ?? "")
            if section == nil {
                out = out.trimmingCharacters(in: .newlines)
                return out.isEmpty ? "" : out + "\n"
            }
            return out
        }
        guard let section else { return body }
        let kept = body.trimmingCharacters(in: .newlines)
        return (kept.isEmpty ? "" : kept + "\n\n") + section + "\n"
    }

    // MARK: - Values

    /// A double-quoted YAML scalar, which is the one form that needs to worry about
    /// nothing but backslashes and quotes — no leading-character rules, no colons, no
    /// guessing whether a title happens to look like a number or a date.
    static func quoted(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }

    static func day(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    /// To the minute, in the reader's own time, in the form Obsidian shows as a date and
    /// time. The exact moment is in `state.json`; this is the one a person reads.
    static func moment(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter.string(from: date)
    }

    static func parseDay(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(text.prefix(10)))
    }

    static func parseMoment(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter.date(from: String(text.prefix(16))) ?? parseDay(text)
    }
}

/// A note's YAML front matter, kept as the lines it was written in.
///
/// Not a YAML parser. It reads the shapes front matter actually takes — `key: value`,
/// quoted or plain, and lists written either `[a, b]` or as `- a` lines — and when it
/// changes a field it replaces that field's lines and nothing else, so what a person or
/// another app wrote around it comes through exactly as it was.
struct FrontMatter: Equatable {
    private(set) var lines: [String]

    init(lines: [String] = []) {
        self.lines = lines
    }

    /// A note's front matter and the rest of it. No front matter when the note does not
    /// open with a `---` line or never closes it.
    static func split(_ text: String) -> (frontMatter: FrontMatter?, body: String) {
        var all = text.components(separatedBy: "\n")
        if all.first?.hasSuffix("\r") == true { all = all.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 } }
        guard all.first == "---",
              let end = all.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." })
        else { return (nil, text) }
        let block = Array(all[1..<end])
        var rest = Array(all[(end + 1)...])
        if rest.first == "" { rest.removeFirst() }
        return (FrontMatter(lines: block), rest.joined(separator: "\n"))
    }

    var text: String {
        (["---"] + lines + ["---"]).joined(separator: "\n") + "\n"
    }

    /// Where a key's lines are: its own line, and any indented or `- ` lines under it.
    private func entry(_ key: String) -> Range<Int>? {
        guard let start = lines.firstIndex(where: { line in
            line.hasPrefix(key + ":") && (line.count == key.count + 1
                || line[line.index(line.startIndex, offsetBy: key.count + 1)].isWhitespace)
        }) else { return nil }
        var end = start + 1
        while end < lines.count {
            let line = lines[end]
            guard line.hasPrefix(" ") || line.hasPrefix("\t") || line.hasPrefix("-") else { break }
            end += 1
        }
        return start..<end
    }

    private func inline(_ key: String) -> String? {
        guard let range = entry(key) else { return nil }
        let line = lines[range.lowerBound]
        return String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
    }

    func value(_ key: String) -> String? {
        guard let raw = inline(key), !raw.isEmpty else { return nil }
        let text = Self.unquote(raw)
        return text.isEmpty ? nil : text
    }

    func list(_ key: String) -> [String]? {
        guard let range = entry(key), let raw = inline(key) else { return nil }
        if raw.hasPrefix("["), raw.hasSuffix("]") {
            return raw.dropFirst().dropLast()
                .split(separator: ",")
                .map { Self.unquote($0.trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.isEmpty }
        }
        if !raw.isEmpty { return [Self.unquote(raw)] }
        return lines[(range.lowerBound + 1)..<range.upperBound].compactMap { line in
            let item = line.trimmingCharacters(in: .whitespaces)
            guard item.hasPrefix("-") else { return nil }
            let text = Self.unquote(item.dropFirst().trimmingCharacters(in: .whitespaces))
            return text.isEmpty ? nil : text
        }
    }

    /// Sets `key` to a value already written as YAML, or takes the key out when nil.
    mutating func set(_ key: String, _ value: String?) {
        replace(key, with: value.map { ["\(key): \($0)"] } ?? [])
    }

    /// Sets `key` to a list, one `- item` line each, the way Obsidian writes them.
    mutating func setList(_ key: String, _ items: [String]?) {
        guard let items else { replace(key, with: []); return }
        replace(key, with: ["\(key):"] + items.map { "  - " + NoteFile.quoted($0) })
    }

    /// Puts the `first` keys at the top in that order and the `last` ones at the end, and
    /// everything else between them in the order it was in.
    mutating func arrange(first: [String], last: [String]) {
        var entries: [(key: String?, lines: [String])] = []
        for line in lines {
            let continues = line.hasPrefix(" ") || line.hasPrefix("\t") || line.hasPrefix("-")
            if continues, !entries.isEmpty {
                entries[entries.count - 1].lines.append(line)
            } else {
                let key = line.firstIndex(of: ":").map { String(line[..<$0]) }
                entries.append((key, [line]))
            }
        }
        func rank(_ key: String?) -> Int {
            guard let key else { return first.count }
            if let i = first.firstIndex(of: key) { return i }
            if let i = last.firstIndex(of: key) { return first.count + 1 + i }
            return first.count
        }
        let ordered = entries.enumerated()
            .sorted { (rank($0.element.key), $0.offset) < (rank($1.element.key), $1.offset) }
        lines = ordered.flatMap(\.element.lines)
    }

    private mutating func replace(_ key: String, with new: [String]) {
        if let range = entry(key) {
            lines.replaceSubrange(range, with: new)
        } else {
            lines.append(contentsOf: new)
        }
    }

    static func unquote(_ raw: String) -> String {
        if raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") {
            var out = ""
            var escaping = false
            for ch in raw.dropFirst().dropLast() {
                if escaping {
                    switch ch {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    default: out.append(ch)
                    }
                    escaping = false
                } else if ch == "\\" {
                    escaping = true
                } else {
                    out.append(ch)
                }
            }
            return out
        }
        if raw.count >= 2, raw.hasPrefix("'"), raw.hasSuffix("'") {
            return String(raw.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        // A plain scalar ends where a comment begins.
        if let hash = raw.range(of: " #") { return String(raw[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces) }
        return raw
    }
}
