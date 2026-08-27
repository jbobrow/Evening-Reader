import Foundation

/// Whether a book can actually be read, checked before anything is written to disk.
///
/// A library loan and a locked purchase both look, at the zip level, exactly like a book —
/// the difference only shows up in `META-INF`. Catching it here means the person sees one
/// honest sentence at the moment they share the file, instead of a permanently broken row
/// or a parse error that means nothing to them.
enum EpubGuard {
    enum Problem {
        /// Adobe ADEPT, Readium LCP, or Apple FairPlay — a real lock this app cannot open.
        case locked
        /// An `.acsm` fulfillment file: a receipt, not a book.
        case fulfillmentFile
        /// A valid zip, but not an EPUB — no container, or no package it points to.
        case notAnEpub

        var title: String {
            switch self {
            case .locked: return "This book is locked by its publisher."
            case .fulfillmentFile: return "That's a loan ticket, not a book."
            case .notAnEpub: return "That doesn't look like a book."
            }
        }

        var detail: String {
            switch self {
            case .locked:
                return "Library loans and most store purchases carry Adobe or LCP "
                    + "protection, which only their own app can open — Libby keeps its "
                    + "loans inside Libby. Amber Glow reads books that aren't locked: "
                    + "Standard Ebooks, Project Gutenberg, and DRM-free purchases from the "
                    + "stores that offer them."
            case .fulfillmentFile:
                return "An .acsm file is a note telling Adobe's software which book to "
                    + "fetch and lock to your account. There is no book inside it to read."
            case .notAnEpub:
                return "This file isn't something Amber Glow knows how to open as a book."
            }
        }
    }

    /// Checked before the zip is even opened: an `.acsm` is XML, not a zip, so the zip
    /// reader would only ever report it as damaged.
    static func fulfillmentProblem(data: Data) -> Problem? {
        let head = data.prefix(2048)
        guard let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1)
        else { return nil }
        let lower = text.lowercased()
        guard lower.contains("<fulfillmenttoken") || lower.contains("ns.adobe.com/adept") else {
            return nil
        }
        return .fulfillmentFile
    }

    /// Checked once the zip is open. `nil` means the book is readable.
    static func drmProblem(in archive: ZipArchive) -> Problem? {
        if archive.contains("META-INF/rights.xml") { return .locked }              // Adobe ADEPT
        if archive.contains("META-INF/license.lcpl") { return .locked }            // Readium LCP
        if archive.contains("META-INF/sinf.xml") { return .locked }                // Apple FairPlay

        if archive.contains("META-INF/encryption.xml") {
            // Presence alone is not a verdict: the same file also carries legitimate
            // IDPF/Adobe *font* obfuscation, which locks nothing a reader cares about.
            // What matters is what is actually encrypted.
            guard let xml = try? archive.text(at: "META-INF/encryption.xml") else { return .locked }
            switch EncryptionManifest.classify(xml) {
            case .fontObfuscationOnly: break   // proceed — the fonts are discarded anyway
            case .encryptsContent, .unknown: return .locked
            }
        }

        return nil
    }
}

/// Opens a book file and stops at the first sign it can't actually be read, so both the
/// share extension (deciding whether to say "Saved") and the app (about to flatten it)
/// run exactly the same checks in exactly the same order.
enum EpubInspector {
    enum Failure: Error, LocalizedError {
        case problem(EpubGuard.Problem)

        var problem: EpubGuard.Problem {
            switch self { case .problem(let p): return p }
        }
        var errorDescription: String? { problem.title }
    }

    static func open(data: Data) throws -> (archive: ZipArchive, package: EpubPackage) {
        if let problem = EpubGuard.fulfillmentProblem(data: data) { throw Failure.problem(problem) }

        let archive: ZipArchive
        do {
            archive = try ZipArchive(data: data)
        } catch {
            throw Failure.problem(.notAnEpub)
        }

        if let problem = EpubGuard.drmProblem(in: archive) { throw Failure.problem(problem) }

        do {
            let package = try EpubPackage.read(from: archive)
            return (archive, package)
        } catch {
            throw Failure.problem(.notAnEpub)
        }
    }
}

/// A minimal read of `META-INF/encryption.xml`: not the full XML-Enc schema, just enough
/// to tell font obfuscation apart from an actually locked spine document.
private enum EncryptionManifest {
    enum Verdict { case fontObfuscationOnly, encryptsContent, unknown }

    private static let obfuscationAlgorithms: Set<String> = [
        "http://www.idpf.org/2008/embedding",
        "http://ns.adobe.com/pdf/enc#RC",
    ]
    private static let fontExtensions: Set<String> = ["ttf", "otf", "woff", "woff2"]

    static func classify(_ xml: String) -> Verdict {
        let parser = XMLParser(data: Data(xml.utf8))
        let delegate = Delegate()
        parser.delegate = delegate
        guard parser.parse(), !delegate.entries.isEmpty else { return .unknown }

        var sawObfuscation = false
        for entry in delegate.entries {
            let ext = (entry.uri as NSString).pathExtension.lowercased()
            if let algorithm = entry.algorithm, obfuscationAlgorithms.contains(algorithm),
               fontExtensions.contains(ext) {
                sawObfuscation = true
                continue
            }
            return .encryptsContent
        }
        return sawObfuscation ? .fontObfuscationOnly : .unknown
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        struct Entry { var uri: String = ""; var algorithm: String? }
        var entries: [Entry] = []
        private var current: Entry?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                   qualifiedName: String?, attributes: [String: String]) {
            let local = name.split(separator: ":").last.map(String.init) ?? name
            switch local {
            case "EncryptedData":
                current = Entry()
            case "EncryptionMethod":
                current?.algorithm = attributes["Algorithm"]
            case "CipherReference":
                if let uri = attributes["URI"] { current?.uri = uri }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                   qualifiedName: String?) {
            let local = name.split(separator: ":").last.map(String.init) ?? name
            if local == "EncryptedData", let entry = current {
                entries.append(entry)
                current = nil
            }
        }
    }
}
