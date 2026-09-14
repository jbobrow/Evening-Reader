import Foundation

/// Turns a book's spine into the same shape an article already comes in: one HTML
/// fragment, with its pictures pulled onto disk and pointed at through `amber-asset://`.
///
/// This is string surgery on the content documents, not an XML round trip — see the
/// primitives borrowed from `OfflineAssets` for why. It is deliberately forgiving: a
/// malformed tag in chapter twelve should cost that chapter, never the book.
enum EpubFlattener {
    struct Result {
        var html: String
        var wordCount: Int
        var coverAssetName: String?
        /// `"ag-line"` or `"ag-photo"`, from the same drawing-or-photograph judgment every
        /// other picture in the book gets — a cover is drawn full colour on a bookstore
        /// shelf, not for a reader that inks its pictures, and needs the same look-once
        /// decision about whether inverting it at night will help or ruin it.
        var coverAssetClass: String?
        /// The book's table of contents, with each entry's href rewritten to an anchor
        /// inside the flattened document (`"ag-c4"` or `"ag-c4-note7"`).
        var chapters: [BookChapter]
    }

    static func flatten(archive: ZipArchive, package: EpubPackage,
                        article: SavedArticle, store: ArticleStore) -> Result {
        // The reading order is the linear spine, with anything `linear="no"` — almost
        // always footnote or endnote targets — appended at the end rather than dropped,
        // so a link into one still lands somewhere instead of nowhere.
        var linear: [(path: String, href: String)] = []
        var nonlinear: [(path: String, href: String)] = []
        for ref in package.spine {
            guard let item = package.manifest[ref.idref],
                  let path = ZipArchive.resolve(item.href, from: package.opfDirectory) else { continue }
            if ref.linear { linear.append((path, item.href)) } else { nonlinear.append((path, item.href)) }
        }
        let ordered = linear + nonlinear
        guard !ordered.isEmpty else {
            return Result(html: "", wordCount: 0, coverAssetName: nil, coverAssetClass: nil, chapters: [])
        }

        var pathToID: [String: String] = [:]
        for (i, entry) in ordered.enumerated() { pathToID[entry.path] = "ag-c\(i)" }

        struct Doc { let id, path, directory, body: String }
        var docs: [Doc] = []
        for entry in ordered {
            guard let raw = try? archive.text(at: entry.path) else { continue }
            docs.append(Doc(id: pathToID[entry.path]!, path: entry.path,
                            directory: ZipArchive.directory(of: entry.path),
                            body: extractBody(raw)))
        }
        guard !docs.isEmpty else {
            return Result(html: "", wordCount: 0, coverAssetName: nil, coverAssetClass: nil, chapters: [])
        }

        // Pass 1: which ids are actually the target of a link, so pass 2 only has to
        // namespace those rather than every id in the book.
        var wanted: [String: Set<String>] = [:]
        for doc in docs {
            collectAnchorTargets(in: doc.body, selfPath: doc.path, directory: doc.directory, into: &wanted)
        }
        for entry in package.toc {
            let parts = entry.href.components(separatedBy: "#")
            guard parts.count > 1 else { continue }
            wanted[parts[0], default: []].insert(parts[1])
        }

        // The book's own declared TOC, indexed for the merge below rather than used
        // as-is: a Gutenberg-style conversion routinely names a handful of front-matter
        // pages and leaves the book's real section headers — which do exist, as
        // headings, right there in the text — unlinked entirely. `collectHeadings`
        // finds those once each chapter is rewritten; what happens here is deciding how
        // a declared entry and a detected heading that turn out to be the same place
        // reconcile, and what happens to a declared entry that isn't on a heading at all.
        var declaredByAnchor: [String: BookChapter] = [:]
        var wholeChapterEntry: [String: BookChapter] = [:]   // chapterID -> entry, no fragment
        var chapterTitle: [String: String] = [:]             // chapterID -> title, whole-chapter entries only
        for entry in package.toc {
            let parts = entry.href.components(separatedBy: "#")
            guard let chapterID = pathToID[parts[0]] else { continue }
            let anchor = parts.count > 1 ? "\(chapterID)-\(namespaced(parts[1]))" : chapterID
            let declared = BookChapter(title: entry.title, href: anchor, depth: entry.depth)
            declaredByAnchor[anchor] = declared
            if parts.count == 1 {
                wholeChapterEntry[chapterID] = declared
                if chapterTitle[chapterID] == nil { chapterTitle[chapterID] = entry.title }
            }
        }

        // The cover, resolved directly from the manifest rather than from whatever the
        // first chapter's markup happens to do with it — plenty of books declare one
        // that is never referenced inline at all.
        var coverAssetName: String?
        var coverAssetClass: String?
        if let coverID = package.coverImageID, let coverItem = package.manifest[coverID],
           let coverPath = ZipArchive.resolve(coverItem.href, from: package.opfDirectory),
           let data = try? archive.data(at: coverPath), !data.isEmpty {
            coverAssetName = store.writeAsset(
                data, ext: OfflineAssets.extensionFor(pathURL(coverPath), data: data), for: article)
            coverAssetClass = OfflineAssets.classify(data)
        }

        var output = ""
        var wordCount = 0
        var chapters: [BookChapter] = []
        for doc in docs {
            let wantedHere = wanted[doc.path] ?? []
            var rewritten = rewrite(doc.body, chapterID: doc.id, directory: doc.directory,
                                    pathToID: pathToID, wantedIDs: wantedHere,
                                    archive: archive, article: article, store: store)
            // The cover is shown once, at the head of the book. Most books also put it
            // on their first page — Gutenberg's do, and the standard cover page is
            // nothing else — and it came through above as the same picture, under the
            // same name, since an asset is named by its bytes. Taken out wherever it
            // appears; a page that was only the cover is then not a page at all.
            if let cover = coverAssetName {
                rewritten = removingImage(named: cover, article: article, from: rewritten)
                if isBlank(rewritten) { continue }
            }
            wordCount += countWords(in: rewritten)

            // A chapter's contribution to the sheet: its own whole-chapter entry, if the
            // TOC has one, followed by every heading actually found inside it — in the
            // order they occur, which is what makes a chapter with real structure read as
            // one. A heading the TOC already named keeps that wording; everything else
            // gets its own text, which is a real improvement over not being listed at all.
            var consumed: Set<String> = []
            // A whole-chapter link almost always names the same heading the chapter
            // opens with — so once it is added, the chapter's first detected heading is
            // what it was already about, not a second, different section.
            var skipOpeningHeading = false
            if let whole = wholeChapterEntry[doc.id] {
                chapters.append(whole)
                consumed.insert(doc.id)
                skipOpeningHeading = true
            }
            for heading in collectHeadings(in: rewritten) {
                consumed.insert(heading.id)
                if skipOpeningHeading { skipOpeningHeading = false; continue }
                let title = declaredByAnchor[heading.id]?.title ?? heading.text
                chapters.append(BookChapter(title: title, href: heading.id, depth: min(heading.level - 1, 3)))
            }
            // A declared entry that points somewhere other than a heading — rare, but
            // real (this app's own Gutenberg test fixture has exactly one, a footnote
            // paragraph) — still deserves a way in, even without a heading's position to
            // sort it by.
            for entry in package.toc {
                let parts = entry.href.components(separatedBy: "#")
                guard parts.count > 1, pathToID[parts[0]] == doc.id else { continue }
                let anchor = "\(doc.id)-\(namespaced(parts[1]))"
                guard !consumed.contains(anchor) else { continue }
                chapters.append(BookChapter(title: entry.title, href: anchor, depth: entry.depth))
                consumed.insert(anchor)
            }

            output += "<section class=\"ag-chapter\" id=\"\(doc.id)\" data-src=\"\(escapeAttr(doc.path))\">\n"
            if let title = chapterTitle[doc.id], !startsWithHeading(rewritten) {
                output += "<h2 class=\"ag-chapter-title\">\(ReaderRenderer.escape(title))</h2>\n"
            }
            output += rewritten
            output += "\n</section>\n"
        }

        if chapters.isEmpty {
            // No declared TOC, no NCX, and not one heading with text anywhere in the
            // book — genuinely nothing to build a contents list from. One entry per
            // spine item beats an empty sheet.
            chapters = docs.enumerated().map { i, doc in
                BookChapter(title: "Chapter \(i + 1)", href: doc.id, depth: 0)
            }
        }

        return Result(html: output, wordCount: wordCount, coverAssetName: coverAssetName,
                     coverAssetClass: coverAssetClass, chapters: chapters)
    }

