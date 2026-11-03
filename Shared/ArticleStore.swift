import Foundation
import CryptoKit

/// Saved reading, kept as plain files.
///
/// One note per article, named after its title, and beside the notes one folder of
/// folders holding everything else each article needs:
///
///     The Worst Mistake in the History of the Human Race.md
///     Attachments/
///         The Worst Mistake in the History of the Human Race/
///             state.json        the app's record of the article, pretty-printed
///             body.html         the reader text
///             document.pdf      instead of body.html, for a saved PDF
///             book.epub         beside it, for a book
///             highlights.json   contents.json
///             assets/           pictures pulled down for offline reading
///     Sites/
///
/// The note is Markdown with YAML front matter — see `NoteFile` — and is the part of the
/// library meant to be read and kept by anything that isn't this app, Obsidian first.
///
/// The shape is deliberate rather than incidental. A single index file would be the
/// obvious thing and is the wrong thing to sync: two devices editing different articles
/// each write the whole index, and whichever syncs last silently discards the other's
/// work. A note and a folder per article means independent edits never touch the same
/// file, so there is nothing to resolve. It also means the library is legible in Finder
/// and portable by any means that copies folders.
///
/// What ties an article's note to its folder is the id both carry — `evening-reader-id`
/// in the note, `id` in `state.json` — so either can be renamed without losing the other.
final class ArticleStore {
    static let appGroupID = "group.com.amberglow.shared"

    /// Where the library lives now. Starts local and moves to iCloud once the container
    /// has been resolved, which cannot be done synchronously at launch.
    private(set) var root: URL
    /// The app group folder. Always writable, and where the share extension puts things.
    let localRoot: URL
    /// The app's own Documents folder, which the Files app shows under On My iPhone:
    /// where the library lives in the app when it is not in iCloud. Nil in the share
    /// extension, which cannot reach it and goes on writing to the app group.
    let deviceRoot: URL?
    let usesAppGroup: Bool
    private(set) var isCloud = false

    private let legacyIndexURL: URL
    private let legacyBodiesDir: URL
    private let legacyAssetsDir: URL
    private let queue = DispatchQueue(label: "com.amberglow.store", qos: .userInitiated)

    /// article id -> its attachments folder, so an amber-asset:// URL can be resolved
    /// without a scan. Under its own lock rather than the queue: it is looked up from the
    /// main thread on every render, and must not wait behind a scan the queue is in the
    /// middle of.
    private var folders: [UUID: URL] = [:]
    /// article id -> its note.
    private var notes: [UUID: URL] = [:]
    /// article id -> what its note said for the fields that go both ways, when it was last
    /// read or written. A save that changes none of them — a scroll, an open — leaves the
    /// note alone rather than reading it to find that out.
    private var signatures: [UUID: String] = [:]
    /// The last scan's articles by address, for what the share extension sends to be
    /// checked against.
    private var bySource: [URL: SavedArticle] = [:]
    private let foldersLock = NSLock()

    private func knownFolder(_ id: UUID) -> URL? {
        foldersLock.withLock { folders[id] }
    }

    private func setFolder(_ url: URL?, for id: UUID) {
        foldersLock.withLock { folders[id] = url }
    }

    private func signature(_ id: UUID) -> String? {
        foldersLock.withLock { signatures[id] }
    }

    private func setSignature(_ signature: String?, for id: UUID) {
        foldersLock.withLock { signatures[id] = signature }
    }

    private func forget(_ id: UUID) {
        foldersLock.withLock {
            folders[id] = nil
            notes[id] = nil
            signatures[id] = nil
        }
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
        deviceRoot = Bundle.main.bundleURL.pathExtension == "appex" ? nil
            : fm.urls(for: .documentDirectory, in: .userDomainMask).first
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

        // Otherwise the library is on this device, in Documents where the reader can see
        // it. What is in the app group — a library an earlier build kept there, or what
        // the share extension has left since — comes across first, so the first read is
        // of all of it. Moves within the device, so this is renames, not copies.
        if !isCloud, let deviceRoot {
            Self.carry(contentsOf: localRoot, into: deviceRoot, ubiquitous: false,
                       droppingDuplicates: false, notes: false)
            root = deviceRoot
        }
    }

    /// A library opened where it already is, by something that is not the app: the Mac's
    /// browser extensions, writing into the library in iCloud from outside it.
    ///
    /// Nothing is moved, migrated or adopted, and nothing local is kept — no app group,
    /// no Documents, no index cache worth reading. The folder is the library, as it is.
    /// With no device of its own, a scan never clears a folder whose note is missing:
    /// that is the app's call, made where the reader is.
    init(libraryAt root: URL) {
        self.root = root
        localRoot = root
        deviceRoot = nil
        usesAppGroup = false
        isCloud = root.path.contains("/Mobile Documents/")
        legacyIndexURL = root.appendingPathComponent("index.json")
        legacyBodiesDir = root.appendingPathComponent("Bodies", isDirectory: true)
        legacyAssetsDir = root.appendingPathComponent("Assets", isDirectory: true)
    }

