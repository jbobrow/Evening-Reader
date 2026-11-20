import SafariServices

/// Safari's side of "Save to Evening Reader". The extension's `sendNativeMessage` arrives
/// here rather than at a separate host as it does in Chrome; what is done with it is the
/// same, and is `LibraryDrop`'s.
///
/// Runs sandboxed. Its entitlements open the one folder it writes to — the library in
/// Evening Reader's iCloud container — and the network, for the article's pictures.
class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems.first as? NSExtensionItem
        let message = request?.userInfo?[SFExtensionMessageKey] as? [String: Any] ?? [:]

        Task {
            let reply = await LibraryDrop.handle(message)
            let response = NSExtensionItem()
            response.userInfo = [SFExtensionMessageKey: reply]
            context.completeRequest(returningItems: [response], completionHandler: nil)
        }
    }
}