    // MARK: - Body extraction

    private static func extractBody(_ raw: String) -> String {
        guard let openRange = raw.range(of: "<body", options: .caseInsensitive),
              let tagEnd = OfflineAssets.endOfTag(in: Substring(raw), from: openRange.upperBound)
        else { return raw }
        let (inner, _) = consumeElement(named: "body", in: raw[tagEnd...])
        return inner
    }

    // MARK: - Pass 1: anchor targets

    private static func collectAnchorTargets(in body: String, selfPath: String, directory: String,
                                             into wanted: inout [String: Set<String>]) {
        forEachTag(named: "a", in: Substring(body)) { tag in
            guard let href = OfflineAssets.value(of: "href", in: tag) else { return }
            let trimmed = href.trimmingCharacters(in: .whitespaces)
            guard !isExternal(trimmed) else { return }

            if trimmed.hasPrefix("#") {
                let frag = String(trimmed.dropFirst())
                guard !frag.isEmpty else { return }
                wanted[selfPath, default: []].insert(frag)
                return
            }
            let parts = trimmed.components(separatedBy: "#")
            guard parts.count > 1, let targetPath = ZipArchive.resolve(parts[0], from: directory) else { return }
            wanted[targetPath, default: []].insert(parts[1])
        }
    }

    // MARK: - Pass 2: rewrite

