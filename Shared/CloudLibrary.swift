import Foundation

/// Finds the iCloud library and keeps an eye on it.
///
/// The store is a folder of folders, which is exactly what iCloud Documents carries, so
/// syncing is mostly a matter of putting the library in the right place. Two things still
/// have to be done by hand.
///
/// The container has to be resolved off the main thread — `url(forUbiquityContainerIdentifier:)`
/// talks to a daemon and can take a noticeable moment the first time — and it returns nil
/// whenever iCloud is not available at all: no account signed in, the entitlement missing,
/// or the user having turned iCloud Drive off. That is not an error, it is the common case
/// on a fresh device, and the library simply stays local.
///
/// And a file that exists in the container is not necessarily *here*. iCloud leaves items
/// as placeholders until something asks for them, so a metadata query watches the
/// container and asks for anything that has not landed yet.
final class CloudLibrary {
    static let containerID = "iCloud.com.jonbobrow.AmberGlow"

    /// Posted when the container's contents change under us, so the library can reload.
    static let didChange = Notification.Name("AmberGlowCloudLibraryDidChange")

    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []

    /// Resolves the container's Documents folder, or nil if iCloud is not available.
    ///
    /// `Documents` specifically: items there are the ones iCloud treats as the user's own
    /// and shows in the Files app, which is the point of keeping the library as readable
    /// folders in the first place.
    static func documentsDirectory() async -> URL? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                let container = fm.url(forUbiquityContainerIdentifier: containerID)
                    ?? fm.url(forUbiquityContainerIdentifier: nil)
                guard let container else {
                    continuation.resume(returning: nil)
                    return
                }
                let documents = container.appendingPathComponent("Documents", isDirectory: true)
                try? fm.createDirectory(at: documents, withIntermediateDirectories: true)
                continuation.resume(returning: documents)
            }
        }
    }

    /// Starts watching, and pulls down anything iCloud is holding as a placeholder.
    func watch() {
        guard query == nil else { return }
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, "*")
        query.valueListAttributes = [NSMetadataUbiquitousItemDownloadingStatusKey]

        for name in [NSNotification.Name.NSMetadataQueryDidFinishGathering,
                     NSNotification.Name.NSMetadataQueryDidUpdate] {
            let token = NotificationCenter.default.addObserver(
                forName: name, object: query, queue: .main
            ) { [weak self] _ in
                self?.harvest(query)
            }
            observers.append(token)
        }
        self.query = query
        query.start()
    }

    func stop() {
        query?.stop()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        query = nil
    }

    private func harvest(_ query: NSMetadataQuery) {
        query.disableUpdates()
        defer { query.enableUpdates() }

        var pending = 0
        for i in 0..<query.resultCount {
            guard let item = query.result(at: i) as? NSMetadataItem,
                  let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { continue }
            let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            if status != NSMetadataUbiquitousItemDownloadingStatusCurrent {
                // Ask for it. This is what turns a placeholder into a readable file.
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                pending += 1
            }
        }
        // Tell the library either way: files that already arrived are worth reloading for,
        // and the ones still coming will trigger another update when they land.
        NotificationCenter.default.post(name: Self.didChange, object: nil,
                                        userInfo: ["pending": pending])
    }

    deinit { stop() }
}
