import Foundation
import Compression

/// A zip file, read without taking a dependency to do it.
///
/// This is a narrow reader for a narrow job. EPUB's container format admits exactly two
/// storage methods — stored and deflate — and every entry's uncompressed size is recorded
/// in the central directory before the bytes are touched. That second fact is what keeps
/// this small: the output buffer can be sized exactly, so there is no streaming decoder to
/// write, only a directory walk and one `compression_decode_buffer` call per entry.
///
/// The file is memory-mapped rather than read. A thirty-megabyte illustrated book is a
/// perfectly ordinary thing to be handed, and it has no business being resident.
struct ZipArchive {

    struct Entry {
        let path: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let crc32: UInt32
        let localHeaderOffset: Int
    }

    private(set) var entries: [Entry] = []

    private let bytes: Data
    private let index: [String: Int]
    /// Lowercased names, for the second attempt. Zip is case-sensitive and some writers
    /// are not, so a manifest href that differs only in case still finds its file.
    private let foldedIndex: [String: Int]

    // MARK: - Reading

    init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    init(data: Data) throws {
        guard data.count >= 22 else { throw ZipError.notAZip }
        bytes = data

        let eocd = try Self.findEndOfCentralDirectory(in: data)
        let (count, directoryOffset) = try Self.centralDirectory(at: eocd, in: data)

        var found: [Entry] = []
        var byPath: [String: Int] = [:]
        var byFolded: [String: Int] = [:]
        found.reserveCapacity(count)

        var cursor = directoryOffset
        for _ in 0..<count {
            guard try Self.u32(data, cursor) == Self.centralSignature else { throw ZipError.corrupt }

            let flags = try Self.u16(data, cursor + 8)
            let method = try Self.u16(data, cursor + 10)
            let crc = try Self.u32(data, cursor + 16)
            var compressed = Int(try Self.u32(data, cursor + 20))
            var uncompressed = Int(try Self.u32(data, cursor + 24))
            let nameLength = Int(try Self.u16(data, cursor + 28))
            let extraLength = Int(try Self.u16(data, cursor + 30))
            let commentLength = Int(try Self.u16(data, cursor + 32))
            var localOffset = Int(try Self.u32(data, cursor + 42))

            let nameStart = cursor + 46
            let extraStart = nameStart + nameLength
            guard extraStart + extraLength + commentLength <= data.count else {
                throw ZipError.truncated
            }

            // A field held at its maximum is a field that did not fit; the real value is in
            // the zip64 extra block. No EPUB is ever this large, but reading 0xFFFFFFFF as a
            // literal offset walks off into the middle of the file and reports damage that
            // is not there.
            if uncompressed == 0xFFFF_FFFF || compressed == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                let wide = try Self.zip64Extra(data, at: extraStart, length: extraLength,
                                               uncompressed: uncompressed,
                                               compressed: compressed,
                                               localOffset: localOffset)
                uncompressed = wide.uncompressed
                compressed = wide.compressed
                localOffset = wide.localOffset
            }

            cursor = extraStart + extraLength + commentLength

            let raw = data.subdata(in: (data.startIndex + nameStart)..<(data.startIndex + extraStart))
            // Flag bit 11 declares UTF-8, which EPUB mandates. A writer that lies, or that
            // sets nothing at all, still yields a usable name through Latin-1 rather than
            // dropping the entry on the floor.
            _ = flags
            guard let name = String(data: raw, encoding: .utf8)
                    ?? String(data: raw, encoding: .isoLatin1),
                  let path = Self.normalize(name) else { continue }

            let entry = Entry(path: path, method: method,
                              compressedSize: compressed, uncompressedSize: uncompressed,
                              crc32: crc, localHeaderOffset: localOffset)
            byPath[path] = found.count
            byFolded[path.lowercased()] = found.count
            found.append(entry)
        }

