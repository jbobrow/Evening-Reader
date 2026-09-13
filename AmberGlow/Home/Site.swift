import Foundation
import UIKit
import Observation

/// A place the reader goes to on purpose: a library, a bookshop, a feed. Not reading
/// that was saved, but a door that stays open.
struct Site: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var url: URL
    /// An SF Symbol the reader chose for it, or nil for the site's own icon.
    var symbol: String?
    var addedAt: Date = .now

    var host: String {
        guard var h = url.host else { return "" }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    /// What stands in when there is neither a symbol nor an icon: the first letter.
    var monogram: String {
        let source = name.isEmpty ? host : name
        return String(source.prefix(1)).uppercased()
    }
}

/// The sites, kept beside the library as one folder per site:
///
///     Sites/
///         libby--a1b2c3d4/
///             site.json
///             icon.png       the site's own icon, when it could be fetched
///
/// The same shape as an article's folder and for the same reason: two devices adding
/// different sites never write the same file, and the folder syncs through iCloud with
/// nothing to resolve.
@MainActor
@Observable
final class Sites {
    private(set) var sites: [Site] = []

    @ObservationIgnored private let store: ArticleStore
    @ObservationIgnored private var folders: [UUID: URL] = [:]
    @ObservationIgnored private var icons: [UUID: UIImage] = [:]
    @ObservationIgnored private var observer: NSObjectProtocol?

    private static let metadataName = "site.json"
    private static let iconName = "icon.png"