    private static let headingTags: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]

    private static func rewrite(_ html: String, chapterID: String, directory: String,
                                pathToID: [String: String], wantedIDs: Set<String>,
                                archive: ZipArchive, article: SavedArticle, store: ArticleStore) -> String {
        var out = ""
        var rest = Substring(html)
        var headingCounter = 0

        while let ltRange = rest.range(of: "<") {
            out += rest[rest.startIndex..<ltRange.lowerBound]
            rest = rest[ltRange.lowerBound...]

            if rest.hasPrefix("<!--") {
                if let end = rest.range(of: "-->") { rest = rest[end.upperBound...] } else { rest = Substring("") }
                continue
            }
            if rest.hasPrefix("<!") {
                // A stray DOCTYPE or CDATA marker in a content document. Drop just the
                // marker itself.
                guard let tagEnd = OfflineAssets.endOfTag(in: rest, from: rest.index(after: rest.startIndex))
                else { break }
                rest = rest[tagEnd...]
                continue
            }
            if rest.hasPrefix("</") {
                guard let tagEnd = OfflineAssets.endOfTag(in: rest, from: rest.index(rest.startIndex, offsetBy: 2))
                else { out += rest; rest = Substring(""); continue }
                out += rest[rest.startIndex..<tagEnd]
                rest = rest[tagEnd...]
                continue
            }

            guard let tagEnd = OfflineAssets.endOfTag(in: rest, from: rest.index(after: rest.startIndex))
            else { out += rest; rest = Substring(""); break }
            let tag = String(rest[rest.startIndex..<tagEnd])
            let name = tagName(of: tag).lowercased()
            rest = rest[tagEnd...]

            switch name {
            case "script", "style":
                let (_, remainder) = consumeElement(named: name, in: rest)
                rest = remainder
            case "link":
                break   // a void element; the tag itself is already consumed
            case "svg":
                let (replacement, remainder) = rewriteCoverSVG(rest: rest, directory: directory,
                                                               archive: archive, article: article, store: store)
                out += replacement
                rest = remainder
            case "img":
                out += rewriteImage(tag: tag, directory: directory, archive: archive,
                                    article: article, store: store)
            case "a":
                out += rewriteAnchor(tag: tag, chapterID: chapterID, directory: directory,
                                     pathToID: pathToID, wantedIDs: wantedIDs)
            case let h where headingTags.contains(h):
                out += rewriteHeading(tag: tag, chapterID: chapterID, headingCounter: &headingCounter)
            default:
                out += rewriteGeneric(tag: tag, chapterID: chapterID, wantedIDs: wantedIDs)
            }
        }
        out += rest
        return out
    }

    private static func rewriteGeneric(tag: String, chapterID: String, wantedIDs: Set<String>) -> String {
        var t = OfflineAssets.removeAttribute("style", from: tag)
        t = stripEventHandlers(t)
        t = namespaceOrDropID(t, chapterID: chapterID, wantedIDs: wantedIDs)

        if let epubType = OfflineAssets.value(of: "epub:type", in: t) {
            let tokens = Set(epubType.split(separator: " ").map(String.init))
            if tokens.contains("noteref") { t = addClass("ag-noteref", to: t) }
            if tokens.contains("footnote") || tokens.contains("endnote") || tokens.contains("rearnote") {
                t = addClass("ag-footnote", to: t)
            }
        }
        return t
    }

    /// A heading is a candidate section of its own, whether or not the book's declared
    /// table of contents happens to link to it — plenty of Gutenberg conversions carry a
    /// TOC that only names a handful of front-matter points and leave the book's real
    /// structure sitting in headings nothing ever links to. So a heading's id is never
    /// dropped the way an ordinary element's is: kept and namespaced if it has one,
    /// synthesized if it doesn't, so `collectHeadings` always has something to point at.
    private static func rewriteHeading(tag: String, chapterID: String, headingCounter: inout Int) -> String {
        var t = OfflineAssets.removeAttribute("style", from: tag)
        t = stripEventHandlers(t)

        if let id = OfflineAssets.value(of: "id", in: t) {
            t = OfflineAssets.replace("id", with: "\(chapterID)-\(namespaced(id))", in: t)
        } else {
            let synthetic = "\(chapterID)-h\(headingCounter)"
            headingCounter += 1
            guard let insertion = t.range(of: "<\(tagName(of: t))") else { return t }
            t.insert(contentsOf: " id=\"\(synthetic)\"", at: insertion.upperBound)
        }
        return t
    }

    private static func rewriteAnchor(tag: String, chapterID: String, directory: String,
                                      pathToID: [String: String], wantedIDs: Set<String>) -> String {
        var t = OfflineAssets.removeAttribute("style", from: tag)
        t = stripEventHandlers(t)
        t = namespaceOrDropID(t, chapterID: chapterID, wantedIDs: wantedIDs)

        if let epubType = OfflineAssets.value(of: "epub:type", in: t),
           epubType.split(separator: " ").map(String.init).contains("noteref") {
            t = addClass("ag-noteref", to: t)
        }

        guard let href = OfflineAssets.value(of: "href", in: t) else { return t }
        let trimmed = href.trimmingCharacters(in: .whitespaces)

        if isExternal(trimmed) { return t }   // untouched — ReaderWebView routes these out

        if trimmed.hasPrefix("#") {
            let frag = String(trimmed.dropFirst())
            guard !frag.isEmpty else { return OfflineAssets.removeAttribute("href", from: t) }
            return OfflineAssets.replace("href", with: "#\(chapterID)-\(namespaced(frag))", in: t)
        }

        let parts = trimmed.components(separatedBy: "#")
        guard let targetPath = ZipArchive.resolve(parts[0], from: directory),
              let targetChapter = pathToID[targetPath] else {
            // Somewhere we don't have — a resource outside the spine. The reader has
            // nothing to send this click to, so the link is dropped and the text stays.
            return OfflineAssets.removeAttribute("href", from: t)
        }
        let anchor = parts.count > 1 ? "\(targetChapter)-\(namespaced(parts[1]))" : targetChapter
        return OfflineAssets.replace("href", with: "#\(anchor)", in: t)
    }

    /// Every `<img>` whose source is this asset of this article, removed.
    private static func removingImage(named name: String, article: SavedArticle, from html: String) -> String {
        let src = "\(OfflineAssets.scheme)://\(article.id.uuidString)/\(name)"
        var out = ""
        var rest = Substring(html)
        while let start = rest.range(of: "<img", options: .caseInsensitive) {
            out += rest[..<start.lowerBound]
            guard let tagEnd = OfflineAssets.endOfTag(in: rest, from: start.upperBound) else {
                out += rest[start.lowerBound...]
                return out
            }
            let tag = String(rest[start.lowerBound..<tagEnd])
            if OfflineAssets.value(of: "src", in: tag) != src { out += tag }
            rest = rest[tagEnd...]
        }
        out += rest
        return out
    }

    /// True when there is nothing to see: no text, and no picture.
    private static func isBlank(_ html: String) -> Bool {
        if html.range(of: "<img", options: .caseInsensitive) != nil { return false }
        let text = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func rewriteImage(tag: String, directory: String, archive: ZipArchive,
                                     article: SavedArticle, store: ArticleStore) -> String {
        guard let src = OfflineAssets.value(of: "src", in: tag),
              let path = ZipArchive.resolve(src, from: directory),
              let data = try? archive.data(at: path), !data.isEmpty,
              let name = store.writeAsset(data, ext: OfflineAssets.extensionFor(pathURL(path), data: data),
                                          for: article)
        else { return "" }   // a picture that can't be found is worse left out than broken

        var t = OfflineAssets.replace("src", with: "\(OfflineAssets.scheme)://\(article.id.uuidString)/\(name)",
                                      in: tag)
        t = OfflineAssets.removeAttribute("srcset", from: t)
        t = OfflineAssets.removeAttribute("sizes", from: t)
        t = OfflineAssets.removeAttribute("style", from: t)
        t = stripEventHandlers(t)
        if let kind = OfflineAssets.classify(data) { t = addClass(kind, to: t) }
        if OfflineAssets.value(of: "loading", in: t) == nil, t.hasPrefix("<img") {
            t.insert(contentsOf: " loading=\"lazy\"", at: t.index(t.startIndex, offsetBy: 4))
        }
        return t
    }

    /// The standard EPUB cover page: an `<svg>` sized to the page whose only real content
    /// is a single `<image>`. The SVG's fixed `viewBox` renders as a giant or tiny box in
    /// a fluid column, and the reader's ink filter targets `img`, not `svg image` — so the
    /// picture is pulled out and shown as a plain image instead.
    ///
    /// Any other `<svg>` — a diagram, a decorative rule — gets the same treatment if it
    /// contains an `<image>`, and is dropped entirely if it does not; inline vector art
    /// is out of scope for a reader built around amber ink on paper.
    private static func rewriteCoverSVG(rest: Substring, directory: String, archive: ZipArchive,
                                        article: SavedArticle, store: ArticleStore) -> (String, Substring) {
        let (inner, remainder) = consumeElement(named: "svg", in: rest)
        guard let href = firstImageHref(in: inner),
              let path = ZipArchive.resolve(href, from: directory),
              let data = try? archive.data(at: path), !data.isEmpty,
              let name = store.writeAsset(data, ext: OfflineAssets.extensionFor(pathURL(path), data: data),
                                          for: article)
        else { return ("", remainder) }
        let extra = OfflineAssets.classify(data).map { " \($0)" } ?? ""
        return ("<img class=\"ag-cover\(extra)\" src=\"\(OfflineAssets.scheme)://\(article.id.uuidString)/\(name)\">",
               remainder)
    }

    private static func firstImageHref(in text: String) -> String? {
        guard let start = text.range(of: "<image", options: .caseInsensitive) else { return nil }
        guard let tagEnd = OfflineAssets.endOfTag(in: Substring(text), from: start.upperBound) else { return nil }
        let tag = String(text[start.lowerBound..<tagEnd])
        return OfflineAssets.value(of: "xlink:href", in: tag) ?? OfflineAssets.value(of: "href", in: tag)
    }

    // MARK: - Small helpers

    /// `OfflineAssets.addClass` assumes an `<img` tag; this book's markup adds classes to
    /// arbitrary elements (`<a>`, `<aside>`, whatever epub:type lands on), so it needs its
    /// own version that finds the tag name rather than assuming it.
    private static func addClass(_ name: String, to tag: String) -> String {
        if let found = OfflineAssets.range(of: "class", in: tag) {
            var copy = tag
            copy.replaceSubrange(found.value, with: String(tag[found.value]) + " " + name)
            return copy
        }
        guard let insertion = tag.range(of: "<\(tagName(of: tag))") else { return tag }
        var copy = tag
        copy.insert(contentsOf: " class=\"\(name)\"", at: insertion.upperBound)
        return copy
    }

    private static func namespaceOrDropID(_ tag: String, chapterID: String, wantedIDs: Set<String>) -> String {
        guard let id = OfflineAssets.value(of: "id", in: tag) else { return tag }
        if wantedIDs.contains(id) {
            return OfflineAssets.replace("id", with: "\(chapterID)-\(namespaced(id))", in: tag)
        }
        // An id nothing links to collides with nothing that matters — the book's own CSS
        // is dropped, so no `#id` selector is left to care — but dropping it anyway keeps
        // the flattened document from accumulating hundreds of stray, meaningless ids.
        return OfflineAssets.removeAttribute("id", from: tag)
    }

    private static func namespaced(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return cleaned.isEmpty ? "x" : cleaned
    }

    private static func isExternal(_ href: String) -> Bool {
        href.hasPrefix("http://") || href.hasPrefix("https://") || href.hasPrefix("mailto:")
    }

    private static func tagName(of tag: String) -> String {
        var name = ""
        for c in tag.dropFirst() {
            if c.isWhitespace || c == ">" || c == "/" { break }
            name.append(c)
        }
        return name
    }

    private static func pathURL(_ path: String) -> URL { URL(fileURLWithPath: "/\(path)") }

    private static func escapeAttr(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// A short, fixed list rather than a general `on*=` scanner — EPUB reflowable content
    /// has no legitimate use for inline handlers (scripting requires an explicit manifest
    /// property this app never honours), so covering the common names is enough to make
    /// them inert without writing a second attribute grammar.
    private static func stripEventHandlers(_ tag: String) -> String {
        var t = tag
        for name in ["onclick", "onload", "onerror", "onmouseover", "onmouseout",
                     "onfocus", "onblur", "onchange", "onsubmit", "ontouchstart", "ontouchend"] {
            t = OfflineAssets.removeAttribute(name, from: t)
        }
        return t
    }

    /// Finds every opening `<name ...>` tag and hands its full text to `action`. Content
    /// between tags, and tags of other names, pass by untouched — this is a lookup, not a
    /// rewrite.
    private static func forEachTag(named name: String, in text: Substring, action: (String) -> Void) {
        var rest = text
        let needle = "<\(name)"
        while let start = rest.range(of: needle, options: .caseInsensitive) {
            let after = start.upperBound
            let boundaryOK = after >= rest.endIndex || rest[after].isWhitespace
                || rest[after] == ">" || rest[after] == "/"
            guard boundaryOK, let tagEnd = OfflineAssets.endOfTag(in: rest, from: after) else {
                rest = rest[start.upperBound...]
                continue
            }
            action(String(rest[start.lowerBound..<tagEnd]))
            rest = rest[tagEnd...]
        }
    }

    /// Consumes an element by name, starting just after its opening tag, tracking nested
    /// same-name elements by counting rather than by building a tree. Returns the inner
    /// content and what remains after the matching closing tag. If no closing tag is ever
    /// found, everything remaining is treated as the element's content — a malformed
    /// document degrades gracefully rather than losing whatever came after it.
    private static func consumeElement(named name: String, in rest: Substring) -> (inner: String, remainder: Substring) {
        var depth = 1
        var inner = ""
        var cursor = rest
        let openNeedle = "<\(name)"
        let closeNeedle = "</\(name)"

        while depth > 0 {
            guard let closeRange = cursor.range(of: closeNeedle, options: .caseInsensitive) else {
                inner += cursor
                return (inner, Substring(""))
            }
            if let openRange = cursor.range(of: openNeedle, options: .caseInsensitive),
               openRange.lowerBound < closeRange.lowerBound {
                depth += 1
                inner += cursor[cursor.startIndex..<openRange.upperBound]
                cursor = cursor[openRange.upperBound...]
                continue
            }
            depth -= 1
            guard let tagEnd = OfflineAssets.endOfTag(in: cursor, from: closeRange.upperBound) else {
                inner += cursor
                return (inner, Substring(""))
            }
            if depth == 0 {
                inner += cursor[cursor.startIndex..<closeRange.lowerBound]
                cursor = cursor[tagEnd...]
            } else {
                inner += cursor[cursor.startIndex..<tagEnd]
                cursor = cursor[tagEnd...]
            }
        }
        return (inner, cursor)
    }

    /// Whether a chapter already opens with a heading, so the TOC-derived title isn't
    /// doubled on top of one the chapter already has. Checks only the very first real
    /// tag — a heading nested inside a wrapper `<div>` is missed, and the title is
    /// duplicated in that case, which is a cosmetic redundancy rather than a defect worth
    /// a full recursive scan for.
    private static func startsWithHeading(_ html: String) -> Bool {
        guard let ltRange = html.range(of: "<") else { return false }
        var s = Substring(html[ltRange.lowerBound...])
        while s.hasPrefix("<!--") {
            guard let end = s.range(of: "-->") else { return false }
            guard let next = s[end.upperBound...].range(of: "<") else { return false }
            s = s[next.lowerBound...]
        }
        guard !s.hasPrefix("</"), let tagEnd = OfflineAssets.endOfTag(in: s, from: s.index(after: s.startIndex))
        else { return false }
        let name = tagName(of: String(s[s.startIndex..<tagEnd])).lowercased()
        return name == "h1" || name == "h2" || name == "h3"
    }

    private static func plainText(of fragment: String) -> String {
        var text = ""
        var rest = Substring(fragment)
        while let lt = rest.range(of: "<") {
            text += rest[rest.startIndex..<lt.lowerBound]
            guard let gt = rest.range(of: ">", range: lt.upperBound..<rest.endIndex) else { break }
            rest = rest[gt.upperBound...]
        }
        text += rest
        return OfflineAssets.decodeEntities(text)
    }

    /// A rough word count from the flattened text — good enough to turn into a duration,
    /// which is all `SavedArticle.lengthLabel` needs from it.
    private static func countWords(in fragment: String) -> Int {
        plainText(of: fragment).split { $0.isWhitespace || $0.isNewline }.count
    }

    /// Every heading in a chapter's finished markup, in the order it actually appears —
    /// `rewriteHeading` guarantees each one carries an id, whether the book's own table of
    /// contents ever pointed at it or not. This is what lets a book whose declared TOC
    /// names three front-matter pages, and leaves the other four hundred section headers
    /// unlinked, still get a usable contents list.
    private static func collectHeadings(in html: String) -> [(id: String, level: Int, text: String)] {
        var found: [(id: String, level: Int, text: String)] = []
        var rest = Substring(html)
        // A single left-to-right pass, not one scan per level — headings of different
        // levels are routinely interleaved (a book's h1 volume titles alongside h5
        // section titles, as this app's own test fixture turned out to be), and scanning
        // level by level would silently reorder them.
        while let start = rest.range(of: "<h", options: .caseInsensitive) {
            let after = start.upperBound
            guard after < rest.endIndex, let digit = rest[after].wholeNumberValue, (1...6).contains(digit)
            else { rest = rest[start.upperBound...]; continue }
            let boundaryIndex = rest.index(after: after)
            let boundaryOK = boundaryIndex >= rest.endIndex || rest[boundaryIndex].isWhitespace
                || rest[boundaryIndex] == ">" || rest[boundaryIndex] == "/"
            guard boundaryOK, let tagEnd = OfflineAssets.endOfTag(in: rest, from: boundaryIndex) else {
                rest = rest[start.upperBound...]
                continue
            }
            let tag = String(rest[start.lowerBound..<tagEnd])
            let (inner, remainder) = consumeElement(named: "h\(digit)", in: rest[tagEnd...])
            rest = remainder
            guard let id = OfflineAssets.value(of: "id", in: tag) else { continue }
            let text = plainText(of: inner).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            found.append((id: id, level: digit, text: text))
        }
        return found
    }
}
