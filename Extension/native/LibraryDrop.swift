import Foundation

/// Puts a page into the Evening Reader library in iCloud, from the Mac — the browser
/// extensions' half of what the app and the share extension do on the phone.
///
/// The extension reads the article out of the page the reader has open, with the app's
/// own extraction scripts, and hands it over here; this side stores it the way
/// `Library.extract` stores a page the app fetched itself — pictures pulled down and
/// classified, `body.html`, the record, the note with the article's Markdown — using the
/// app's own `ArticleStore`, `OfflineAssets` and `MarkdownSidecar`. The article arrives
/// on every device ready to read, offline, without the app having been opened.
///
/// When there is nothing to store — a link saved from a context menu, a page the
/// scripts could not read — it queues the address instead, `pending`, exactly as the
/// share extension does, and the app fetches it the next time it is opened.
enum LibraryDrop {
    enum Outcome {
        /// A new article, ready to read when `captured`, otherwise queued.
        case saved(title: String, captured: Bool)
        /// Already in the library: brought back to the top of Unread, and filled in if it
        /// had not been fetched yet.
        case resaved(title: String, captured: Bool)
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// What the extension read out of the page: the fields of the app's
    /// `ExtractionResult` that a saved article keeps.
    struct Capture {
        var title: String
        var byline: String
        var site: String
        var published: String
        var excerpt: String
        var wordCount: Int
        var html: String
        var markdown: String

        init?(_ object: Any?) {
            guard let fields = object as? [String: Any],
                  let html = fields["html"] as? String, !html.isEmpty else { return nil }
            func text(_ key: String) -> String { fields[key] as? String ?? "" }
            title = text("title")
            byline = text("byline")
            site = text("site")
            published = text("published")
            excerpt = text("excerpt")
            wordCount = (fields["wordCount"] as? NSNumber)?.intValue ?? 0
            self.html = html
            markdown = text("markdown")
        }
    }

    static let containerFolder = "iCloud~com~jonbobrow~AmberGlow"

    // MARK: - Messages

