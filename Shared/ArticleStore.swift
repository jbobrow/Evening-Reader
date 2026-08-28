import Foundation
import CryptoKit

/// Saved reading, kept as plain files.
///
/// One folder per article, named after its title, holding everything that belongs to it:
///
///     the-worst-mistake-in-the-history--a1b2c3d4/
///         article.json      the metadata, pretty-printed
///         body.html         the reader text
///         document.pdf      instead of body.html, for a saved PDF
///         assets/           pictures pulled down for offline reading
///
/// The shape is deliberate rather than incidental. A single index file would be the
/// obvious thing and is the wrong thing to sync: two devices editing different articles
/// each write the whole index, and whichever syncs last silently discards the other's
/// work. A folder per article means independent edits never touch the same file, so
/// there is nothing to resolve. It also means the library is legible in Finder and
/// portable by any means that copies folders.
final class ArticleStore {
    static let appGroupID = "group.com.amberglow.shared"

    /// Where the library lives now. Starts local and moves to iCloud once the container
    /// has been resolved, which cannot be done synchronously at launch.
    private(set) var root: URL
    /// The app group folder. Always writable, and where the share extension puts things.
    let localRoot: URL
    let usesAppGroup: Bool
    private(set) var isCloud = false

    private let legacyIndexURL: URL
    private let legacyBodiesDir: URL
    private let legacyAssetsDir: URL
    private let queue = DispatchQueue(label: "com.amberglow.store", qos: .userInitiated)
    /// article id -> its folder, so an amber-asset:// URL can be resolved without a scan.
    private var folders: [UUID: URL] = [:]

    static let shared = ArticleStore()

