import Foundation

/// What an EPUB's own manifest says about itself: metadata, the manifest, the reading
/// order, the cover, and a table of contents.
///
/// Read with `XMLParser` rather than the string surgery `EpubFlattener` uses on chapter
/// content, because these files are spec-guaranteed well-formed and small, and they need
/// to be read exactly — a package is not a place to be forgiving.
struct EpubPackage {
    struct Item {
        var id: String
        var href: String          // as written in the manifest — resolve with opfDirectory
        var mediaType: String
        var properties: Set<String>
    }

    struct SpineRef {
        var idref: String
        var linear: Bool
    }

    var opfPath: String
    /// Every href in the manifest, spine, nav and NCX resolves against this.
    var opfDirectory: String

    var title: String
    var creator: String?
    var publisher: String?
    var bookDescription: String?
    var language: String?
    var date: String?
    /// `dc:identifier` for the package's `unique-identifier` — the dedupe key.
    var identifier: String?

    var manifest: [String: Item] = [:]
    var spine: [SpineRef] = []
    var coverImageID: String?
    var navItemID: String?
    var ncxItemID: String?

    /// A depth-first table of contents, from the EPUB 3 nav document when there is one,
    /// falling back to the EPUB 2 NCX.
    var toc: [BookChapter] = []

    // MARK: - Reading

    static func read(from archive: ZipArchive) throws -> EpubPackage {
        let opfPath = try rootfilePath(in: archive)
        let opfDirectory = ZipArchive.directory(of: opfPath)
        let opfXML = try archive.text(at: opfPath)

        let opf = try OPFDelegate.parse(opfXML)
        guard !opf.manifest.isEmpty, !opf.spine.isEmpty else { throw EpubError.malformed }

        var package = EpubPackage(
            opfPath: opfPath, opfDirectory: opfDirectory,
            title: opf.title.isEmpty ? "Untitled" : opf.title,
            creator: opf.creator, publisher: opf.publisher,
            bookDescription: opf.bookDescription, language: opf.language, date: opf.date,
            identifier: opf.identifier,
            manifest: opf.manifest, spine: opf.spine,
            coverImageID: opf.coverImageID(),
            navItemID: opf.manifest.values.first { $0.properties.contains("nav") }?.id,
            ncxItemID: opf.ncxItemID
        )

        package.toc = Self.readTOC(for: package, archive: archive)
        return package
    }

    // MARK: - container.xml

    private static func rootfilePath(in archive: ZipArchive) throws -> String {
        guard let xml = try? archive.text(at: "META-INF/container.xml") else {
            throw EpubError.notAnEpub
        }
        let delegate = ContainerDelegate()
        let parser = XMLParser(data: Data(XMLSanitizer.strip(xml).utf8))
        parser.delegate = delegate
        guard parser.parse(), let path = delegate.fullPath else { throw EpubError.notAnEpub }
        return path
    }

    private final class ContainerDelegate: NSObject, XMLParserDelegate {
        var fullPath: String?
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                   qualifiedName: String?, attributes: [String: String]) {
            guard localName(name) == "rootfile", fullPath == nil else { return }
            fullPath = attributes["full-path"]
        }
    }

    // MARK: - Table of contents

    private static func readTOC(for package: EpubPackage, archive: ZipArchive) -> [BookChapter] {
        if let navID = package.navItemID, let nav = package.manifest[navID],
           let path = ZipArchive.resolve(nav.href, from: package.opfDirectory),
           let xml = try? archive.text(at: path),
           let entries = NavDelegate.parse(xml, directory: ZipArchive.directory(of: path)),
           !entries.isEmpty {
            return entries
        }
        if let ncxID = package.ncxItemID, let ncx = package.manifest[ncxID],
           let path = ZipArchive.resolve(ncx.href, from: package.opfDirectory),
           let xml = try? archive.text(at: path),
           let entries = NCXDelegate.parse(xml, directory: ZipArchive.directory(of: path)) {
            return entries
        }
        return []
    }
}

