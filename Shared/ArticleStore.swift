import Foundation
import CryptoKit

/// Saved reading, kept as plain files.
///
/// One folder per article, named after its title, holding everything that belongs to it:
///
///     the-worst-mistake-in-the-history--a1b2c3d4/
///         article.json      the metadata, pretty-printed
///         body.html         the reader text
///         body.md           the same article as Markdown, for anything that isn't us
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
    /// Under its own lock rather than the queue: it is looked up from the main thread on
    /// every render, and must not wait behind a scan the queue is in the middle of.
    private var folders: [UUID: URL] = [:]
    private let foldersLock = NSLock()

    private func knownFolder(_ id: UUID) -> URL? {
        foldersLock.withLock { folders[id] }
    }

    private func setFolder(_ url: URL?, for id: UUID) {
        foldersLock.withLock { folders[id] = url }
    }

    /// Where the library was last found in iCloud, so the next launch can start there.
    ///
    /// The app's own defaults rather than the group's: the share extension has no iCloud
    /// entitlement and must go on writing to the app group, whatever the app remembers.
    private static let cloudRootKey = "store.cloudRoot"

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

        // Where the library was last time. Asking iCloud where its container is takes a
        // round trip to a daemon and cannot be done here; the answer does not change
        // between launches, and the folder is either still there or it is not. Starting
        // from it means the first read is of the real library rather than of an app
        // group folder that was emptied into iCloud the first time it synced.
        if let remembered = UserDefaults.standard.url(forKey: Self.cloudRootKey),
           fm.fileExists(atPath: remembered.path) {
            root = remembered
            isCloud = true
        }
    }

    /// Runs `work` on the store's own queue and hands back what it returns, without
    /// holding whichever thread asked. Everything that scans or moves the library goes
    /// through here rather than `queue.sync`: with the library in iCloud, a read can
    /// wait on the network, and the main thread is the one place that must never happen.
    private func onQueue<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    // MARK: - What can be read right now

    /// Whether a file in the store can be read without waiting on iCloud.
    ///
    /// A file that exists in the container is not necessarily on the device: iCloud
    /// leaves what has not been asked for as a placeholder, and a plain read of one
    /// blocks until the bytes have come down — for as long as that takes, which on a
    /// poor connection is longer than the watchdog allows. So the question is asked
    /// first. A placeholder is asked for, so that it stops being one, and reported as
    /// not yet readable; the metadata query says when it has landed.
    func isReadable(_ url: URL) -> Bool {
        guard isCloud,
              let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                  .ubiquitousItemDownloadingStatus
        else { return true }
        guard status == .notDownloaded else { return true }
        requestDownload(url)
        return false
    }

    /// Files already asked for, and when. The question is asked wherever a file is
    /// about to be read — which for a page can be every frame — and the daemon does
    /// not need telling every frame.
    private var requested: [String: Date] = [:]

    private func requestDownload(_ url: URL) {
        let now = Date.now
        let due = foldersLock.withLock { () -> Bool in
            if let last = requested[url.path], now.timeIntervalSince(last) < 10 { return false }
            requested[url.path] = now
            return true
        }
        guard due else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    /// True when a file exists in the library but has not come down from iCloud yet.
    func isDownloading(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) && !isReadable(url)
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
        guard let cloud = await CloudLibrary.documentsDirectory() else { return isCloud }
        // Already there, and it is still where it was.
        if isCloud, cloud == root { return true }
        let fm = FileManager.default
        let local = localRoot
        await onQueue {
            if let entries = try? fm.contentsOfDirectory(at: local,
                                                         includingPropertiesForKeys: [.isDirectoryKey],
                                                         options: [.skipsHiddenFiles]) {
                for dir in entries where Self.isLibraryFolder(dir) {
                    let destination = cloud.appendingPathComponent(dir.lastPathComponent, isDirectory: true)
                    // The sites folder is one folder of folders, and is carried across
                    // one site at a time so what is already there keeps its own.
                    if dir.lastPathComponent == Self.sitesName {
                        Self.adoptChildren(of: dir, into: destination, droppingDuplicates: false)
                        continue
                    }
                    guard !fm.fileExists(atPath: destination.path) else { continue }
                    try? fm.setUbiquitous(true, itemAt: dir, destinationURL: destination)
                }
            }
            self.root = cloud
            self.isCloud = true
            self.foldersLock.withLock { self.folders.removeAll() }
            UserDefaults.standard.set(cloud, forKey: Self.cloudRootKey)
        }
        return true
    }

    /// Takes anything the share extension left in the app group.
    ///
    /// The extension has no iCloud entitlement — it writes where it can, and the app
    /// carries it the rest of the way on the next launch or foreground.
    func drainInbox() async {
        guard isCloud else { return }
        let fm = FileManager.default
        let inbox = localRoot
        await onQueue {
            guard let entries = try? fm.contentsOfDirectory(at: inbox,
                                                            includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: [.skipsHiddenFiles]) else { return }
            for dir in entries where Self.isLibraryFolder(dir) {
                let destination = self.root.appendingPathComponent(dir.lastPathComponent, isDirectory: true)
                if dir.lastPathComponent == Self.sitesName {
                    Self.adoptChildren(of: dir, into: destination, droppingDuplicates: true)
                    continue
                }
                if fm.fileExists(atPath: destination.path) {
                    try? fm.removeItem(at: dir)          // already have it
                } else {
                    try? fm.setUbiquitous(true, itemAt: dir, destinationURL: destination)
                }
            }
        }
    }

    /// Whether a folder in the local root is the library's own — an article, or the sites
    /// — and so something to carry into iCloud.
    ///
    /// Asked rather than assumed because the local root is not the library's alone. In
    /// the app group it is the group container's `Library` directory, and the system
    /// keeps things there too: `Library/Preferences` holds the group's `UserDefaults` —
    /// the glow, the type, and every saved preset — and `Library/Caches` is the system's
    /// as well. Taking every folder carried the preferences off into iCloud on the first
    /// sync, and deleted them outright on every foreground after that, once iCloud had a
    /// `Preferences` of its own for them to be a "duplicate" of. `cfprefsd` went on
    /// serving what it held in memory, so nothing looked wrong until it let go, and then
    /// the presets were simply gone.
    ///
    /// So a folder is taken only when it has the shape of something the store wrote: the
    /// sites folder, or a folder with an `article.json` in it. One the share extension is
    /// still writing has no metadata yet, and waits for the next pass rather than being
    /// carried across half made.
    private static func isLibraryFolder(_ dir: URL) -> Bool {
        let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        guard isDir else { return false }
        if dir.lastPathComponent == sitesName { return true }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent(metadataName).path)
    }

    /// The system's own folders, as an earlier build left them in iCloud.
    private static let strayFolderNames = ["Preferences", "Caches"]

    /// Takes back the preferences an earlier build carried into iCloud (see
    /// `isLibraryFolder`), and clears away what else it carried with them.
    ///
    /// Hands back the stray preferences file, as it was written, for the settings to
    /// take what they have lost from it. Nothing is removed until that file has been
    /// read: one still on its way down from iCloud is asked for and left, and the next
    /// call finds it. Nil when there is nothing to recover, which after the first
    /// successful call is always.
    func reclaimStrayPreferences() async -> Data? {
        guard isCloud else { return nil }
        let fm = FileManager.default
        return await onQueue {
            let root = self.root
            let preferences = root.appendingPathComponent("Preferences", isDirectory: true)
            var recovered: Data?
            if fm.fileExists(atPath: preferences.path) {
                let plist = preferences.appendingPathComponent(Self.appGroupID + ".plist")
                if fm.fileExists(atPath: plist.path) {
                    guard self.isReadable(plist),
                          let data = try? Data(contentsOf: plist) else { return nil }
                    recovered = data
                } else if self.hasPlaceholder(for: plist) {
                    try? fm.startDownloadingUbiquitousItem(at: plist)
                    return nil
                }
            }
            for name in Self.strayFolderNames {
                let dir = root.appendingPathComponent(name, isDirectory: true)
                guard fm.fileExists(atPath: dir.path), !Self.isLibraryFolder(dir) else { continue }
                try? fm.removeItem(at: dir)
            }
            return recovered
        }
    }

    /// Whether iCloud holds a file here that has not come down yet — which it shows as a
    /// hidden `.name.icloud` stand-in rather than as the file itself.
    private func hasPlaceholder(for url: URL) -> Bool {
        let stub = url.deletingLastPathComponent()
            .appendingPathComponent("." + url.lastPathComponent + ".icloud")
        return FileManager.default.fileExists(atPath: stub.path)
    }

    /// Moves each folder inside `source` into iCloud under `destination`, one at a time.
    /// A folder already at the destination came from another device and wins; the local
    /// copy is dropped only where asked, and `source` is removed once it is empty.
    private static func adoptChildren(of source: URL, into destination: URL, droppingDuplicates: Bool) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: source,
                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles]) else { return }
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for child in entries {
            let target = destination.appendingPathComponent(child.lastPathComponent, isDirectory: true)
            if fm.fileExists(atPath: target.path) {
                if droppingDuplicates { try? fm.removeItem(at: child) }
                continue
            }
            try? fm.setUbiquitous(true, itemAt: child, destinationURL: target)
        }
        if droppingDuplicates,
           let left = try? fm.contentsOfDirectory(atPath: source.path), left.isEmpty {
            try? fm.removeItem(at: source)
        }
    }

    // MARK: - Layout

    private static let metadataName = "article.json"
    private static let bodyName = "body.html"
    private static let markdownName = "body.md"
    private static let documentName = "document.pdf"
    private static let bookName = "book.epub"
    private static let assetsName = "assets"
    /// The sites, beside the articles rather than among them: one folder of folders,
    /// each the shape `Sites` gives it.
    static let sitesName = "Sites"

    var sitesRoot: URL { root.appendingPathComponent(Self.sitesName, isDirectory: true) }
    /// Sidecar files a kind may keep beside `article.json`. Whitelisted rather than
    /// taking any name, so this stays a store for known shapes rather than a place
    /// anything can be dropped.
    private static let allowedSidecars: Set<String> = ["contents.json", "highlights.json"]

    func folder(for article: SavedArticle) -> URL {
        if let known = knownFolder(article.id) { return known }
        let url = root.appendingPathComponent(Self.folderName(for: article), isDirectory: true)
        setFolder(url, for: article.id)
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

    /// The portable copy. Nothing in the app reads this — it is written for whatever
    /// opens the folder next.
    func markdownURL(for article: SavedArticle) -> URL {
        folder(for: article).appendingPathComponent(Self.markdownName)
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

    /// What a scan of the library found: the articles it could read, and the folders it
    /// could not — ones iCloud has not brought down yet, which are asked for and left
    /// for the next scan. A caller holding an article from an earlier scan should keep
    /// it while its folder is on that list: the folder is there, only its bytes are not.
    struct Snapshot {
        var articles: [SavedArticle] = []
        /// Folder names, as written on disk.
        var held: [String] = []

        /// Whether a folder for this article is among those still on their way down.
        /// Matched on the id suffix a folder name carries rather than the whole name —
        /// the title half can have been changed by another device.
        func holds(_ article: SavedArticle) -> Bool {
            let short = article.id.uuidString.prefix(8).lowercased()
            return held.contains { name in
                name == short || name.hasSuffix("--" + short)
            }
        }
    }

    func load() -> [SavedArticle] { queue.sync { scan().articles } }

    /// The same scan, off whichever thread asked for it.
    func snapshot() async -> Snapshot { await onQueue { self.scan() } }

    /// Reads every folder's metadata. Runs on the queue; `load()` and `snapshot()` are
    /// the two ways in.
    private func scan() -> Snapshot {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root,
                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles])
        else { return Snapshot() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var found = Snapshot()
        for dir in entries {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            let meta = dir.appendingPathComponent(Self.metadataName)
            guard isReadable(meta) else {
                found.held.append(dir.lastPathComponent)
                continue
            }
            guard let data = try? Data(contentsOf: meta),
                  let article = try? decoder.decode(SavedArticle.self, from: data) else { continue }
            setFolder(dir, for: article.id)
            found.articles.append(article)
        }
        found.articles.sort { $0.addedAt > $1.addedAt }
        return found
    }

    // MARK: - Index cache

    /// One file holding what the last scan found, kept in the app group where nothing
    /// else has to be asked for it. It is what the shelf is drawn from on the first
    /// frame: with the library in iCloud a scan can take a moment and can come back
    /// short, and the opening is not the place to wait for it. Never the truth — the
    /// folders are — only what the truth looked like last time.
    private var indexCacheURL: URL { localRoot.appendingPathComponent("index-cache.json") }

    func loadIndexCache() -> [SavedArticle]? {
        guard let data = try? Data(contentsOf: indexCacheURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([SavedArticle].self, from: data)
    }

    func writeIndexCache(_ articles: [SavedArticle]) {
        let url = indexCacheURL
        queue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(articles) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Writes one article's metadata, and moves the folder if the title has changed.
    ///
    /// An article is saved before it is read, so at first it is only a URL and the folder
    /// takes the site's name. Once extraction supplies the real title the folder is
    /// renamed to match, which is the whole point of naming folders after titles. The
    /// contents travel with it, and nothing refers to a folder by name — the asset URLs
    /// carry the article's id — so the move breaks no links.
    ///
    /// Queued rather than waited for. Nothing the caller does next depends on the bytes
    /// being on disk, and the queue keeps its order — a read that follows sees the write.
    func save(_ article: SavedArticle) {
        queue.async {
            let fm = FileManager.default
            let desired = self.root.appendingPathComponent(Self.folderName(for: article), isDirectory: true)
            if let current = self.knownFolder(article.id), current != desired,
               fm.fileExists(atPath: current.path), !fm.fileExists(atPath: desired.path) {
                try? fm.moveItem(at: current, to: desired)
            }
            self.setFolder(desired, for: article.id)

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
        setFolder(nil, for: article.id)
        queue.async { try? FileManager.default.removeItem(at: dir) }
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
        let url = bodyURL(for: article)
        guard isReadable(url) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// What the body file is right now, as one string: its size and when it was last
    /// written, or "" when there is no file. Changes exactly when the text would read
    /// differently, so it is the key a reader can hold the text under.
    func bodyStamp(for article: SavedArticle) -> String {
        let url = bodyURL(for: article)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        else { return "" }
        let size = values.fileSize ?? 0
        let stamp = values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        return "\(size)|\(stamp)"
    }

    /// The saved text exists but is still on its way down from iCloud.
    func isBodyDownloading(for article: SavedArticle) -> Bool {
        isDownloading(bodyURL(for: article))
    }

    func isDocumentDownloading(for article: SavedArticle) -> Bool {
        isDownloading(documentURL(for: article))
    }

    /// Writes the Markdown sidecar. Its absence is never an error worth surfacing: an
    /// article whose portable copy could not be written is still a saved article.
    @discardableResult
    func writeMarkdown(_ markdown: String, for article: SavedArticle) -> Bool {
        let dir = folder(for: article)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try markdown.write(to: dir.appendingPathComponent(Self.markdownName),
                               atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    func readMarkdown(for article: SavedArticle) -> String? {
        let url = markdownURL(for: article)
        guard isReadable(url) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
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
        let url = folder(for: article).appendingPathComponent(name)
        guard isReadable(url) else { return nil }
        return try? Data(contentsOf: url)
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
        var dir = knownFolder(id)
        if dir == nil {
            _ = load()                       // first request after launch
            dir = knownFolder(id)
        }
        guard let dir else { return nil }
        let file = dir.appendingPathComponent(Self.assetsName, isDirectory: true)
            .appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: file.path), isReadable(file) else { return nil }
        return file
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
            setFolder(dir, for: article.id)
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
