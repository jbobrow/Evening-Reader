import Foundation
import PDFKit
import UIKit
import Observation

/// The reading list, plus the work of turning a URL into readable text.
@MainActor
@Observable
final class Library {
    var articles: [SavedArticle] = []
    var working: Set<UUID> = []
    var lastError: String?

    enum Scope: String, CaseIterable, Identifiable {
        case unread, all, archive
        var id: String { rawValue }
        var label: String {
            switch self {
            case .unread: return "Unread"
            case .all: return "All"
            case .archive: return "Archive"
            }
        }
    }

    /// Where the library is living.
    enum SyncState {
        /// Still asking iCloud where its container is.
        case searching
        /// Only on this device: iCloud is off, or no account is signed in.
        case local
        case cloud
    }

    private(set) var syncState: SyncState = .searching

    private let store: ArticleStore
    @ObservationIgnored private let cloud = CloudLibrary()
    @ObservationIgnored private var cloudObserver: NSObjectProtocol?
    @ObservationIgnored private var syncing = false

    init(store: ArticleStore = .shared) {
        self.store = store
        articles = store.load()
        repairStoredDates()
    }

    var usesAppGroup: Bool { store.usesAppGroup }

    // MARK: - Queries

    func list(scope: Scope, search: String) -> [SavedArticle] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return articles
            .filter { item in
                switch scope {
                case .unread: return !item.isArchived && item.readAt == nil
                case .all: return !item.isArchived
                case .archive: return item.isArchived
                }
            }
            .filter { item in
                guard !query.isEmpty else { return true }
                return item.displayTitle.lowercased().contains(query)
                    || (item.byline ?? "").lowercased().contains(query)
                    || item.sourceLabel.lowercased().contains(query)
                    || (item.excerpt ?? "").lowercased().contains(query)
            }
            .sorted { $0.addedAt > $1.addedAt }
    }

    func count(scope: Scope) -> Int { list(scope: scope, search: "").count }

    /// The reading to go back to: whatever was opened last and is still on the shelf.
    var continueReading: SavedArticle? {
        articles
            .filter { !$0.isArchived && $0.openedAt != nil }
            .max { ($0.openedAt ?? .distantPast) < ($1.openedAt ?? .distantPast) }
    }

    /// The last thing to arrive.
    var justSaved: SavedArticle? {
        articles.filter { !$0.isArchived }.max { $0.addedAt < $1.addedAt }
    }

    func body(for article: SavedArticle) -> String? {
        store.readBody(for: article)
    }

    func documentURL(for article: SavedArticle) -> URL {
        store.documentURL(for: article)
    }

    /// A book's cover, on disk, if it has one and got one.
    func coverURL(for article: SavedArticle) -> URL? {
        guard let asset = article.coverAsset else { return nil }
        return store.assetsDirectory(for: article).appendingPathComponent(asset)
    }

    // MARK: - Mutation

    /// Pull in anything the share extension queued while we were away, and finish
    /// extracting whatever is still pending.
    func refreshFromDisk() {
        let onDisk = store.load()
        // Keep in-flight local edits (scroll positions) from being clobbered.
        var merged = onDisk
        for local in articles {
            if let i = merged.firstIndex(where: { $0.id == local.id }) {
                if local.state == .ready, merged[i].state != .ready { merged[i] = local }
                else if local.lastScroll > merged[i].lastScroll { merged[i].lastScroll = local.lastScroll }
                if local.readAt != nil, merged[i].readAt == nil { merged[i].readAt = local.readAt }
                if let opened = local.openedAt, opened > (merged[i].openedAt ?? .distantPast) {
                    merged[i].openedAt = opened
                }
            }
        }
        articles = merged
        repairStoredDates()
        processPending()
    }

    func processPending() {
        for article in articles where article.state == .pending && !working.contains(article.id) {
            Task { await extract(article) }
        }
    }

    @discardableResult
    func add(url rawURL: URL, title: String? = nil) -> SavedArticle {
        let normalized = Self.normalize(rawURL)
        if let existing = articles.first(where: { $0.url == normalized }) {
            if existing.isArchived { setArchived(existing, false) }
            if existing.state == .failed { retry(existing) }
            return existing
        }
        var article = SavedArticle(url: normalized,
                                   title: title ?? "",
                                   siteName: nil,
                                   state: .pending)
        article.title = title ?? normalized.host.map { $0.replacingOccurrences(of: "www.", with: "") } ?? normalized.absoluteString
        articles.insert(article, at: 0)
        persist()
        Task { await extract(article) }
        return article
    }

    func retry(_ article: SavedArticle) {
        guard var found = articles.first(where: { $0.id == article.id }) else { return }
        found.state = .pending
        replace(found)
        Task { await extract(found) }
    }

    private func extract(_ article: SavedArticle) async {
        guard !working.contains(article.id) else { return }
        working.insert(article.id)
        defer { working.remove(article.id) }

        // A book was already identified and its file already copied in by whatever queued
        // it — the share extension, today. There is no `article.url` worth fetching: its
        // scheme is synthetic, and `isPDF`'s HEAD request would only fail or hang against it.
        if article.isBook {
            await importBook(article)
            return
        }

        // A PDF has no reader text to pull out of it — it is already the document. Save
        // the file itself and let the reader render it.
        if await Self.isPDF(article.url) {
            await savePDF(article)
            return
        }

        do {
            let result = try await ArticleExtractor.shared.extract(url: article.url)
            guard var updated = articles.first(where: { $0.id == article.id }) else { return }
            updated.title = result.title.isEmpty ? updated.title : result.title
            updated.byline = result.byline.isEmpty ? nil : result.byline
            updated.siteName = result.site.isEmpty ? nil : result.site
            updated.excerpt = result.excerpt.isEmpty ? nil : String(result.excerpt.prefix(320))
            updated.wordCount = result.wordCount
            updated.publishedAt = Self.parseDate(result.published)
            // Pull the pictures onto the device before the body is written, so what is
            // stored already points at the copies rather than at the web.
            let offline = await OfflineAssets.localize(html: result.html, article: updated, store: store)
            updated.state = store.writeBody(offline.html, for: updated) ? .ready : .failed
            // The portable copy, written from the same fetch: same article, same
            // pictures, in a format that outlives this app.
            if let sidecar = MarkdownSidecar.document(article: updated, markdown: result.markdown,
                                                      assets: offline.assets) {
                store.writeMarkdown(sidecar, for: updated)
            }
            replace(updated)
        } catch {
            guard var updated = articles.first(where: { $0.id == article.id }) else { return }
            updated.state = .failed
            replace(updated)
            lastError = error.localizedDescription
        }
    }

    /// Is this a PDF? The extension is only a hint — plenty of PDFs are served from a
    /// path that does not end in one — so the server is asked, and the answer falls back
    /// to the extension when it cannot be.
    private static func isPDF(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 12
        if let (_, response) = try? await URLSession.shared.data(for: request),
           let mime = (response as? HTTPURLResponse)?
               .value(forHTTPHeaderField: "Content-Type")?.lowercased() {
            if mime.contains("application/pdf") { return true }
            if mime.contains("text/html") { return false }
        }
        return url.pathExtension.lowercased() == "pdf"
    }

    private func savePDF(_ article: SavedArticle) async {
        var request = URLRequest(url: article.url)
        request.timeoutInterval = 60
        guard let (data, _) = try? await URLSession.shared.data(for: request), !data.isEmpty,
              var updated = articles.first(where: { $0.id == article.id }) else {
            guard var failed = articles.first(where: { $0.id == article.id }) else { return }
            failed.state = .failed
            replace(failed)
            return
        }
        updated.kind = .pdf
        updated.pageCount = PDFDocument(data: data)?.pageCount
        if updated.title.isEmpty || updated.title == updated.host {
            let name = article.url.deletingPathExtension().lastPathComponent
            let cleaned = name.replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
            if !cleaned.isEmpty { updated.title = cleaned }
        }
        // A page count is the honest unit for a PDF; the reader shows it in place of a
        // reading time, which would be a guess about something we cannot see inside.
        updated.wordCount = 0
        updated.state = store.writeDocument(data, for: updated) ? .ready : .failed
        replace(updated)
    }

    /// Takes a book already vetted by the caller (guard already run, metadata already
    /// read) and queues it the same way one that arrived through the share extension
    /// would — one folder, one pending item, extracted on the next pass.
    @discardableResult
    func addBookFile(_ article: SavedArticle, from fileURL: URL) -> SavedArticle {
        if let existing = articles.first(where: { $0.url == article.url }) {
            if existing.isArchived { setArchived(existing, false) }
            if existing.state == .failed { retry(existing) }
            return existing
        }
        articles.insert(article, at: 0)
        persist()
        store.adoptDocument(from: fileURL, for: article)
        Task { await extract(article) }
        return article
    }

    /// Unzips and flattens a book already stored by whatever queued it. Real work — a
    /// long novel is not something to do on the main actor — so it runs detached and only
    /// the finished `SavedArticle` mutation comes back to it.
    private func importBook(_ article: SavedArticle) async {
        let store = self.store
        let outcome: Result<BookImporter.Imported, Error> = await Task.detached(priority: .userInitiated) {
            do { return .success(try BookImporter.importBook(for: article, store: store)) }
            catch { return .failure(error) }
        }.value

        guard var updated = articles.first(where: { $0.id == article.id }) else { return }
        switch outcome {
        case .success(let imported):
            updated.title = imported.title.isEmpty ? updated.title : imported.title
            updated.byline = imported.creator
            updated.siteName = imported.publisher
            updated.wordCount = imported.wordCount
            updated.chapterCount = imported.chapters.count
            updated.coverAsset = imported.coverAssetName
            updated.coverAssetClass = imported.coverAssetClass
            updated.state = .ready
        case .failure(let error):
            updated.state = .failed
            lastError = error.localizedDescription
        }
        replace(updated)
    }

    func markRead(_ article: SavedArticle) {
        guard var found = articles.first(where: { $0.id == article.id }), found.readAt == nil else { return }
        found.readAt = .now
        replace(found)
    }

    /// Opened to read, now. Kept apart from `markRead`, which records the first time
    /// only: this is the one the front page follows.
    func noteOpened(_ article: SavedArticle) {
        guard var found = articles.first(where: { $0.id == article.id }) else { return }
        found.openedAt = .now
        replace(found)
    }

    func setArchived(_ article: SavedArticle, _ archived: Bool) {
        guard var found = articles.first(where: { $0.id == article.id }) else { return }
        found.isArchived = archived
        if archived, found.readAt == nil { found.readAt = .now }
        replace(found)
    }

    func setScroll(_ fraction: Double, for article: SavedArticle) {
        guard let i = articles.firstIndex(where: { $0.id == article.id }) else { return }
        guard abs(articles[i].lastScroll - fraction) > 0.01 else { return }
        articles[i].lastScroll = fraction
        // Scroll updates arrive continuously; write them out lazily.
        schedulePersist()
    }

    func delete(_ article: SavedArticle) {
        store.delete(article)
        articles.removeAll { $0.id == article.id }
        persist()
    }

    // MARK: - Clipboard

    /// True when the clipboard *probably* holds a link — checked without reading the
    /// contents, so iOS doesn't show a paste banner until the user asks for it.
    var clipboardMayHoldLink: Bool { UIPasteboard.general.hasURLs }

    /// Move the library into iCloud if it is available, then keep up with it.
    ///
    /// Everything before this point works against the local copy, so a slow or absent
    /// iCloud never delays the first read.
    ///
    /// It keeps asking, which matters more than it looks.
    /// `url(forUbiquityContainerIdentifier:)` returns nil both when iCloud is genuinely
    /// unavailable and when the container has simply not been provisioned on this device
    /// yet — and a first launch on a new device is exactly when provisioning is still in
    /// flight, which is exactly when the reader is expecting to find the library they
    /// already have somewhere else. Asking once and giving up leaves them looking at an
    /// empty shelf with nothing to explain it.
    func startSync() async {
        guard syncState != .cloud, !syncing else { return }
        syncing = true
        defer { syncing = false }

        var delay: UInt64 = 1
        for attempt in 0..<7 {
            if await store.adoptCloud() {
                syncState = .cloud
                store.drainInbox()
                refreshFromDisk()
                cloud.watch()
                cloudObserver = NotificationCenter.default.addObserver(
                    forName: CloudLibrary.didChange, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshFromDisk() }
                }
                return
            }
            // Don't sleep past the last attempt; the answer is already in.
            guard attempt < 6 else { break }
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            delay = min(delay * 2, 30)
        }
        syncState = .local
    }

    /// On returning to the app, take anything the share extension queued while away.
    ///
    /// Also worth another look for iCloud: the reader may have gone to Settings and
    /// turned it on, which is the likeliest thing to have happened while they were away.
    func pickUpInbox() {
        store.drainInbox()
        refreshFromDisk()
        if syncState != .cloud {
            Task { await startSync() }
        }
    }

    func addFromClipboard() {
        let pasteboard = UIPasteboard.general
        if let url = pasteboard.url ?? pasteboard.string.flatMap(BrowserModel.url(from:)) {
            add(url: url)
        }
    }

    // MARK: - Storage

    private func replace(_ article: SavedArticle) {
        guard let i = articles.firstIndex(where: { $0.id == article.id }) else { return }
        articles[i] = article
        persist()
    }

    @ObservationIgnored private var persistTask: Task<Void, Never>?

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    func persist() {
        store.save(articles)
    }

    /// Publication dates arrive in whatever format the publisher felt like.
    ///
    /// A publication date is a calendar day, and a day is the only thing the app ever
    /// shows. So anything naming a day rather than a moment is anchored to midnight
    /// where the reader is, and the day the publisher wrote is the day the reader sees.
    /// Reading `2026-08-29` as midnight UTC and then printing it in California is how an
    /// article comes to be dated the day before it came out.
    static func parseDate(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let day = calendarDay(text) { return day }

        let iso = ISO8601DateFormatter()
        for options in [[.withInternetDateTime, .withFractionalSeconds] as ISO8601DateFormatter.Options,
                        [.withInternetDateTime]] {
            iso.formatOptions = options
            if let date = iso.date(from: text) { return date }
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let date = formatter.date(from: text) { return date }

        // A day written out in words is a day like any other, and is read where the
        // reader is for the same reason.
        formatter.timeZone = .current
        for format in ["yyyy/MM/dd", "MMMM d, yyyy", "d MMMM yyyy", "MMM d, yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// Puts right the dates saved before a day was understood to be a day.
    ///
    /// An article saved earlier kept whatever `parseDate` made of it at the time, so a
    /// day-granularity date is sitting in the library an instant into the wrong one.
    /// Nothing else will ever correct it: the page is not fetched again, and the stored
    /// date is what the reader and the sidecar both print.
    ///
    /// Only a date that is exactly midnight UTC is touched — the shape a day took on the
    /// way through. Running this twice changes nothing the second time: a repaired date
    /// is anchored locally and no longer looks like one of these, and where the reader
    /// keeps UTC time it already maps to itself. So it can run at every launch, and on
    /// whatever another device has since written into iCloud, without a marker to say it
    /// has been here.
    private func repairStoredDates() {
        var repaired: [SavedArticle] = []
        for i in articles.indices {
            guard let stored = articles[i].publishedAt,
                  let corrected = Self.localDay(matching: stored) else { continue }
            articles[i].publishedAt = corrected
            repaired.append(articles[i])
        }
        guard !repaired.isEmpty else { return }
        store.save(repaired)
        for article in repaired {
            guard let sidecar = store.readMarkdown(for: article),
                  let updated = MarkdownSidecar.repointing(sidecar, published: article.publishedAt)
            else { continue }
            store.writeMarkdown(updated, for: article)
        }
    }

    /// Local midnight on the day a stored date names, when that date is exactly midnight
    /// UTC. Nil for anything else — a real moment, or a date already anchored where the
    /// reader is.
    static func localDay(matching date: Date) -> Date? {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let parts = utc.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond],
                                       from: date)
        guard parts.hour == 0, parts.minute == 0, parts.second == 0, (parts.nanosecond ?? 0) == 0
        else { return nil }
        var day = DateComponents()
        day.year = parts.year
        day.month = parts.month
        day.day = parts.day
        guard let local = Calendar.current.date(from: day), local != date else { return nil }
        return local
    }

    /// Local midnight on the day a string names, for a string that names a day: a bare
    /// `2026-08-29`, or a timestamp whose clock reads midnight in whatever zone it
    /// states.
    ///
    /// That second case is not a curiosity. It is what a date-only value becomes once
    /// something upstream widens it into a timestamp — Defuddle hands back a page's
    /// `2026-08-29` as `2026-08-29T00:00:00+00:00`, and the day is already gone by the
    /// time it arrives here. A publisher that means a moment writes one; midnight on the
    /// nose is a day wearing a clock.
    private static func calendarDay(_ text: String) -> Date? {
        guard text.count >= 10 else { return nil }
        let pieces = text.prefix(10).split(separator: "-")
        guard pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2])
        else { return nil }

        var clock = text.dropFirst(10)
        if !clock.isEmpty {
            guard clock.first == "T" || clock.first == " " else { return nil }
            clock = clock.dropFirst()
            // The zone, if one is stated, is not part of the question: midnight in the
            // publisher's zone is still the day the publisher meant.
            for designator in ["Z", "+", "-"] {
                if let cut = clock.range(of: designator) { clock = clock[..<cut.lowerBound] }
            }
            var reading = String(clock)
            if let dot = reading.firstIndex(of: ".") {
                guard reading[reading.index(after: dot)...].allSatisfy({ $0 == "0" }) else { return nil }
                reading = String(reading[..<dot])
            }
            guard ["00:00", "00:00:00", "0000", "000000"].contains(reading) else { return nil }
        }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return Calendar.current.date(from: components)
    }

    /// Strip tracking noise so the same article shared twice is recognised as one item.
    static func normalize(_ url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let junk: Set<String> = ["utm_source", "utm_medium", "utm_campaign", "utm_term",
                                 "utm_content", "utm_name", "fbclid", "gclid", "mc_cid",
                                 "mc_eid", "igshid", "ref", "ref_src", "s", "cmpid"]
        if let items = comps.queryItems {
            let kept = items.filter { !junk.contains($0.name.lowercased()) }
            comps.queryItems = kept.isEmpty ? nil : kept
        }
        comps.fragment = nil
        return comps.url ?? url
    }
}