        entries = found
        index = byPath
        foldedIndex = byFolded
    }

    // MARK: - Lookup

    func entry(at path: String) -> Entry? {
        guard let clean = Self.normalize(path) else { return nil }
        if let i = index[clean] { return entries[i] }
        if let i = foldedIndex[clean.lowercased()] { return entries[i] }
        return nil
    }

    func contains(_ path: String) -> Bool { entry(at: path) != nil }

    func data(at path: String) throws -> Data {
        guard let entry = entry(at: path) else { throw ZipError.notFound(path) }
        return try data(for: entry)
    }

    /// An entry's text. EPUB is UTF-8 throughout; Latin-1 is the fallback that turns a
    /// mis-declared file into a slightly wrong chapter instead of a missing one.
    func text(at path: String) throws -> String {
        let raw = try data(at: path)
        let stripped = raw.starts(with: [0xEF, 0xBB, 0xBF]) ? raw.dropFirst(3) : raw[...]
        guard let text = String(data: stripped, encoding: .utf8)
                ?? String(data: stripped, encoding: .isoLatin1) else { throw ZipError.corrupt }
        return text
    }

    func data(for entry: Entry) throws -> Data {
        guard entry.uncompressedSize <= Self.maxEntrySize else { throw ZipError.tooLarge }

        // The bytes do not sit a fixed distance from the local header. The name and extra
        // lengths recorded *there* are the ones that place them, and they legitimately
        // differ from the central directory's copy of the same entry — the central record
        // often carries extra fields the local one does not.
        let header = entry.localHeaderOffset
        guard try Self.u32(bytes, header) == Self.localSignature else { throw ZipError.corrupt }
        let nameLength = Int(try Self.u16(bytes, header + 26))
        let extraLength = Int(try Self.u16(bytes, header + 28))

        let start = header + 30 + nameLength + extraLength
        guard start >= 0, start + entry.compressedSize <= bytes.count else { throw ZipError.truncated }
        let raw = bytes.subdata(in: (bytes.startIndex + start)..<(bytes.startIndex + start + entry.compressedSize))

        let out: Data
        switch entry.method {
        case Self.stored:
            guard raw.count == entry.uncompressedSize else { throw ZipError.corrupt }
            out = raw
        case Self.deflated:
            // An empty member deflates to nothing, and `compression_decode_buffer` reports
            // "nothing came out" and "it failed" with the same zero. Settling the empty
            // case here means the return value is unambiguous everywhere else.
            out = entry.uncompressedSize == 0 ? Data()
                                              : try Self.inflate(raw, to: entry.uncompressedSize)
        default:
            throw ZipError.unsupportedMethod(entry.method)
        }

        // Worth the pass: the one bug this reader is most likely to have is slicing at the
        // wrong offset, and a checksum turns that from plausible-looking rubbish into an
        // error at the point it happens.
        if entry.uncompressedSize > 0, Self.crc32(out) != entry.crc32 { throw ZipError.corrupt }
        return out
    }

    // MARK: - Layout

    private static let stored: UInt16 = 0
    private static let deflated: UInt16 = 8

    private static let localSignature: UInt32 = 0x0403_4b50
    private static let centralSignature: UInt32 = 0x0201_4b50
    private static let eocdSignature: UInt32 = 0x0605_4b50
    private static let zip64LocatorSignature: UInt32 = 0x0706_4b50
    private static let zip64EOCDSignature: UInt32 = 0x0606_4b50

    /// The size in a header is whatever the file claims. A buffer is allocated from it
    /// before a single byte has been verified, so it needs a ceiling.
    private static let maxEntrySize = 64 * 1024 * 1024

    /// The end-of-central-directory record is last, except that a comment of up to 64 KB
    /// may follow it — so it is found by scanning backwards.
    private static func findEndOfCentralDirectory(in data: Data) throws -> Int {
        let span = min(data.count, 22 + 65_535)
        let floor = data.count - span
        var offset = data.count - 22
        while offset >= floor {
            if (try? u32(data, offset)) == eocdSignature,
               let commentLength = try? u16(data, offset + 20),
               // Those four bytes will also occur by chance inside compressed data in any
               // large archive. What distinguishes the real record is that its comment
               // length accounts for exactly the rest of the file.
               offset + 22 + Int(commentLength) == data.count {
                return offset
            }
            offset -= 1
        }
        throw ZipError.notAZip
    }

    private static func centralDirectory(at eocd: Int, in data: Data) throws -> (count: Int, offset: Int) {
        var count = Int(try u16(data, eocd + 10))
        let size = Int(try u32(data, eocd + 12))
        var offset = Int(try u32(data, eocd + 16))

        guard count == 0xFFFF || size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF else {
            guard offset >= 0, offset < data.count else { throw ZipError.corrupt }
            return (count, offset)
        }

        let locator = eocd - 20
        guard locator >= 0, try u32(data, locator) == zip64LocatorSignature else {
            throw ZipError.corrupt
        }
        let record = Int(try u64(data, locator + 8))
        guard record >= 0, try u32(data, record) == zip64EOCDSignature else {
            throw ZipError.corrupt
        }
        count = Int(try u64(data, record + 32))
        offset = Int(try u64(data, record + 48))
        guard offset >= 0, offset < data.count else { throw ZipError.corrupt }
        return (count, offset)
    }

    /// Reads the wide values out of extra-field block 0x0001.
    ///
    /// Only the fields that were held at their maximum are present, and they appear in a
    /// fixed order, so the block is read positionally rather than by name.
    private static func zip64Extra(_ data: Data, at start: Int, length: Int,
                                   uncompressed: Int, compressed: Int,
                                   localOffset: Int) throws -> (uncompressed: Int, compressed: Int, localOffset: Int) {
        var result = (uncompressed: uncompressed, compressed: compressed, localOffset: localOffset)
        var cursor = start
        let end = start + length
        while cursor + 4 <= end {
            let id = try u16(data, cursor)
            let size = Int(try u16(data, cursor + 2))
            guard cursor + 4 + size <= end else { break }
            if id == 0x0001 {
                var field = cursor + 4
                if result.uncompressed == 0xFFFF_FFFF, field + 8 <= end {
                    result.uncompressed = Int(try u64(data, field)); field += 8
                }
                if result.compressed == 0xFFFF_FFFF, field + 8 <= end {
                    result.compressed = Int(try u64(data, field)); field += 8
                }
                if result.localOffset == 0xFFFF_FFFF, field + 8 <= end {
                    result.localOffset = Int(try u64(data, field))
                }
                return result
            }
            cursor += 4 + size
        }
        throw ZipError.corrupt
    }

    // MARK: - Paths

    /// Cleans a stored name, and refuses one that climbs.
    ///
    /// Nothing here writes an entry out under its own name — a book's pictures are stored
    /// by digest — but href resolution walks this same table, so a name that escapes the
    /// archive is refused at the door rather than trusted to be harmless downstream.
    static func normalize(_ path: String) -> String? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return nil }
        var parts: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { return nil }
            parts.append(String(part))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    /// Resolves an href against the directory of the document that contains it.
    ///
    /// EPUB hrefs are relative and routinely climb (`../images/plate.png` from
    /// `OEBPS/text/ch01.xhtml`), so `..` is resolved here — where it means what it says —
    /// rather than in `normalize`, where a stored name containing one is a red flag.
    static func resolve(_ href: String, from directory: String) -> String? {
        let target = href.components(separatedBy: "#")[0]
            .removingPercentEncoding ?? href.components(separatedBy: "#")[0]
        guard !target.isEmpty else { return nil }
        if target.hasPrefix("/") { return normalize(String(target.dropFirst())) }

        var parts = directory.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        for part in target.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { if parts.isEmpty { return nil }; parts.removeLast(); continue }
            parts.append(String(part))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    /// The directory part of an entry path, `""` at the root.
    static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[path.startIndex..<slash])
    }

    // MARK: - Bytes

    private static func inflate(_ source: Data, to size: Int) throws -> Data {
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { destination -> Int in
            guard let target = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return source.withUnsafeBytes { input -> Int in
                guard let origin = input.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                // COMPRESSION_ZLIB is raw deflate per RFC 1951 — which is exactly what a
                // zip member holds, headerless.
                return compression_decode_buffer(target, size, origin, source.count,
                                                 nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw ZipError.corrupt }
        return out
    }

    private static func u16(_ data: Data, _ offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { throw ZipError.truncated }
        let base = data.startIndex + offset
        return UInt16(data[base]) | UInt16(data[base + 1]) << 8
    }

    private static func u32(_ data: Data, _ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { throw ZipError.truncated }
        let base = data.startIndex + offset
        return UInt32(data[base])
            | UInt32(data[base + 1]) << 8
            | UInt32(data[base + 2]) << 16
            | UInt32(data[base + 3]) << 24
    }

    private static func u64(_ data: Data, _ offset: Int) throws -> UInt64 {
        guard offset >= 0, offset + 8 <= data.count else { throw ZipError.truncated }
        let low = UInt64(try u32(data, offset))
        let high = UInt64(try u32(data, offset + 4))
        return low | high << 32
    }

    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            return c
        }
    }()

    private static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { raw in
            for byte in raw.bindMemory(to: UInt8.self) {
                c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
            }
        }
        return c ^ 0xFFFF_FFFF
    }
}

enum ZipError: Error, LocalizedError {
    case notAZip
    case truncated
    case corrupt
    case unsupportedMethod(UInt16)
    case tooLarge
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .notAZip: return "This isn't a zip archive."
        case .truncated: return "The file ends before it should."
        case .corrupt: return "The file is damaged."
        case .unsupportedMethod(let method): return "The file uses compression method \(method), which this reader doesn't handle."
        case .tooLarge: return "Something inside the file is too large to read."
        case .notFound(let path): return "\(path) isn't in the file."
        }
    }
}
