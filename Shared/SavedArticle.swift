import Foundation

/// A page the reader has saved. Shared between the app and the share extension.
struct SavedArticle: Codable, Identifiable, Hashable {
    enum State: String, Codable {
        /// Queued by the share extension; body has not been extracted yet.
        case pending
        /// Reader text was extracted and cached on disk.
        case ready
        /// Extraction failed; the page can still be opened in the live web view.
        case failed
    }

    var id: UUID = UUID()
    var url: URL
    var title: String
    var byline: String?
    var siteName: String?
    var excerpt: String?
    var wordCount: Int = 0
    var addedAt: Date = .now
    var publishedAt: Date?
    var readAt: Date?
    var lastScroll: Double = 0
    var isArchived: Bool = false
    var state: State = .pending
    /// File name (not a full path) of the cached reader HTML inside the store's `Bodies` folder.
    var bodyFile: String?

    var estimatedMinutes: Int { max(1, Int((Double(wordCount) / 235.0).rounded())) }

    var host: String {
        guard var h = url.host else { return url.absoluteString }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    var displayTitle: String { title.isEmpty ? host : title }
}