    /// One request from the extension, `{action: "save", url, title, capture?}`, and the
    /// reply it gets: `{ok: true, status: "saved" | "resaved", captured, title}`, or
    /// `{ok: false, error}`. The same shape whichever browser asked.
    static func handle(_ message: [String: Any]) async -> [String: Any] {
        guard message["action"] as? String == "save" else {
            return ["ok": false, "error": "Evening Reader doesn't know how to do that."]
        }
        guard let raw = message["url"] as? String, let url = URL(string: raw),
              url.scheme == "http" || url.scheme == "https" else {
            return ["ok": false, "error": "Only web pages can be saved to Evening Reader."]
        }
        let title = (message["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            switch try await save(url: url, title: title, capture: Capture(message["capture"])) {
            case .saved(let title, let captured):
                return ["ok": true, "status": "saved", "captured": captured, "title": title]
            case .resaved(let title, let captured):
                return ["ok": true, "status": "resaved", "captured": captured, "title": title]
            }
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    }

    // MARK: - Saving

    /// The library's folder: the container's `Documents`, where the app keeps it.
    ///
    /// From the real home rather than `NSHomeDirectory()`, which inside Safari's sandboxed
    /// handler is the sandbox's own container. Safari's handler and the Chrome helper the
    /// Mac app carries are each given this one folder by entitlement.
    static func libraryRoot() throws -> URL {
        // A stand-in library, for trying the host out without touching the real one.
        if let override = ProcessInfo.processInfo.environment["EVENING_READER_LIBRARY"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let home = getpwuid(getuid()).map { URL(fileURLWithPath: String(cString: $0.pointee.pw_dir)) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let root = home
            .appendingPathComponent("Library/Mobile Documents", isDirectory: true)
            .appendingPathComponent(containerFolder, isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw Failure("Evening Reader's iCloud library isn't on this Mac. Check that iCloud Drive is on, "
                          + "and that Evening Reader has saved something on your phone.")
        }
        return root
    }

    static func save(url: URL, title: String?, capture: Capture?) async throws -> Outcome {
        let root = try libraryRoot()
        try checkWritable(root)
        let store = ArticleStore(libraryAt: root)

        // A page saved again is the article already there, brought back — not a second
        // copy. The same as the share extension and the app's own Add Link do.
        if var existing = store.load().first(where: { $0.url == url }) {
            // Saved again is to be read again: back in Unread, the same place taking it
            // out of the archive puts it.
            existing.addedAt = .now
            existing.isArchived = false
            existing.readAt = nil
            var captured = false
            if existing.state != .ready, let capture {
                try await fill(&existing, from: capture, in: store, renaming: true)
                captured = true
            }
            // Saved again after it could not be fetched is asked for again.
            if !captured, existing.state == .failed { existing.state = .pending }
            store.save(existing)
            await store.flush()
            try confirm(existing, in: store, at: root)
            return .resaved(title: existing.displayTitle, captured: captured || existing.state == .ready)
        }

        let host = url.host?.replacingOccurrences(of: "www.", with: "")
        var article = SavedArticle(url: url, title: title ?? "")
        if article.title.isEmpty { article.title = host ?? url.absoluteString }
        article.siteName = host
        article.state = .pending

        var captured = false
        do {
            if let capture {
                try await fill(&article, from: capture, in: store, renaming: false)
                captured = true
            }
            if !captured { store.save(article) }
            await store.flush()
            try confirm(article, in: store, at: root)
        } catch {
            // Whatever of it did land would show in the app as an article that failed.
            store.delete(article)
            await store.flush()
            throw error
        }
        return .saved(title: article.displayTitle, captured: captured)
    }

    // MARK: - Making sure it's there

    /// `ArticleStore` writes the way the app needs it to, quietly: a write that fails is
    /// tried again by the next save, and there is always a next save. Here there isn't, and
    /// the reader is told "Saved" and walks away, so what this side writes is checked.

    /// Writes and removes a small file in the library first, so a folder this side may not
    /// write to — a sandbox that wasn't given it, permissions, a full disk — says so before
    /// anything is saved, and says why. Hidden and `.nosync`, so iCloud never carries it.
    static func checkWritable(_ root: URL) throws {
        let probe = root.appendingPathComponent(".evening-reader-write-check-\(UUID().uuidString).nosync")
        do {
            try Data().write(to: probe)
        } catch {
            throw Failure("Evening Reader Saver can't write to \(place(root))\(reason(error)), so nothing was saved.")
        }
        try? FileManager.default.removeItem(at: probe)
    }

    /// Reads the library back as the app would, and fails unless the article is in it —
    /// and ready to read, when it was saved ready. Catches whatever the check before
    /// couldn't: a note or record that didn't land, for any reason.
    static func confirm(_ article: SavedArticle, in store: ArticleStore, at root: URL) throws {
        // Its note and its record, `state.json` beside its body: the app reads a note
        // without a record as an article that failed.
        guard let found = store.load().first(where: { $0.id == article.id }),
              FileManager.default.fileExists(atPath: store.folder(for: found)
                .appendingPathComponent("state.json").path) else {
            throw Failure("Evening Reader Saver couldn't write this page to \(place(root)), so it wasn't saved.")
        }
        if article.state == .ready, found.state != .ready {
            throw Failure("Evening Reader Saver couldn't write all of this page to \(place(root)). Try saving it again.")
        }
    }

    /// The library's folder as the reader knows it: where Finder shows it, or the stand-in's
    /// path, with the home folder as `~`.
    static func place(_ root: URL) -> String {
        if root.lastPathComponent == "Documents",
           root.deletingLastPathComponent().lastPathComponent == containerFolder {
            return "iCloud Drive › Evening Reader"
        }
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return root.path.hasPrefix(home + "/") ? "~" + root.path.dropFirst(home.count) : root.path
    }

    /// The system's own words for why a write failed, " (Operation not permitted)", from
    /// the error underneath Foundation's, which would name the check file instead.
    private static func reason(_ error: Error) -> String {
        let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        if let underlying, underlying.domain == NSPOSIXErrorDomain,
           let code = POSIXErrorCode(rawValue: Int32(underlying.code)) {
            return " (\(String(cString: strerror(code.rawValue))))"
        }
        return ""
    }

    /// `Library.extract`, from the point it has the page: the article's details, its
    /// pictures, its body, its record and its note, in that order. Throws when the body
    /// can't be written: the reader is told, rather than handed a queued link instead of
    /// the page they captured.
    private static func fill(_ article: inout SavedArticle, from capture: Capture,
                             in store: ArticleStore, renaming: Bool) async throws {
        var updated = article
        updated.title = capture.title.isEmpty ? updated.title : capture.title
        updated.byline = capture.byline.isEmpty ? nil : capture.byline
        updated.siteName = capture.site.isEmpty ? nil : capture.site
        updated.excerpt = capture.excerpt.isEmpty ? nil : String(capture.excerpt.prefix(320))
        updated.wordCount = capture.wordCount
        updated.publishedAt = PublishedDate.parse(capture.published)
        // Queued as a bare address, it is named after one. Now it has a title, its note
        // and folder take that name before anything more is written into them.
        if renaming { await store.rename(updated) }

        let offline = await OfflineAssets.localize(html: capture.html, article: updated, store: store)
        guard store.writeBody(offline.html, for: updated) else {
            throw Failure("Evening Reader Saver couldn't write this page to \(place(store.root)), so it wasn't saved.")
        }
        updated.state = .ready
        // The record before the note: a note that reaches another device before its record
        // is read there as an article that failed, until the record lands.
        store.save(updated)
        let body = MarkdownSidecar.body(article: updated, markdown: capture.markdown,
                                        assets: offline.assets,
                                        assetsPath: store.assetsLinkPath(for: updated))
        await store.writeNote(updated, body: body)
        article = updated
    }
}