struct BookChapter: Codable, Equatable {
    var title: String
    /// Resolved manifest-relative path plus fragment, e.g. `"OEBPS/ch03.xhtml#note1"`.
    var href: String
    var depth: Int
}

enum EpubError: Error, LocalizedError {
    case notAnEpub
    case malformed

    var errorDescription: String? {
        switch self {
        case .notAnEpub: return "This isn't a readable EPUB — its container is missing or damaged."
        case .malformed: return "This EPUB's manifest doesn't describe a book Amber Glow can open."
        }
    }
}

private func localName(_ qualified: String) -> String {
    qualified.split(separator: ":").last.map(String.init) ?? qualified
}

// MARK: - OPF

/// The package document: `<metadata>`, `<manifest>`, `<spine>`.
private final class OPFDelegate: NSObject, XMLParserDelegate {
    var title = ""
    var creator: String?
    var publisher: String?
    var bookDescription: String?
    var language: String?
    var date: String?
    var identifier: String?
    var manifest: [String: EpubPackage.Item] = [:]
    var spine: [EpubPackage.SpineRef] = []
    var ncxItemID: String?

    /// EPUB 2's cover, `<meta name="cover" content="id"/>` — a manifest id, not a property.
    private var epub2CoverID: String?
    private var uniqueIdentifierRef: String?

    private var currentElement = ""
    private var currentText = ""
    private var currentID: String?     // the dc:* element carrying this @id, if any

    static func parse(_ xml: String) throws -> OPFDelegate {
        let delegate = OPFDelegate()
        let parser = XMLParser(data: Data(XMLSanitizer.strip(xml).utf8))
        parser.delegate = delegate
        guard parser.parse() else { throw EpubError.malformed }
        return delegate
    }

    func coverImageID() -> String? {
        if let id = epub2CoverID, manifest[id] != nil { return id }
        return manifest.values.first { $0.properties.contains("cover-image") }?.id
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
               qualifiedName: String?, attributes: [String: String]) {
        currentText = ""
        let local = localName(name)
        currentElement = local

        switch local {
        case "package":
            uniqueIdentifierRef = attributes["unique-identifier"]
        case "item":
            guard let id = attributes["id"], let href = attributes["href"] else { return }
            let props = Set((attributes["properties"] ?? "").split(separator: " ").map(String.init))
            let type = attributes["media-type"] ?? ""
            manifest[id] = EpubPackage.Item(id: id, href: href, mediaType: type, properties: props)
            if type == "application/x-dtbncx+xml" { ncxItemID = id }
        case "itemref":
            guard let idref = attributes["idref"] else { return }
            let linear = attributes["linear"] != "no"
            spine.append(.init(idref: idref, linear: linear))
        case "meta":
            if attributes["name"] == "cover" { epub2CoverID = attributes["content"] }
        case "identifier":
            currentID = attributes["id"]
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
               qualifiedName: String?) {
        let local = localName(name)
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch local {
        case "title": if title.isEmpty { title = text }
        case "creator": if creator == nil { creator = text }
        case "publisher": if publisher == nil { publisher = text }
        case "description": if bookDescription == nil { bookDescription = text }
        case "language": if language == nil { language = text }
        case "date": if date == nil { date = text }
        case "identifier":
            if identifier == nil || (currentID != nil && currentID == uniqueIdentifierRef) {
                identifier = text
            }
            currentID = nil
        default:
            break
        }
        currentText = ""
    }
}

// MARK: - EPUB 3 nav document

/// `<nav epub:type="toc">` — an ordinary nested `<ol>` of `<a href>`s.
private final class NavDelegate: NSObject, XMLParserDelegate {
    private var entries: [BookChapter] = []
    private var inTOC = false
    private var depth = 0
    private var pendingHref: String?
    private var text = ""
    private let directory: String

    private init(directory: String) { self.directory = directory }