    /// Waits for every write queued before it. For a writer whose process ends as soon
    /// as it has saved, before a queued write would otherwise have run.
    func flush() async {
        await onQueue {}
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
    /// not need telling every frame. Under a lock of its own: it is asked while the
    /// folders' lock is held, when a name is being chosen.
    private var requested: [String: Date] = [:]
    private let requestedLock = NSLock()

    private func requestDownload(_ url: URL) {
        let now = Date.now
        let due = requestedLock.withLock { () -> Bool in
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
    /// Anything already on this device is moved across the first time. An article that is
    /// already there wins — it came from another device and is at least as current as
    /// what is here.
    ///
    /// Returns true when the library is in iCloud afterwards.
    @discardableResult
    func adoptCloud() async -> Bool {
        guard let cloud = await CloudLibrary.documentsDirectory() else { return isCloud }
        // Already there, and it is still where it was.
        if isCloud, cloud == root { return true }
        // Documents, where the library has been on this device, and the app group, for
        // what an earlier build kept there. What the share extension has left since is
        // the inbox's, and `drainInbox` takes it.
        let local = localRoot
        let device = deviceRoot
        await onQueue {
            if let device {
                Self.carry(contentsOf: device, into: cloud, ubiquitous: true,
                           droppingDuplicates: false, notes: true)
            }
            Self.carry(contentsOf: local, into: cloud, ubiquitous: true,
                       droppingDuplicates: false, notes: false)
            self.root = cloud
            self.isCloud = true
            self.foldersLock.withLock {
                self.folders.removeAll()
                self.notes.removeAll()
                self.signatures.removeAll()
            }
            UserDefaults.standard.set(cloud, forKey: Self.cloudRootKey)
        }
        return true
    }

    /// Takes anything the share extension left in the app group.
    ///
    /// The extension has no iCloud entitlement and cannot reach the app's Documents — it
    /// writes where it can, and the app carries it the rest of the way, into iCloud or
    /// onto the device, on the next launch or foreground.
    func drainInbox() async {
        let inbox = localRoot
        await onQueue {
            guard self.root != inbox else { return }
            self.takeAlreadySaved(from: inbox)
            Self.carry(contentsOf: inbox, into: self.root, ubiquitous: self.isCloud,
                       droppingDuplicates: true, notes: true)
        }
    }

    /// A link shared again is the article already saved, brought back to the top and out
    /// of the archive — not a second copy of it. The extension can only see what is in the
    /// app group, so the check it makes on its own side misses everything already
    /// carried over; it is made again here, against the library.
    private func takeAlreadySaved(from inbox: URL) {
        let fm = FileManager.default
        let entries = ((try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil,
                                                    options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension.lowercased() == Self.noteExtension }
        guard !entries.isEmpty else { return }
        // The library has to have been read to be checked against; at launch the inbox
        // can be reached first.
        if foldersLock.withLock({ bySource.isEmpty }) { _ = scan() }
        let known = foldersLock.withLock { bySource }
        for note in entries {
            guard let id = Self.noteID(at: note),
                  let folder = Self.attachmentsFolder(for: id, named: note.deletingPathExtension().lastPathComponent,
                                                      in: inbox),
                  let incoming = Self.record(in: folder),
                  var existing = known[incoming.url], existing.id != incoming.id else { continue }
            existing.addedAt = incoming.addedAt
            existing.isArchived = false
            write(existing)
            try? fm.removeItem(at: note)
            try? fm.removeItem(at: folder)
        }
    }

    /// Moves the library in `source` into `destination` — into iCloud when `ubiquitous`,
    /// otherwise across the device. An article already at the destination wins; the one
    /// being moved is dropped only where asked, and otherwise left alone.
    ///
    /// Notes are taken only where asked: in the app group they are the share extension's,
    /// and go through `drainInbox`, which checks them against the library first.
    private static func carry(contentsOf source: URL, into destination: URL,
                              ubiquitous: Bool, droppingDuplicates: Bool, notes: Bool) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: source,
                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles]) else { return }
        for entry in entries {
            if entry.pathExtension.lowercased() == noteExtension {
                guard notes, let id = noteID(at: entry) else { continue }
                carryNote(entry, id: id, from: source, into: destination,
                          ubiquitous: ubiquitous, droppingDuplicates: droppingDuplicates)
                continue
            }
            guard isLibraryFolder(entry) else { continue }
            let target = destination.appendingPathComponent(entry.lastPathComponent, isDirectory: true)
            // The sites folder is one folder of folders, and is carried across one site
            // at a time so what is already there keeps its own.
            if entry.lastPathComponent == sitesName {
                adoptChildren(of: entry, into: target, ubiquitous: ubiquitous,
                              droppingDuplicates: droppingDuplicates)
            } else if fm.fileExists(atPath: target.path) {
                if droppingDuplicates { try? fm.removeItem(at: entry) }   // already have it
            } else {
                // A folder in the old layout. It is turned into a note once it is there.
                move(entry, to: target, ubiquitous: ubiquitous)
            }
        }
    }

    /// Moves one note and its attachments folder. A note of the same name already at the
    /// destination is either this article — the same id — and wins, or another one, and
    /// this one takes the next free name, its links following.
    private static func carryNote(_ note: URL, id: UUID, from source: URL, into destination: URL,
                                  ubiquitous: Bool, droppingDuplicates: Bool) {
        let fm = FileManager.default
        let base = note.deletingPathExtension().lastPathComponent
        let folder = attachmentsFolder(for: id, named: base, in: source)
        let attachments = destination.appendingPathComponent(attachmentsName, isDirectory: true)

        var name = base
        var n = 2
        while true {
            let there = destination.appendingPathComponent(name + "." + noteExtension)
            let noteThere = fm.fileExists(atPath: there.path)
                || fm.fileExists(atPath: placeholder(for: there).path)
            let folderThere = fm.fileExists(atPath: attachments.appendingPathComponent(name).path)
            if !noteThere && !folderThere { break }
            if noteThere, noteID(at: there) == id {
                if droppingDuplicates {
                    try? fm.removeItem(at: note)
                    if let folder { try? fm.removeItem(at: folder) }
                }
                return
            }
            name = "\(base) \(n)"
            n += 1
        }

        if let folder {
            if folder.lastPathComponent != name {
                repoint(note, from: folder.lastPathComponent, to: name)
            }
            try? fm.createDirectory(at: attachments, withIntermediateDirectories: true)
            move(folder, to: attachments.appendingPathComponent(name, isDirectory: true), ubiquitous: ubiquitous)
        }
        move(note, to: destination.appendingPathComponent(name + "." + noteExtension), ubiquitous: ubiquitous)
    }

    private static func move(_ item: URL, to destination: URL, ubiquitous: Bool) {
        let fm = FileManager.default
        if ubiquitous {
            try? fm.setUbiquitous(true, itemAt: item, destinationURL: destination)
        } else {
            try? fm.moveItem(at: item, to: destination)
        }
    }

    /// Whether a folder in the local root is the library's own — an article in the old
    /// layout, or the sites — and so something to carry into iCloud.
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
    /// carried across half made. Notes are taken by their id instead; see `carry`.
    private static func isLibraryFolder(_ dir: URL) -> Bool {
        guard isDirectory(dir) else { return false }
        if dir.lastPathComponent == sitesName { return true }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent(metadataName).path)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
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
        FileManager.default.fileExists(atPath: Self.placeholder(for: url).path)
    }

