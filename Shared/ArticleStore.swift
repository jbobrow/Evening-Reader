import Foundation
import CryptoKit

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
    private let assetsDir: URL
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
        assetsDir = root.appendingPathComponent("Assets", isDirectory: true)
        try? fm.createDirectory(at: bodiesDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: assetsDir, withIntermediateDirectories: true)
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

    // MARK: - Assets

    /// Where one article's downloaded pictures live.
    func assetsDirectory(for article: UUID) -> URL {
        assetsDir.appendingPathComponent(article.uuidString, isDirectory: true)
    }

    /// Writes one picture and returns its file name. Named by a digest of the bytes, so
    /// a page that uses the same image twice stores it once.
    func writeAsset(_ data: Data, ext: String, article: UUID) -> String? {
        let digest = SHA256.hash(data: data).prefix(10)
            .map { String(format: "%02x", $0) }.joined()
        let name = "\(digest).\(ext)"
        let dir = assetsDirectory(for: article)
        let url = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return name }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    /// Resolves `amber-asset://<article-id>/<file>` to a file on disk.
    ///
    /// The components are checked rather than trusted: the host has to parse as a UUID
    /// and the name has to be a plain file name, so a crafted page cannot walk out of
    /// the assets folder.
    func assetFile(for url: URL) -> URL? {
        guard url.scheme == OfflineAssets.scheme,
              let host = url.host, UUID(uuidString: host) != nil else { return nil }
        let name = url.lastPathComponent
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return nil }
        let file = assetsDir.appendingPathComponent(host, isDirectory: true)
            .appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    func deleteAssets(for article: UUID) {
        try? FileManager.default.removeItem(at: assetsDirectory(for: article))
    }

    /// Bytes held on disk for saved reading, for the settings panel to report.
    func storedByteCount() -> Int64 {
        var total: Int64 = 0
        for dir in [bodiesDir, assetsDir] {
            guard let e = FileManager.default.enumerator(at: dir,
                                                         includingPropertiesForKeys: [.fileSizeKey])
            else { continue }
            for case let url as URL in e {
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }
}