    init() {
        let fm = FileManager.default
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID) {
            localRoot = group.appendingPathComponent("Library", isDirectory: true)
            usesAppGroup = true
        } else {
            let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true))
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            localRoot = base.appendingPathComponent("AmberGlow", isDirectory: true)
            usesAppGroup = false
        }
        root = localRoot
        legacyIndexURL = localRoot.appendingPathComponent("index.json")
        legacyBodiesDir = localRoot.appendingPathComponent("Bodies", isDirectory: true)
        legacyAssetsDir = localRoot.appendingPathComponent("Assets", isDirectory: true)
        try? fm.createDirectory(at: localRoot, withIntermediateDirectories: true)
        migrateIfNeeded()
    }

    // MARK: - iCloud

    /// Moves the library into iCloud, if iCloud will have it.
    ///
    /// Anything already on this device is moved across the first time. A folder that is
    /// already there wins — it came from another device and is at least as current as
    /// what is here, and a folder is only ever written whole.
    ///
    /// Returns true when the library is in iCloud afterwards.
    @discardableResult
    func adoptCloud() async -> Bool {
        guard !isCloud, let cloud = await CloudLibrary.documentsDirectory() else { return isCloud }
        let fm = FileManager.default
        let local = localRoot
        queue.sync {
            if let entries = try? fm.contentsOfDirectory(at: local,
                                                         includingPropertiesForKeys: [.isDirectoryKey],
                                                         options: [.skipsHiddenFiles]) {
                for dir in entries {
                    let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    guard isDir else { continue }
                    let destination = cloud.appendingPathComponent(dir.lastPathComponent, isDirectory: true)
                    guard !fm.fileExists(atPath: destination.path) else { continue }
                    try? fm.setUbiquitous(true, itemAt: dir, destinationURL: destination)
                }
            }
            root = cloud
            isCloud = true
            folders.removeAll()
        }
        return true
    }

    /// Takes anything the share extension left in the app group.
    ///
    /// The extension has no iCloud entitlement — it writes where it can, and the app
    /// carries it the rest of the way on the next launch or foreground.
    func drainInbox() {
        guard isCloud else { return }
        let fm = FileManager.default
        let inbox = localRoot
        queue.sync {
            guard let entries = try? fm.contentsOfDirectory(at: inbox,
                                                            includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: [.skipsHiddenFiles]) else { return }
            for dir in entries {
                let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir else { continue }
                let destination = root.appendingPathComponent(dir.lastPathComponent, isDirectory: true)
                if fm.fileExists(atPath: destination.path) {
                    try? fm.removeItem(at: dir)          // already have it
                } else {
                    try? fm.setUbiquitous(true, itemAt: dir, destinationURL: destination)
                }
            }
        }
    }

    // MARK: - Layout

    private static let metadataName = "article.json"
    private static let bodyName = "body.html"
    private static let documentName = "document.pdf"
    private static let bookName = "book.epub"
    private static let assetsName = "assets"
    /// Sidecar files a kind may keep beside `article.json`. Whitelisted rather than
    /// taking any name, so this stays a store for known shapes rather than a place
    /// anything can be dropped.
    private static let allowedSidecars: Set<String> = ["contents.json", "highlights.json"]

    func folder(for article: SavedArticle) -> URL {
        if let known = queue.sync(execute: { folders[article.id] }) { return known }
        let url = root.appendingPathComponent(Self.folderName(for: article), isDirectory: true)
        queue.sync { folders[article.id] = url }
        return url
    }

    /// `some-article-title--a1b2c3d4`. The suffix is the head of the id, which keeps two
    /// articles with the same title apart without any collision bookkeeping.
    static func folderName(for article: SavedArticle) -> String {
        let short = article.id.uuidString.prefix(8).lowercased()
        let base = slug(article.title.isEmpty ? article.host : article.title)
        return base.isEmpty ? String(short) : "\(base)--\(short)"
    }

    static func slug(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        var out = ""
        var lastWasDash = false
        for ch in folded {
            if ch.isLetter || ch.isNumber {
                out.append(Character(ch.lowercased()))
                lastWasDash = false
            } else if !lastWasDash, !out.isEmpty {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return String(out.prefix(60))
    }

    func bodyURL(for article: SavedArticle) -> URL {
        folder(for: article).appendingPathComponent(Self.bodyName)
    }

    func documentURL(for article: SavedArticle) -> URL {
        folder(for: article).appendingPathComponent(Self.documentName)
    }

    /// Where a book's own EPUB file lives, kept alongside the `body.html` flattened from
    /// it. Doubling the folder's size is the cost of the store's own rule — a folder is
    /// the complete, portable thing — and it means a better flattener can re-run later
    /// without asking the reader to fetch the book again.
    func bookURL(for article: SavedArticle) -> URL {
        folder(for: article).appendingPathComponent(Self.bookName)
    }

    func assetsDirectory(for article: SavedArticle) -> URL {
        folder(for: article).appendingPathComponent(Self.assetsName, isDirectory: true)
    }

    // MARK: - Index

    func load() -> [SavedArticle] {
        queue.sync {
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(at: root,
                                                            includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: [.skipsHiddenFiles])
            else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var found: [SavedArticle] = []
            for dir in entries {
                let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir else { continue }
                let meta = dir.appendingPathComponent(Self.metadataName)
                guard let data = try? Data(contentsOf: meta),
                      let article = try? decoder.decode(SavedArticle.self, from: data) else { continue }
                folders[article.id] = dir
                found.append(article)
            }
            return found.sorted { $0.addedAt > $1.addedAt }
        }
    }

    /// Writes one article's metadata, and moves the folder if the title has changed.
    ///
    /// An article is saved before it is read, so at first it is only a URL and the folder
    /// takes the site's name. Once extraction supplies the real title the folder is
    /// renamed to match, which is the whole point of naming folders after titles. The
    /// contents travel with it, and nothing refers to a folder by name — the asset URLs
    /// carry the article's id — so the move breaks no links.
    func save(_ article: SavedArticle) {
        queue.sync {
            let fm = FileManager.default
            let desired = root.appendingPathComponent(Self.folderName(for: article), isDirectory: true)
            if let current = folders[article.id], current != desired,
               fm.fileExists(atPath: current.path), !fm.fileExists(atPath: desired.path) {
                try? fm.moveItem(at: current, to: desired)
            }
            folders[article.id] = desired

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(article) else { return }
            try? fm.createDirectory(at: desired, withIntermediateDirectories: true)
            try? data.write(to: desired.appendingPathComponent(Self.metadataName), options: .atomic)
        }
    }

    func save(_ articles: [SavedArticle]) {
        for article in articles { save(article) }
    }

    /// Add one item, or refresh it if that URL is already saved.
    @discardableResult
    func append(_ article: SavedArticle) -> [SavedArticle] {
        var all = load()
        if let i = all.firstIndex(where: { $0.url == article.url }) {
            var existing = all[i]
            existing.addedAt = .now
            existing.isArchived = false
            if existing.title.isEmpty { existing.title = article.title }
            all[i] = existing
            save(existing)
        } else {
            all.insert(article, at: 0)
            save(article)
        }
        return all
    }

    func delete(_ article: SavedArticle) {
        let dir = folder(for: article)
        queue.sync {
            folders[article.id] = nil
            try? FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - Body

    @discardableResult
    func writeBody(_ html: String, for article: SavedArticle) -> Bool {
        let dir = folder(for: article)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try html.write(to: dir.appendingPathComponent(Self.bodyName),
                           atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    func readBody(for article: SavedArticle) -> String? {
        try? String(contentsOf: bodyURL(for: article), encoding: .utf8)
    }

    @discardableResult
    func writeDocument(_ data: Data, for article: SavedArticle) -> Bool {
        let dir = folder(for: article)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent(Self.documentName), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Copies a book's file into its folder. A copy rather than a `Data` round trip: a
    /// share extension lives in a tight memory budget and an illustrated book is tens of
    /// megabytes, so the bytes should move once, on disk, and never sit fully in memory.
    @discardableResult
    func adoptDocument(from fileURL: URL, for article: SavedArticle) -> Bool {
        let dir = folder(for: article)
        let destination = dir.appendingPathComponent(Self.bookName)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: fileURL, to: destination)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Sidecars

    /// A book's table of contents, or anything else a kind needs beside `article.json`.
    /// `name` must be on the whitelist above — this is a store for known shapes, not an
    /// arbitrary drop folder.
    @discardableResult
    func writeSidecar(_ data: Data, named name: String, for article: SavedArticle) -> Bool {
        guard Self.allowedSidecars.contains(name) else { return false }
        let dir = folder(for: article)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent(name), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func readSidecar(named name: String, for article: SavedArticle) -> Data? {
        guard Self.allowedSidecars.contains(name) else { return nil }
        return try? Data(contentsOf: folder(for: article).appendingPathComponent(name))
    }

    // MARK: - Assets

    /// Writes one picture and returns its file name. Named by a digest of the bytes, so a
    /// page that uses the same image twice stores it once.
    func writeAsset(_ data: Data, ext: String, for article: SavedArticle) -> String? {
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
    /// Both components are checked rather than trusted: the host has to parse as an id we
    /// know, and the name has to be a plain file name, so a crafted page cannot walk out
    /// of the assets folder.
    func assetFile(for url: URL) -> URL? {
        guard url.scheme == OfflineAssets.scheme,
              let host = url.host, let id = UUID(uuidString: host) else { return nil }
        let name = url.lastPathComponent
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return nil }
        var dir = queue.sync { folders[id] }
        if dir == nil {
            _ = load()                       // first request after launch
            dir = queue.sync { folders[id] }
        }
        guard let dir else { return nil }
        let file = dir.appendingPathComponent(Self.assetsName, isDirectory: true)
            .appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    // MARK: - Migration

    /// Moves a library written by the old single-index layout into folders. Runs once;
    /// the old index is kept, renamed, rather than deleted.
    private func migrateIfNeeded() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyIndexURL.path),
              let data = try? Data(contentsOf: legacyIndexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let old = try? decoder.decode([SavedArticle].self, from: data) else { return }

        for var article in old {
            let dir = root.appendingPathComponent(Self.folderName(for: article), isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if let body = article.bodyFile {
                let from = legacyBodiesDir.appendingPathComponent(body)
                try? fm.moveItem(at: from, to: dir.appendingPathComponent(Self.bodyName))
            }
            let assetsFrom = legacyAssetsDir.appendingPathComponent(article.id.uuidString, isDirectory: true)
            if fm.fileExists(atPath: assetsFrom.path) {
                try? fm.moveItem(at: assetsFrom, to: dir.appendingPathComponent(Self.assetsName, isDirectory: true))
            }
            article.bodyFile = nil
            folders[article.id] = dir
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let out = try? encoder.encode(article) {
                try? out.write(to: dir.appendingPathComponent(Self.metadataName), options: .atomic)
            }
        }
        try? fm.moveItem(at: legacyIndexURL, to: root.appendingPathComponent("index.json.migrated"))
        try? fm.removeItem(at: legacyBodiesDir)
        try? fm.removeItem(at: legacyAssetsDir)
    }
}
