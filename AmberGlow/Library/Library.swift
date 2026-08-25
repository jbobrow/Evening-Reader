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

    private let store: ArticleStore

    init(store: ArticleStore = .shared) {
        self.store = store
        articles = store.load()
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
                    || item.host.lowercased().contains(query)
                    || (item.excerpt ?? "").lowercased().contains(query)
            }
            .sorted { $0.addedAt > $1.addedAt }
    }

    func count(scope: Scope) -> Int { list(scope: scope, search: "").count }

    func body(for article: SavedArticle) -> String? {
        store.readBody(for: article)
    }

    func documentURL(for article: SavedArticle) -> URL {
        store.documentURL(for: article)
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
            }
        }
        articles = merged
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
            updated.state = store.writeBody(offline, for: updated) ? .ready : .failed
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

    func markRead(_ article: SavedArticle) {
        guard var found = articles.first(where: { $0.id == article.id }), found.readAt == nil else { return }
        found.readAt = .now
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
    static func parseDate(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let iso = ISO8601DateFormatter()
        for options in [[.withInternetDateTime, .withFractionalSeconds] as ISO8601DateFormatter.Options,
                        [.withInternetDateTime],
                        [.withFullDate]] {
            iso.formatOptions = options
            if let date = iso.date(from: text) { return date }
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy/MM/dd", "MMMM d, yyyy", "d MMMM yyyy", "MMM d, yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
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