    init(store: ArticleStore = .shared) {
        self.store = store
        observer = NotificationCenter.default.addObserver(
            forName: CloudLibrary.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshFromDisk() }
        }
    }

    /// Read the folders again, without waiting.
    func refreshFromDisk() {
        Task { await reload() }
    }

    /// Reads the folders off this thread and replaces the list when they are in. The
    /// sites live beside the library, in iCloud with it, and a folder there can be a
    /// placeholder; see `ArticleStore.isReadable`.
    func reload() async {
        let root = store.sitesRoot
        let store = self.store
        let (found, map) = await Task.detached(priority: .userInitiated) {
            Self.scan(root: root, store: store)
        }.value
        sites = found
        folders = map
        icons.removeAll()
    }

    private nonisolated static func scan(root: URL, store: ArticleStore) -> ([Site], [UUID: URL]) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root,
                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles])
        else { return ([], [:]) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var found: [Site] = []
        var map: [UUID: URL] = [:]
        for dir in entries {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            let meta = dir.appendingPathComponent(Self.metadataName)
            guard store.isReadable(meta),
                  let data = try? Data(contentsOf: meta),
                  let site = try? decoder.decode(Site.self, from: data) else { continue }
            map[site.id] = dir
            found.append(site)
        }
        // In the order they were added, like anything laid out by hand.
        return (found.sorted { $0.addedAt < $1.addedAt }, map)
    }

    func site(forHost host: String) -> Site? {
        sites.first { $0.host == host }
    }

    /// The site's own icon, if one was fetched when it was added.
    func icon(for site: Site) -> UIImage? {
        if let cached = icons[site.id] { return cached }
        guard let dir = folders[site.id] else { return nil }
        let file = dir.appendingPathComponent(Self.iconName)
        guard store.isReadable(file),
              let data = try? Data(contentsOf: file),
              let image = UIImage(data: data) else { return nil }
        icons[site.id] = image
        return image
    }

    /// Writes a site, new or changed, and its icon when there is one to write. An icon
    /// already on disk is kept when none is passed: choosing a symbol does not throw the
    /// site's own icon away, and choosing it back is then free.
    func save(_ site: Site, icon: UIImage?) {
        let fm = FileManager.default
        let desired = store.sitesRoot.appendingPathComponent(Self.folderName(for: site), isDirectory: true)
        if let current = folders[site.id], current != desired,
           fm.fileExists(atPath: current.path), !fm.fileExists(atPath: desired.path) {
            try? fm.moveItem(at: current, to: desired)
        }
        folders[site.id] = desired
        try? fm.createDirectory(at: desired, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(site) {
            try? data.write(to: desired.appendingPathComponent(Self.metadataName), options: .atomic)
        }
        if let icon, let data = Self.normalized(icon) {
            try? data.write(to: desired.appendingPathComponent(Self.iconName), options: .atomic)
            icons[site.id] = icon
        }

        if let i = sites.firstIndex(where: { $0.id == site.id }) {
            sites[i] = site
        } else {
            sites.append(site)
        }
    }

    func remove(_ site: Site) {
        if let dir = folders[site.id] { try? FileManager.default.removeItem(at: dir) }
        folders[site.id] = nil
        icons[site.id] = nil
        sites.removeAll { $0.id == site.id }
    }

    private static func folderName(for site: Site) -> String {
        let short = site.id.uuidString.prefix(8).lowercased()
        let base = ArticleStore.slug(site.name.isEmpty ? site.host : site.name)
        return base.isEmpty ? String(short) : "\(base)--\(short)"
    }

    /// Stored small and as PNG whatever it arrived as, so an `.ico` is decoded once,
    /// here, rather than every time a tile is drawn.
    private static func normalized(_ image: UIImage) -> Data? {
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, 128 / longest)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format)
            .image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            .pngData()
    }

    // MARK: - Fetching an icon

    /// The best icon a site will admit to: what its page declares, largest first, and
    /// failing that the places an icon is kept by convention.
    nonisolated static func fetchIcon(for url: URL) async -> UIImage? {
        guard let host = url.host, let root = URL(string: "https://\(host)") else { return nil }
        var candidates: [URL] = []
        if let html = await fetchHTML(url) {
            candidates += declaredIcons(in: html, base: url)
        }
        candidates += [
            root.appendingPathComponent("apple-touch-icon.png"),
            root.appendingPathComponent("apple-touch-icon-precomposed.png"),
            root.appendingPathComponent("favicon.ico"),
        ]
        var seen: Set<URL> = []
        for candidate in candidates where seen.insert(candidate).inserted {
            if let image = await download(candidate) { return image }
        }
        return nil
    }

    private nonisolated static func fetchHTML(_ url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(ArticleExtractor.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
        else { return nil }
        // Only the head is wanted, and a page can be enormous.
        return String(decoding: data.prefix(300_000), as: UTF8.self)
    }

    private nonisolated static func download(_ url: URL) async -> UIImage? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(ArticleExtractor.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              !data.isEmpty, let image = UIImage(data: data),
              image.size.width >= 16 else { return nil }
        return image
    }

    /// Every `<link rel="…icon…">` in the page, best first: touch icons before favicons,
    /// larger before smaller. SVG is left out, since it cannot be drawn as an image here.
    private nonisolated static func declaredIcons(in html: String, base: URL) -> [URL] {
        guard let tag = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive]),
              let rel = try? NSRegularExpression(pattern: "\\brel\\s*=\\s*[\"']([^\"']*)[\"']", options: [.caseInsensitive]),
              let href = try? NSRegularExpression(pattern: "\\bhref\\s*=\\s*[\"']([^\"']*)[\"']", options: [.caseInsensitive]),
              let sizes = try? NSRegularExpression(pattern: "\\bsizes\\s*=\\s*[\"']([^\"']*)[\"']", options: [.caseInsensitive])
        else { return [] }
        let whole = NSRange(html.startIndex..., in: html)
        var ranked: [(score: Int, url: URL)] = []
        for match in tag.matches(in: html, range: whole) {
            guard let range = Range(match.range, in: html) else { continue }
            let link = String(html[range])
            func capture(_ regex: NSRegularExpression) -> String? {
                guard let m = regex.firstMatch(in: link, range: NSRange(link.startIndex..., in: link)),
                      let r = Range(m.range(at: 1), in: link) else { return nil }
                return String(link[r])
            }
            guard let relation = capture(rel)?.lowercased(), relation.contains("icon"),
                  let path = capture(href), !path.isEmpty,
                  !path.lowercased().hasSuffix(".svg"),
                  let url = URL(string: path, relativeTo: base)?.absoluteURL,
                  url.scheme == "http" || url.scheme == "https" else { continue }
            var score = relation.contains("apple-touch") ? 1000 : 0
            if let declared = capture(sizes),
               let side = declared.split(separator: "x").first.flatMap({ Int($0) }) {
                score += side
            }
            ranked.append((score, url))
        }
        return ranked.sorted { $0.score > $1.score }.map(\.url)
    }
}
