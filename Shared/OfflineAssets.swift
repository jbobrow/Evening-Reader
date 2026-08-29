import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Pulls an article's pictures onto the device so a saved page reads the same on a plane
/// as it does on wifi.
///
/// The extracted HTML points at wherever the images live on the web, which is fine until
/// there is no web. Each one is fetched once, at save time, written next to the article,
/// and the tag rewritten to point at the copy. What the reader loads afterwards touches
/// the network for nothing.
///
/// The download is also the right moment to decide whether a picture is a drawing or a
/// photograph — the reader needs to know, at night, whether inverting it will help or
/// ruin it. Deciding here rather than in the page means the answer is computed once
/// instead of on every open, from the real bytes rather than through a canvas.
enum OfflineAssets {
    /// Custom scheme so the stored copies can be served straight from disk.
    static let scheme = "amber-asset"

    /// Kept deliberately modest: this runs while someone waits to read.
    private static let maxImages = 60
    private static let maxBytesPerImage = 6 * 1024 * 1024
    private static let maxBytesTotal = 24 * 1024 * 1024

    // MARK: - Rewriting

    /// A page's markup with its pictures pointed at the copies on disk, and the record
    /// of which remote URL became which file. The record is what lets the Markdown
    /// sidecar point at the same copies without fetching anything a second time.
    struct Localized {
        var html: String
        /// Absolute remote URL -> asset file name, for everything actually stored.
        var assets: [String: String] = [:]
    }

    static func localize(html: String, article: SavedArticle, store: ArticleStore) async -> Localized {
        var out = ""
        var rest = Substring(html)
        var budget = maxBytesTotal
        var saved = 0
        var stored: [String: String] = [:]

        while let start = rest.range(of: "<img", options: .caseInsensitive) {
            guard let tagEnd = endOfTag(in: rest, from: start.upperBound) else { break }
            out += rest[rest.startIndex..<start.lowerBound]
            let tag = String(rest[start.lowerBound..<tagEnd])
            rest = rest[tagEnd...]

            guard saved < maxImages,
                  let src = value(of: "src", in: tag),
                  let remote = URL(string: src, relativeTo: article.url)?.absoluteURL,
                  remote.scheme == "http" || remote.scheme == "https" else {
                out += tag
                continue
            }

            guard let fetched = await fetch(remote), fetched.count <= budget else {
                out += tag
                continue
            }
            budget -= fetched.count
            guard let name = store.writeAsset(fetched, ext: extensionFor(remote, data: fetched),
                                              for: article) else {
                out += tag
                continue
            }
            saved += 1
            stored[remote.absoluteString] = name

            var rewritten = replace("src", with: "\(scheme)://\(article.id.uuidString)/\(name)", in: tag)
            // Responsive variants would send the reader back to the network for a
            // different copy of a picture already on disk.
            rewritten = removeAttribute("srcset", from: rewritten)
            rewritten = removeAttribute("sizes", from: rewritten)
            if let kind = classify(fetched) {
                rewritten = addClass(kind, to: rewritten)
            }
            out += rewritten
        }
        out += rest
        return Localized(html: out, assets: stored)
    }

    private static func fetch(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(ArticleExtractorUserAgent.value, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              data.count <= maxBytesPerImage, !data.isEmpty else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return nil
        }
        return data
    }

    // MARK: - Drawing or photograph

    /// Returns `ag-line` for artwork that may be inverted at night, `ag-photo` otherwise.
    ///
    /// Mid-tone density is the signal. Counting distinct tones does not work: a line
    /// engraving saved as JPEG carries ringing artifacts across the whole histogram and
    /// measures much like a photograph. Ink on paper is mostly ink or mostly paper; a
    /// photograph lives in the greys.
    static func classify(_ data: Data) -> String? {
        #if canImport(UIKit)
        guard let cg = UIImage(data: data)?.cgImage else { return nil }
        let w = max(1, min(96, cg.width))
        let h = max(1, min(96, cg.height))
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buffer, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // No interpolation: averaging a dithered engraving down blends its blacks and
        // whites into greys, and it then measures exactly like a photograph.
        ctx.interpolationQuality = .none
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var seen = [Bool](repeating: false, count: 256)
        var distinct = 0, mid = 0, total = 0
        for i in stride(from: 0, to: buffer.count, by: 4) {
            if buffer[i + 3] < 8 { continue }
            let r = Double(buffer[i])
            let g = Double(buffer[i + 1])
            let b = Double(buffer[i + 2])
            let l = Int(0.2126 * r + 0.7152 * g + 0.0722 * b)
            if !seen[l] { seen[l] = true; distinct += 1 }
            if l >= 64 && l < 192 { mid += 1 }
            total += 1
        }
        guard total > 0 else { return nil }
        return (Double(mid) / Double(total) < 0.30 || distinct <= 16) ? "ag-line" : "ag-photo"
        #else
        return nil
        #endif
    }

