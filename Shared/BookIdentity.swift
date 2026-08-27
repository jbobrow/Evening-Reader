import Foundation
import CryptoKit

/// The synthetic `url` a book is saved under, standing in for the web address an article
/// or a PDF already has. `ArticleStore.append` and `Library.add` both dedupe on `url`, so
/// this is what makes sharing the same book twice land on one item instead of two.
enum BookIdentity {
    /// Prefers the book's own `dc:identifier` — normalized, so the same ISBN or UUID
    /// written as `urn:isbn:…` or `URN:ISBN:…` still matches itself — and falls back to a
    /// digest of the file when a book simply doesn't declare one.
    static func url(package: EpubPackage, fileData: Data) -> URL {
        let source: String
        if let raw = package.identifier?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            source = "id:" + raw.lowercased()
                .replacingOccurrences(of: "urn:uuid:", with: "")
                .replacingOccurrences(of: "urn:isbn:", with: "")
        } else {
            source = "digest"
        }
        // Hashed either way, rather than carrying the identifier's own text into a URL
        // host — an EPUB's dc:identifier is free text and can hold characters a host
        // component has no clean way to represent.
        let bytes = source == "digest" ? fileData : Data(source.utf8)
        let digest = SHA256.hash(data: bytes).prefix(16).map { String(format: "%02x", $0) }.joined()
        return URL(string: "amber-book://\(digest)")!
    }
}
