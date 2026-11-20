import Foundation

/// Tells Chrome, and every other Chromium browser on this Mac, where Evening Reader's
/// helper is, so the Chrome extension can save without anyone running a script.
///
/// A Chrome extension can't write files outside its own sandbox, so it hands each article
/// to a native messaging host: `evening-reader-host`, which this app carries in
/// `Contents/MacOS`. A browser finds a host only through a small JSON file in its own
/// `NativeMessagingHosts` folder, and nothing from the Chrome Web Store can put one there.
/// This app does, each time it opens, so the path stays right if the app has moved.
///
/// The app is sandboxed and can reach only those folders, never the browsers' own data;
/// the paths are in `App.entitlements` and must match `browsers` below.
enum ChromeHosts {
    /// The name the extension asks for, `HOST` in `background.js`.
    static let name = "com.jonbobrow.eveningreader"

    /// The extensions the helper answers: the copy from the Chrome Web Store, and the
    /// unpacked copy in `Extension/web`, whose ID the `key` in its manifest fixes.
    static let extensionIDs = [
        "dmlokfbnjmfbnabmieklfickbjihkcag",  // Chrome Web Store
        "jchcaaglfjbkhenophbgnkopmdlibacd",  // unpacked
    ]

    /// Where the extension is installed from.
    static let storeURL = URL(string: "https://chromewebstore.google.com/detail/\(extensionIDs[0])")!

    /// Each browser's name as people know it, and its folder in `~/Library/Application Support`.
    static let browsers: [(name: String, folder: String)] = [
        ("Chrome", "Google/Chrome"),
        ("Chrome Beta", "Google/Chrome Beta"),
        ("Chrome Dev", "Google/Chrome Dev"),
        ("Chrome Canary", "Google/Chrome Canary"),
        ("Chromium", "Chromium"),
        ("Brave", "BraveSoftware/Brave-Browser"),
        ("Edge", "Microsoft Edge"),
        ("Vivaldi", "Vivaldi"),
        ("Arc", "Arc/User Data"),
    ]

    enum Outcome {
        /// Registered with these browsers, by name.
        case registered([String])
        /// No Chromium browser on this Mac.
        case noBrowser
        /// Opened from somewhere that won't last — a disk image, or a copy macOS runs from
        /// a randomized location until it's moved out of Downloads — so a browser given
        /// this path would lose the helper.
        case notInPlace
        case failed(String)
    }

    /// Done once, the first time anything asks: when the app finishes launching.
    static let outcome: Outcome = register()

    private static func register() -> Outcome {
        let bundlePath = Bundle.main.bundlePath
        if bundlePath.contains("/AppTranslocation/") || bundlePath.hasPrefix("/Volumes/") {
            return .notInPlace
        }
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "evening-reader-host"),
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            return .failed("The helper is missing from this copy of Evening Reader Saver.")
        }

        let manifest: [String: Any] = [
            "name": name,
            "description": "Saves pages to the Evening Reader library in iCloud",
            "path": helper.path,
            "type": "stdio",
            "allowed_origins": extensionIDs.map { "chrome-extension://\($0)/" },
        ]
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        } catch {
            return .failed(error.localizedDescription)
        }

        // The real home: inside the sandbox `NSHomeDirectory()` is the app's container.
        let home = getpwuid(getuid()).map { URL(fileURLWithPath: String(cString: $0.pointee.pw_dir)) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)

        var registered: [String] = []
        var lastError: Error?
        for browser in browsers {
            let folder = support
                .appendingPathComponent(browser.folder, isDirectory: true)
                .appendingPathComponent("NativeMessagingHosts", isDirectory: true)
            // Made only inside a browser's folder that is already there: the sandbox can't
            // see whether the browser's folder exists, but making this one fails if it doesn't.
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            } catch CocoaError.fileWriteFileExists {
                // Already there.
            } catch {
                continue  // Not installed.
            }
            do {
                try data.write(to: folder.appendingPathComponent("\(name).json"), options: .atomic)
                registered.append(browser.name)
            } catch {
                lastError = error
            }
        }

        if !registered.isEmpty { return .registered(registered) }
        if let lastError { return .failed(lastError.localizedDescription) }
        return .noBrowser
    }
}
