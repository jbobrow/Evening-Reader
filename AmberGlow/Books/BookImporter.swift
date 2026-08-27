import Foundation

/// Turns a stored `book.epub` into the `body.html` and table of contents a book is read
/// from. Deliberately not `@MainActor` — unzipping and flattening a real book is real
/// work, and `Library` runs it off the main actor and only brings the result back.
enum BookImporter {
    struct Imported {
        var title: String
        var creator: String?
        var publisher: String?
        var identifier: String?
        var chapters: [BookChapter]
        var wordCount: Int
        var coverAssetName: String?
        var coverAssetClass: String?
    }

    enum ImportError: Error, LocalizedError {
        case bookFileMissing
        case empty
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .bookFileMissing: return "This book's file is missing."
            case .empty: return "This book has no chapters to read."
            case .writeFailed: return "Couldn't save this book's text."
            }
        }
    }

    static func importBook(for article: SavedArticle, store: ArticleStore) throws -> Imported {
        let fileURL = store.bookURL(for: article)
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            throw ImportError.bookFileMissing
        }

        // The guard already ran once, in the share extension, before this file was ever
        // written to disk — checked again here because that is a separate process and a
        // separate moment, and this is the one place that is about to act on the bytes.
        let (archive, package) = try EpubInspector.open(data: data)

        let result = EpubFlattener.flatten(archive: archive, package: package, article: article, store: store)
        guard !result.chapters.isEmpty, !result.html.isEmpty else { throw ImportError.empty }
        guard store.writeBody(result.html, for: article) else { throw ImportError.writeFailed }
        BookContents.write(result.chapters, for: article, store: store)

        return Imported(title: package.title, creator: package.creator, publisher: package.publisher,
                        identifier: package.identifier, chapters: result.chapters,
                        wordCount: result.wordCount, coverAssetName: result.coverAssetName,
                        coverAssetClass: result.coverAssetClass)
    }
}
