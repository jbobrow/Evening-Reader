import Foundation

/// JSON-on-disk store for saved articles, living in the app group container so the
/// share extension and the app write to the same place.
///
/// If the app group is unavailable (an unsigned simulator build, for instance) it
/// falls back to the process's own Application Support directory so the app still
/// works standalone — the share extension just won't be able to hand items over.
final class ArticleStore {
    static let appGroupID = "group.com.amberglow.shared"

    let root: URL
    let usesAppGroup: Bool

    private let indexURL: URL
    private let bodiesDir: URL
    private let queue = DispatchQueue(label: "com.amberglow.store", qos: .userInitiated)

    static let shared = ArticleStore()

    init() {
        let fm = FileManager.default
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID) {
            root = group.appendingPathComponent("Library", isDirectory: true)
            usesAppGroup = true
        } else {
            let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true))
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            root = base.appendingPathComponent("AmberGlow", isDirectory: true)
            usesAppGroup = false
        }
        indexURL = root.appendingPathComponent("index.json")
        bodiesDir = root.appendingPathComponent("Bodies", isDirectory: true)
        try? fm.createDirectory(at: bodiesDir, withIntermediateDirectories: true)
    }

    // MARK: - Index

    func load() -> [SavedArticle] {
        queue.sync {
            guard let data = try? Data(contentsOf: indexURL) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? decoder.decode([SavedArticle].self, from: data)) ?? []
        }
    }

    func save(_ articles: [SavedArticle]) {
        queue.sync {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(articles) else { return }
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    /// Append (or refresh) one item without clobbering concurrent writes from the other process.
    @discardableResult
    func append(_ article: SavedArticle) -> [SavedArticle] {
        var all = load()
        if let i = all.firstIndex(where: { $0.url == article.url }) {
            var existing = all[i]
            existing.addedAt = .now
            existing.isArchived = false
            if existing.title.isEmpty { existing.title = article.title }
            all[i] = existing
        } else {
            all.insert(article, at: 0)
        }
        save(all)
        return all
    }

    // MARK: - Bodies

    func bodyURL(for name: String) -> URL { bodiesDir.appendingPathComponent(name) }

    func writeBody(_ html: String, for article: SavedArticle) -> String? {
        let name = "\(article.id.uuidString).html"
        let url = bodyURL(for: name)
        do {
            try FileManager.default.createDirectory(at: bodiesDir, withIntermediateDirectories: true)
            try html.write(to: url, atomically: true, encoding: .utf8)
            return name
        } catch {
            return nil
        }
    }

    func readBody(_ name: String) -> String? {
        try? String(contentsOf: bodyURL(for: name), encoding: .utf8)
    }

    func deleteBody(_ name: String?) {
        guard let name else { return }
        try? FileManager.default.removeItem(at: bodyURL(for: name))
    }
}