    // MARK: - Tag surgery
    //
    // Shared with EpubFlattener, which does the same shape of work on a book's markup —
    // hence `internal` rather than `private` on the primitives below.

    /// Finds the `>` that closes a tag, ignoring any inside quoted attribute values.
    static func endOfTag(in text: Substring, from index: String.Index) -> String.Index? {
        var i = index
        var quote: Character?
        while i < text.endIndex {
            let c = text[i]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == ">" {
                return text.index(after: i)
            }
            i = text.index(after: i)
        }
        return nil
    }

    static func range(of attribute: String, in tag: String) -> (name: Range<String.Index>, value: Range<String.Index>)? {
        var search = tag.startIndex
        while let found = tag.range(of: attribute, options: [.caseInsensitive], range: search..<tag.endIndex) {
            search = found.upperBound
            // Must be a whole attribute name, not the tail of another one.
            let before = tag.index(before: found.lowerBound)
            guard found.lowerBound > tag.startIndex, tag[before].isWhitespace else { continue }
            var i = found.upperBound
            while i < tag.endIndex, tag[i].isWhitespace { i = tag.index(after: i) }
            guard i < tag.endIndex, tag[i] == "=" else { continue }
            i = tag.index(after: i)
            while i < tag.endIndex, tag[i].isWhitespace { i = tag.index(after: i) }
            guard i < tag.endIndex else { return nil }
            let quote = tag[i]
            guard quote == "\"" || quote == "'" else { continue }
            let valueStart = tag.index(after: i)
            guard let valueEnd = tag[valueStart...].firstIndex(of: quote) else { return nil }
            return (found, valueStart..<valueEnd)
        }
        return nil
    }

    static func value(of attribute: String, in tag: String) -> String? {
        guard let found = range(of: attribute, in: tag) else { return nil }
        let raw = String(tag[found.value])
        return raw.isEmpty ? nil : decodeEntities(raw)
    }

    static func replace(_ attribute: String, with newValue: String, in tag: String) -> String {
        guard let found = range(of: attribute, in: tag) else { return tag }
        var copy = tag
        copy.replaceSubrange(found.value, with: newValue)
        return copy
    }

    static func removeAttribute(_ attribute: String, from tag: String) -> String {
        guard let found = range(of: attribute, in: tag) else { return tag }
        var copy = tag
        // Take the closing quote with it.
        let end = copy.index(after: found.value.upperBound)
        copy.removeSubrange(found.name.lowerBound..<end)
        return copy
    }

    static func addClass(_ name: String, to tag: String) -> String {
        if let found = range(of: "class", in: tag) {
            var copy = tag
            copy.replaceSubrange(found.value, with: String(tag[found.value]) + " " + name)
            return copy
        }
        // Insert right after "<img".
        var copy = tag
        let insert = copy.index(copy.startIndex, offsetBy: 4)
        copy.insert(contentsOf: " class=\"\(name)\"", at: insert)
        return copy
    }

    static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    static func extensionFor(_ url: URL, data: Data) -> String {
        // Trust the bytes over the URL: plenty of images are served from paths with no
        // extension at all, or the wrong one.
        if data.count > 3 {
            let b = [UInt8](data.prefix(12))
            if b[0] == 0xFF, b[1] == 0xD8 { return "jpg" }
            if b[0] == 0x89, b[1] == 0x50 { return "png" }
            if b[0] == 0x47, b[1] == 0x49 { return "gif" }
            if b.count >= 12, b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "webp" }
            if b[0] == 0x3C { return "svg" }
        }
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? "img" : ext
    }
}

/// The user agent the extractor presents, shared so asset fetches look like the same
/// visitor that fetched the page.
enum ArticleExtractorUserAgent {
    static let value = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"
}