    static func parse(_ xml: String, directory: String) -> [BookChapter]? {
        let clean = XMLSanitizer.strip(xml)
        let delegate = NavDelegate(directory: directory)
        let parser = XMLParser(data: Data(clean.utf8))
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.entries
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
               qualifiedName: String?, attributes: [String: String]) {
        let local = localName(name)
        switch local {
        case "nav":
            let type = attributes["epub:type"] ?? attributes["type"] ?? ""
            if type.split(separator: " ").contains("toc") { inTOC = true }
        case "ol":
            if inTOC { depth += 1 }
        case "a" where inTOC:
            pendingHref = attributes["href"]
            text = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if pendingHref != nil { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
               qualifiedName: String?) {
        let local = localName(name)
        switch local {
        case "nav":
            inTOC = false
        case "ol":
            if inTOC { depth = max(0, depth - 1) }
        case "a" where inTOC:
            if let href = pendingHref, let resolved = ZipArchive.resolve(href, from: directory) {
                let fragment = href.components(separatedBy: "#").dropFirst().first
                let full = fragment.map { "\(resolved)#\($0)" } ?? resolved
                let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    entries.append(BookChapter(title: title, href: full, depth: max(0, depth - 1)))
                }
            }
            pendingHref = nil
        default:
            break
        }
    }
}

// MARK: - EPUB 2 NCX

/// `navMap/navPoint/navLabel/text` + `content/@src`, nested `navPoint`s giving depth.
private final class NCXDelegate: NSObject, XMLParserDelegate {
    private var entries: [BookChapter] = []
    private var depth = -1
    private var pendingSrc: String?
    private var inLabel = false
    private var text = ""
    private let directory: String

    private init(directory: String) { self.directory = directory }

    static func parse(_ xml: String, directory: String) -> [BookChapter]? {
        let clean = XMLSanitizer.strip(xml)
        let delegate = NCXDelegate(directory: directory)
        let parser = XMLParser(data: Data(clean.utf8))
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.entries
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
               qualifiedName: String?, attributes: [String: String]) {
        switch localName(name) {
        case "navPoint": depth += 1
        case "navLabel": inLabel = true; text = ""
        case "content": pendingSrc = attributes["src"]
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inLabel { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
               qualifiedName: String?) {
        switch localName(name) {
        case "navPoint":
            if let src = pendingSrc, let resolved = ZipArchive.resolve(src, from: directory) {
                let fragment = src.components(separatedBy: "#").dropFirst().first
                let full = fragment.map { "\(resolved)#\($0)" } ?? resolved
                let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    entries.append(BookChapter(title: title, href: full, depth: max(0, depth)))
                }
            }
            pendingSrc = nil
            depth -= 1
        case "navLabel": inLabel = false
        default: break
        }
    }
}

/// `XMLParser` aborts outright on a DOCTYPE referencing an external DTD, or on the
/// handful of named entities (`&nbsp;`, `&mdash;`, …) that DTD would have defined. Nav and
/// NCX documents carry both routinely. Stripping the DOCTYPE and substituting the common
/// entities turns a hard failure into a document `XMLParser` can actually read.
enum XMLSanitizer {
    private static let entities: [(String, String)] = [
        ("&nbsp;", "&#160;"), ("&mdash;", "&#8212;"), ("&ndash;", "&#8211;"),
        ("&hellip;", "&#8230;"), ("&ldquo;", "&#8220;"), ("&rdquo;", "&#8221;"),
        ("&lsquo;", "&#8216;"), ("&rsquo;", "&#8217;"), ("&copy;", "&#169;"),
    ]

    static func strip(_ xml: String) -> String {
        var out = xml
        if let doctypeStart = out.range(of: "<!DOCTYPE", options: .caseInsensitive) {
            if let close = out.range(of: ">", range: doctypeStart.upperBound..<out.endIndex) {
                out.removeSubrange(doctypeStart.lowerBound..<close.upperBound)
            }
        }
        for (named, numeric) in entities {
            out = out.replacingOccurrences(of: named, with: numeric)
        }
        return out
    }
}