    private static func placeholder(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
    }

    /// Moves each folder inside `source` under `destination`, one at a time. A folder
    /// already at the destination came from elsewhere and wins; the moving copy is
    /// dropped only where asked, and `source` is removed once it is empty.
    private static func adoptChildren(of source: URL, into destination: URL,
                                      ubiquitous: Bool, droppingDuplicates: Bool) {
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
            move(child, to: target, ubiquitous: ubiquitous)
        }
        if droppingDuplicates,
           let left = try? fm.contentsOfDirectory(atPath: source.path), left.isEmpty {
            try? fm.removeItem(at: source)
        }
    }

    // MARK: - Layout

    private static let noteExtension = "md"
    /// The app's record of an article, in its attachments folder.
    private static let stateName = "state.json"
    private static let bodyName = "body.html"
    private static let documentName = "document.pdf"
    private static let bookName = "book.epub"
    private static let assetsName = "assets"
    /// The old layout's record and Markdown copy, kept in the article's own folder at the
    /// top of the library. Read only to turn such a folder into a note; see `convert`.
    private static let metadataName = "article.json"
    private static let markdownName = "body.md"
    /// Everything an article has besides its note: one folder per article.
    static let attachmentsName = "Attachments"
    /// The sites, beside the articles rather than among them: one folder of folders,
    /// each the shape `Sites` gives it.
    static let sitesName = "Sites"

    var sitesRoot: URL { root.appendingPathComponent(Self.sitesName, isDirectory: true) }
    private var attachmentsRoot: URL { root.appendingPathComponent(Self.attachmentsName, isDirectory: true) }
    /// Sidecar files a kind may keep beside `state.json`. Whitelisted rather than
    /// taking any name, so this stays a store for known shapes rather than a place
    /// anything can be dropped.
    private static let allowedSidecars: Set<String> = ["contents.json", "highlights.json"]

    /// The article's attachments folder, where everything but its note lives.
    func folder(for article: SavedArticle) -> URL {
        place(for: article).folder
    }

    /// Where an article's note and folder are, deciding their name the first time it is
    /// asked: the title, or the title and a number when another article has it already.
    ///
    /// Decided once, under the lock, and remembered — the first write to an article and
    /// the first picture pulled down for it can ask from different threads, and must be
    /// told the same place.
    private func place(for article: SavedArticle) -> (note: URL, folder: URL) {
        foldersLock.withLock {
            let id = article.id
            let note = notes[id] ?? noteURL(named: uniqueName(NoteFile.fileName(for: article.displayTitle), for: id))
            notes[id] = note
            let folder = folders[id] ?? attachmentsRoot.appendingPathComponent(
                uniqueName(note.deletingPathExtension().lastPathComponent, for: id), isDirectory: true)
            folders[id] = folder
            return (note, folder)
        }
    }

    private func noteURL(named name: String) -> URL {
        root.appendingPathComponent(name + "." + Self.noteExtension)
    }

    /// `base`, or the first of "base 2", "base 3"… that no other article has. Called with
    /// the folders' lock held.
    private func uniqueName(_ base: String, for id: UUID) -> String {
        guard isTaken(base, by: id) else { return base }
        var n = 2
        while isTaken("\(base) \(n)", by: id) { n += 1 }
        return "\(base) \(n)"
    }

    /// Whether a note or attachments folder by this name belongs to some other article —
    /// one already placed, or one on disk whose id is not this one's. Called with the
    /// folders' lock held.
    private func isTaken(_ name: String, by id: UUID) -> Bool {
        let note = noteURL(named: name)
        let folder = attachmentsRoot.appendingPathComponent(name, isDirectory: true)
        if notes.contains(where: { $0.key != id && $0.value.path == note.path }) { return true }
        if folders.contains(where: { $0.key != id && $0.value.path == folder.path }) { return true }
        let fm = FileManager.default
        if notes[id]?.path != note.path {
            if fm.fileExists(atPath: Self.placeholder(for: note).path) { return true }
            if fm.fileExists(atPath: note.path), !isReadable(note) || Self.noteID(at: note) != id { return true }
        }
        if folders[id]?.path != folder.path, fm.fileExists(atPath: folder.path) {
            let state = folder.appendingPathComponent(Self.stateName)
            if !isReadable(state) || Self.record(in: folder)?.id != id { return true }
        }
        return false
    }

    /// The relative link from a note to its article's pictures, for the note's Markdown.
    func assetsLinkPath(for article: SavedArticle) -> String {
        NoteFile.attachmentsPath(folder(for: article).lastPathComponent, Self.assetsName)
    }

    /// `some-article-title--a1b2c3d4`: the old layout's folder name, still made by the
    /// first layout's migration, which runs before the old layout's own.
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
    /// it. Doubling the folder's size is the cost of the store's own rule — an article's
    /// files are the complete, portable thing — and it means a better flattener can
    /// re-run later without asking the reader to fetch the book again.
    func bookURL(for article: SavedArticle) -> URL {
        folder(for: article).appendingPathComponent(Self.bookName)
    }

    func assetsDirectory(for article: SavedArticle) -> URL {
        folder(for: article).appendingPathComponent(Self.assetsName, isDirectory: true)
    }

    // MARK: - Reading what is on disk

    /// The id in a note's front matter, if it is one of ours.
    private static func noteID(at url: URL) -> UUID? {
        guard isDownloaded(url), let head = readHead(url),
              let fm = FrontMatter.split(head).frontMatter,
              let value = fm.value(NoteFile.idKey) else { return nil }
        return UUID(uuidString: value)
    }

    /// The record in an attachments folder.
    private static func record(in folder: URL) -> SavedArticle? {
        let state = folder.appendingPathComponent(stateName)
        guard isDownloaded(state), let data = try? Data(contentsOf: state) else { return nil }
        return try? decoder.decode(SavedArticle.self, from: data)
    }

    /// Where an article's attachments are, beside one of its notes: the folder of the
    /// note's own name when that is this article's, otherwise whichever folder is.
    private static func attachmentsFolder(for id: UUID, named name: String, in root: URL) -> URL? {
        let attachments = root.appendingPathComponent(attachmentsName, isDirectory: true)
        let named = attachments.appendingPathComponent(name, isDirectory: true)
        if record(in: named)?.id == id { return named }
        let all = (try? FileManager.default.contentsOfDirectory(at: attachments, includingPropertiesForKeys: nil,
                                                                options: [.skipsHiddenFiles])) ?? []
        return all.first { record(in: $0)?.id == id }
    }

    /// A static stand-in for `isReadable`, for the moves made before the library has an
    /// instance to ask: true unless iCloud says the bytes are not here.
    private static func isDownloaded(_ url: URL) -> Bool {
        let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            .ubiquitousItemDownloadingStatus
        return status != .notDownloaded
    }

    /// The start of a note — enough for its front matter, without reading a long article
    /// to the end on every scan. The whole note when the front matter runs longer.
    private static func readHead(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16_384) else { return nil }
        let head = String(decoding: data, as: UTF8.self)
        if data.count < 16_384 || FrontMatter.split(head).frontMatter != nil { return head }
        guard let rest = try? handle.readToEnd() else { return head }
        return String(decoding: data + rest, as: UTF8.self)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    // MARK: - Index

    /// What a scan of the library found: the articles it could read, and the ones it
    /// could not yet — notes or records iCloud has not brought down, which are asked for
    /// and left for the next scan. A caller holding an article from an earlier scan
    /// should keep it while it is on that list: it is there, only its bytes are not.
    struct Snapshot {
        var articles: [SavedArticle] = []
        /// Articles known from an earlier scan whose note or record is on its way down.
        var heldIDs: Set<UUID> = []
        /// Folders in the old layout still on their way down, by name.
        var heldLegacy: [String] = []

        /// Whether this article is among those still on their way down. An old-layout
        /// folder is matched on the id suffix its name carries rather than the whole name
        /// — the title half can have been changed by another device.
        func holds(_ article: SavedArticle) -> Bool {
            if heldIDs.contains(article.id) { return true }
            let short = article.id.uuidString.prefix(8).lowercased()
            return heldLegacy.contains { name in
                name == short || name.hasSuffix("--" + short)
            }
        }
    }

    func load() -> [SavedArticle] { queue.sync { scan().articles } }

    /// The same scan, off whichever thread asked for it.
    func snapshot() async -> Snapshot { await onQueue { self.scan() } }

    /// Reads every note, and the record beside it. Runs on the queue; `load()` and
    /// `snapshot()` are the two ways in.
    ///
    /// The record in `state.json` is the app's; the note says what the reader may have
    /// changed — the title, the status and the tags — and where they differ, the note is
    /// taken at its word. A note whose record is missing is still an article, made from
    /// its front matter alone.
    private func scan() -> Snapshot {
        let fm = FileManager.default
        var found = Snapshot()
        convertOldFolders(into: &found)

        // What each attachments folder says, by the id it carries.
        var records: [UUID: (folder: URL, article: SavedArticle)] = [:]
        var heldFolders: Set<String> = []
        let dirs = (try? fm.contentsOfDirectory(at: attachmentsRoot, includingPropertiesForKeys: [.isDirectoryKey],
                                                options: [.skipsHiddenFiles])) ?? []
        for dir in dirs where Self.isDirectory(dir) {
            let state = dir.appendingPathComponent(Self.stateName)
            if !fm.fileExists(atPath: state.path) {
                // A conversion that stopped before its record was renamed. Finished here.
                let old = dir.appendingPathComponent(Self.metadataName)
                if fm.fileExists(atPath: old.path), isReadable(old) {
                    try? fm.moveItem(at: old, to: state)
                } else {
                    if hasPlaceholder(for: state) || hasPlaceholder(for: old) {
                        heldFolders.insert(dir.lastPathComponent)
                    }
                    continue
                }
            }
            guard isReadable(state) else {
                heldFolders.insert(dir.lastPathComponent)
                continue
            }
            guard let data = try? Data(contentsOf: state),
                  let article = try? Self.decoder.decode(SavedArticle.self, from: data),
                  records[article.id] == nil else { continue }
            records[article.id] = (dir, article)
        }

        // The notes, and the articles they make.
        var noteIDs: Set<UUID> = []
        var heldNotes: Set<String> = []
        let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                                   options: [])) ?? []
        let stubSuffix = "." + Self.noteExtension + ".icloud"
        for url in entries {
            let name = url.lastPathComponent
            if name.hasPrefix(".") {
                if name.hasSuffix(stubSuffix) { heldNotes.insert(String(name.dropFirst().dropLast(stubSuffix.count))) }
                continue
            }
            guard url.pathExtension.lowercased() == Self.noteExtension else { continue }
            let base = url.deletingPathExtension().lastPathComponent
            guard isReadable(url) else {
                heldNotes.insert(base)
                continue
            }
            guard let head = Self.readHead(url),
                  let front = FrontMatter.split(head).frontMatter,
                  let id = front.value(NoteFile.idKey).flatMap(UUID.init(uuidString:)),
                  !noteIDs.contains(id) else { continue }
            let changed = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .now

            var article: SavedArticle
            if let record = records[id] {
                article = record.article
            } else if heldFolders.contains(knownFolder(id)?.lastPathComponent ?? base) {
                // The record is on its way down. Until it lands, what was held stands.
                found.heldIDs.insert(id)
                continue
            } else if let made = NoteFile.article(from: front, id: id, changed: changed) {
                article = made
            } else {
                continue
            }
            noteIDs.insert(id)
            NoteFile.overlay(front, onto: &article, changed: changed)
            foldersLock.withLock {
                notes[id] = url
                if let folder = records[id]?.folder { folders[id] = folder }
                signatures[id] = NoteFile.signature(of: front)
            }
            found.articles.append(article)
        }

        // Known from before and on their way down, by the names they had then.
        foldersLock.withLock {
            for (id, url) in notes where !noteIDs.contains(id)
                && heldNotes.contains(url.deletingPathExtension().lastPathComponent) {
                found.heldIDs.insert(id)
            }
            for (id, url) in folders where !noteIDs.contains(id) && heldFolders.contains(url.lastPathComponent) {
                found.heldIDs.insert(id)
            }
            bySource = Dictionary(found.articles.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        }

        // Folders whose note is gone: deleted, in Finder or Obsidian, which deletes the
        // article. Only in the app's own library, and only after a while — see
        // `clearOrphans`.
        if deviceRoot != nil, root != localRoot {
            let orphans = records.values
                .filter { !noteIDs.contains($0.article.id) && !found.heldIDs.contains($0.article.id)
                    && !heldNotes.contains($0.folder.lastPathComponent) }
                .map(\.folder)
            clearOrphans(orphans)
        }

        found.articles.sort { $0.addedAt > $1.addedAt }
        return found
    }

    /// When each attachments folder without a note was first seen that way, by name.
    private static let orphansKey = "store.orphans"
    /// How long a folder whose note is gone is kept before it is taken as deleted.
    private static let orphanGrace: TimeInterval = 3 * 24 * 60 * 60

    /// Removes the folders whose notes have been gone for a while.
    ///
    /// Not at once. A note can be missing for reasons that are not a deletion — moved
    /// out and back, or caught between iCloud's report of one item and the next — and a
    /// folder is what holds the article's pictures and its book. So it is kept, out of
    /// the library, until it has been without a note for days, and then it goes.
    private func clearOrphans(_ orphans: [URL]) {
        let defaults = UserDefaults.standard
        let seen = defaults.dictionary(forKey: Self.orphansKey) as? [String: Double] ?? [:]
        let now = Date.now.timeIntervalSince1970
        var next: [String: Double] = [:]
        for folder in orphans {
            let first = seen[folder.lastPathComponent] ?? now
            if now - first > Self.orphanGrace {
                try? FileManager.default.removeItem(at: folder)
            } else {
                next[folder.lastPathComponent] = first
            }
        }
        if next != seen { defaults.set(next, forKey: Self.orphansKey) }
    }

    // MARK: - The old layout

    /// Turns every folder in the old layout at the top of the library into a note and an
    /// attachments folder. Not only once: another device on an earlier build goes on
    /// writing the old layout into iCloud, and what it writes is taken up the same way.
    private func convertOldFolders(into found: inout Snapshot) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles]) else { return }
        for dir in entries where Self.isDirectory(dir) {
            let name = dir.lastPathComponent
            guard name != Self.attachmentsName, name != Self.sitesName else { continue }
            let meta = dir.appendingPathComponent(Self.metadataName)
            guard fm.fileExists(atPath: meta.path) || hasPlaceholder(for: meta) else { continue }
            if !convert(dir) { found.heldLegacy.append(name) }
        }
    }

    /// One folder in the old layout, made into a note and an attachments folder.
    ///
    /// The note is written first and the folder moved after, so a conversion cut short
    /// leaves the old folder where it was, to be converted again — into the same note,
    /// which carries the same id and so is taken as this article's own.
    ///
    /// False when part of it is still on its way down from iCloud, to be tried again.
    private func convert(_ dir: URL) -> Bool {
        let fm = FileManager.default
        let meta = dir.appendingPathComponent(Self.metadataName)
        guard isReadable(meta) else { return false }
        guard let data = try? Data(contentsOf: meta),
              var article = try? Self.decoder.decode(SavedArticle.self, from: data) else { return true }
        article.bodyFile = nil

        // Whatever the note is made from has to be here first.
        let markdown = dir.appendingPathComponent(Self.markdownName)
        var oldBody: String?
        if fm.fileExists(atPath: markdown.path) || hasPlaceholder(for: markdown) {
            guard isReadable(markdown) else { return false }
            oldBody = try? String(contentsOf: markdown, encoding: .utf8)
        }
        let highlightsURL = dir.appendingPathComponent(HighlightsFile.sidecarName)
        var highlights: [Highlight] = []
        if fm.fileExists(atPath: highlightsURL.path) || hasPlaceholder(for: highlightsURL) {
            guard isReadable(highlightsURL) else { return false }
            if let data = try? Data(contentsOf: highlightsURL) {
                highlights = (try? Self.decoder.decode([Highlight].self, from: data)) ?? []
            }
        }

        forget(article.id)
        let place = self.place(for: article)
        let folderName = place.folder.lastPathComponent

        // The old Markdown copy pointed at `assets/` beside it; the note is a level up.
        var body: String
        if let oldBody {
            body = FrontMatter.split(oldBody).body.replacingOccurrences(
                of: "](\(Self.assetsName)/", with: "](\(NoteFile.attachmentsPath(folderName, Self.assetsName))/")
        } else {
            body = NoteFile.defaultBody(for: article, folderName: folderName)
        }
        body = NoteFile.replacingHighlights(in: body, with: NoteFile.highlightsSection(highlights))
        var front = FrontMatter()
        NoteFile.apply(article, to: &front)
        guard (try? NoteFile.compose(front, body: body).write(to: place.note, atomically: true, encoding: .utf8)) != nil
        else { return true }

        try? fm.createDirectory(at: attachmentsRoot, withIntermediateDirectories: true)
        if fm.fileExists(atPath: place.folder.path) {
            // Part of it came across before the last attempt stopped; the rest follows.
            let children = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for child in children {
                let target = place.folder.appendingPathComponent(child.lastPathComponent)
                if !fm.fileExists(atPath: target.path) { try? fm.moveItem(at: child, to: target) }
            }
            try? fm.removeItem(at: dir)
        } else {
            guard (try? fm.moveItem(at: dir, to: place.folder)) != nil else { return true }
        }
        if let state = try? Self.encoder.encode(article) {
            try? state.write(to: place.folder.appendingPathComponent(Self.stateName), options: .atomic)
        }
        try? fm.removeItem(at: place.folder.appendingPathComponent(Self.metadataName))
        try? fm.removeItem(at: place.folder.appendingPathComponent(Self.markdownName))
        setSignature(NoteFile.signature(of: article), for: article.id)
        return true
    }

    // MARK: - Index cache

    /// One file holding what the last scan found, kept in the app group where nothing
    /// else has to be asked for it. It is what the shelf is drawn from on the first
    /// frame: with the library in iCloud a scan can take a moment and can come back
    /// short, and the opening is not the place to wait for it. Never the truth — the
    /// notes are — only what the truth looked like last time.
    private var indexCacheURL: URL { localRoot.appendingPathComponent("index-cache.json") }

    func loadIndexCache() -> [SavedArticle]? {
        guard let data = try? Data(contentsOf: indexCacheURL) else { return nil }
        return try? Self.decoder.decode([SavedArticle].self, from: data)
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

    // MARK: - Writing

    /// Writes one article's record, and makes its note if it has none.
    ///
    /// The note itself is only touched when its title, status or tags would read
    /// differently, so the scroll position and the last time it was opened — which
    /// change all the time — never rewrite a file the reader may have open somewhere.
    ///
    /// Queued rather than waited for. Nothing the caller does next depends on the bytes
    /// being on disk, and the queue keeps its order — a read that follows sees the write.
    func save(_ article: SavedArticle) {
        queue.async { self.write(article) }
    }

    func save(_ articles: [SavedArticle]) {
        for article in articles { save(article) }
    }

    /// `save`, on the queue.
    private func write(_ article: SavedArticle) {
        let place = self.place(for: article)
        writeRecord(article, in: place.folder)
        syncNote(article, at: place.note, folderName: place.folder.lastPathComponent)
    }

    private func writeRecord(_ article: SavedArticle, in folder: URL) {
        let fm = FileManager.default
        guard let data = try? Self.encoder.encode(article) else { return }
        let url = folder.appendingPathComponent(Self.stateName)
        // Unchanged is not written: every write is a file for iCloud to carry up and a
        // change for every device to be told about.
        if fm.fileExists(atPath: url.path), isReadable(url), (try? Data(contentsOf: url)) == data { return }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func syncNote(_ article: SavedArticle, at note: URL, folderName: String) {
        let fm = FileManager.default
        let signature = NoteFile.signature(of: article)
        if !fm.fileExists(atPath: note.path) {
            guard !hasPlaceholder(for: note) else { return }
            var front = FrontMatter()
            NoteFile.apply(article, to: &front)
            let text = NoteFile.compose(front, body: NoteFile.defaultBody(for: article, folderName: folderName))
            try? text.write(to: note, atomically: true, encoding: .utf8)
            setSignature(signature, for: article.id)
            return
        }
        guard self.signature(article.id) != signature,
              isReadable(note), let text = try? String(contentsOf: note, encoding: .utf8) else { return }
        // A note someone has taken the front matter out of is theirs now.
        let split = FrontMatter.split(text)
        guard var front = split.frontMatter else { return }
        NoteFile.sync(article, into: &front)
        let updated = NoteFile.compose(front, body: split.body)
        if updated != text { try? updated.write(to: note, atomically: true, encoding: .utf8) }
        setSignature(signature, for: article.id)
    }

    /// Writes an article's note in full — every field the app owns, and `body` below
    /// them — keeping whatever else is in the front matter, and the highlights block.
    /// For when there is something new to say: the article has just been fetched, or a
    /// PDF or book has just been stored. With no body, a PDF's note embeds the document
    /// and a book's links its file.
    func writeNote(_ article: SavedArticle, body: String?) async {
        await onQueue {
            let fm = FileManager.default
            let place = self.place(for: article)
            var front = FrontMatter()
            var highlights: Substring?
            if fm.fileExists(atPath: place.note.path) {
                guard self.isReadable(place.note),
                      let text = try? String(contentsOf: place.note, encoding: .utf8) else { return }
                let split = FrontMatter.split(text)
                front = split.frontMatter ?? FrontMatter()
                highlights = NoteFile.highlightsBlock(in: split.body)
            }
            NoteFile.apply(article, to: &front)
            var text = body ?? NoteFile.defaultBody(for: article, folderName: place.folder.lastPathComponent)
            if let highlights { text = NoteFile.replacingHighlights(in: text, with: String(highlights)) }
            try? NoteFile.compose(front, body: text).write(to: place.note, atomically: true, encoding: .utf8)
            self.setSignature(NoteFile.signature(of: article), for: article.id)
        }
    }

    /// Rewrites the highlights block at the end of an article's note.
    func writeHighlights(_ highlights: [Highlight], for article: SavedArticle) {
        queue.async {
            self.editNote(of: article) { _, body in
                body = NoteFile.replacingHighlights(in: body, with: NoteFile.highlightsSection(highlights))
            }
        }
    }

    /// Puts a note's `published:` line right after the date it carries has been repaired.
    func setPublished(for article: SavedArticle) {
        guard let published = article.publishedAt else { return }
        queue.async {
            self.editNote(of: article) { front, _ in
                if front.value("published") != nil { front.set("published", NoteFile.day(published)) }
            }
        }
    }

    /// Reads a note, lets `change` alter it, and writes it back if anything changed. On
    /// the queue.
    private func editNote(of article: SavedArticle, _ change: (inout FrontMatter, inout String) -> Void) {
        let note = place(for: article).note
        guard FileManager.default.fileExists(atPath: note.path), isReadable(note),
              let text = try? String(contentsOf: note, encoding: .utf8) else { return }
        let split = FrontMatter.split(text)
        guard var front = split.frontMatter else { return }
        var body = split.body
        change(&front, &body)
        let updated = NoteFile.compose(front, body: body)
        if updated != text { try? updated.write(to: note, atomically: true, encoding: .utf8) }
    }

    /// Gives an article's note and folder its title's name, when the title has changed
    /// under them — most of all when something saved as a bare address is fetched and
    /// turns out to have a real title. The note's links to its pictures are repointed at
    /// the folder's new name.
    ///
    /// A name the reader gave the note themselves is theirs, but only until the app has a
    /// new title of its own to give it — which happens when an article is fetched, and
    /// not otherwise.
    func rename(_ article: SavedArticle) async {
        await onQueue {
            let fm = FileManager.default
            let current = self.place(for: article)
            let base = NoteFile.fileName(for: article.displayTitle)
            let currentName = current.note.deletingPathExtension().lastPathComponent
            guard !NoteFile.name(currentName, isVariantOf: base) else { return }
            let name = self.foldersLock.withLock { self.uniqueName(base, for: article.id) }

            var folder = current.folder
            let newFolder = self.attachmentsRoot.appendingPathComponent(name, isDirectory: true)
            if !fm.fileExists(atPath: current.folder.path) {
                folder = newFolder
            } else if (try? fm.moveItem(at: current.folder, to: newFolder)) != nil {
                folder = newFolder
                Self.repoint(current.note, from: current.folder.lastPathComponent, to: name)
            }
            var note = current.note
            let newNote = self.noteURL(named: name)
            if !fm.fileExists(atPath: current.note.path) || (try? fm.moveItem(at: current.note, to: newNote)) != nil {
                note = newNote
            }
            self.foldersLock.withLock {
                self.notes[article.id] = note
                self.folders[article.id] = folder
            }
        }
    }

    /// Points a note's links into its attachments folder at the folder's new name.
    private static func repoint(_ note: URL, from old: String, to new: String) {
        guard isDownloaded(note), let text = try? String(contentsOf: note, encoding: .utf8) else { return }
        let updated = text.replacingOccurrences(of: "](" + NoteFile.attachmentsPath(old) + "/",
                                                with: "](" + NoteFile.attachmentsPath(new) + "/")
        if updated != text { try? updated.write(to: note, atomically: true, encoding: .utf8) }
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
        let place = self.place(for: article)
        forget(article.id)
        queue.async {
            try? FileManager.default.removeItem(at: place.folder)
            try? FileManager.default.removeItem(at: place.note)
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

    /// A book's table of contents, or anything else a kind needs beside `state.json`.
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

    /// Moves a library written by the first, single-index layout into folders in the old
    /// layout, which the first scan then turns into notes. Runs once; the old index is
    /// kept, renamed, rather than deleted.
    private func migrateIfNeeded() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyIndexURL.path),
              let data = try? Data(contentsOf: legacyIndexURL) else { return }
        guard let old = try? Self.decoder.decode([SavedArticle].self, from: data) else { return }

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
            if let out = try? Self.encoder.encode(article) {
                try? out.write(to: dir.appendingPathComponent(Self.metadataName), options: .atomic)
            }
        }
        try? fm.moveItem(at: legacyIndexURL, to: root.appendingPathComponent("index.json.migrated"))
        try? fm.removeItem(at: legacyBodiesDir)
        try? fm.removeItem(at: legacyAssetsDir)
    }
}
