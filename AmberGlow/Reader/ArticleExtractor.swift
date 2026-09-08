import Foundation
import WebKit
import UIKit

struct ExtractionResult: Codable {
    var ok: Bool
    var reason: String
    var url: String
    var title: String
    var byline: String
    var site: String
    var published: String
    var excerpt: String
    var leadImage: String
    var wordCount: Int
    var length: Int
    var html: String
    /// The article as Markdown, from the Defuddle pass. Empty from the app's own
    /// extractor, which produces HTML only.
    var markdown: String
    /// `"amber"` or `"defuddle"` — which pass the body above came from.
    var source: String
}

enum ExtractionError: LocalizedError {
    case badURL
    case timedOut
    case navigationFailed(String)
    case scriptMissing
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "That doesn't look like a web address."
        case .timedOut: return "The page took too long to load."
        case .navigationFailed(let m): return m
        case .scriptMissing: return "The reader script is missing from the app bundle."
        case .unreadable(let r):
            return r == "too-short"
                ? "Couldn't find an article on that page."
                : "Couldn't read that page."
        }
    }
}

/// Loads a page in an off-screen web view and reads the article out of it.
///
/// Two passes over the same loaded page. The app's own `extract.js` goes first: it is
/// written for this reader and its output needs no cleaning up afterwards. Defuddle
/// follows, always — it is the only source of the Markdown every article keeps as its
/// portable sidecar, and when the first pass came back with nothing it is also the
/// second chance. Defuddle carries site-specific extractors for the places a
/// density-scoring pass reliably fails, Substack among them.
///
/// One extraction at a time — a second call waits its turn rather than fighting over
/// the shared web view.
@MainActor
final class ArticleExtractor: NSObject {
    static let shared = ArticleExtractor()

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private static let script: String? = resource("extract")
    /// The vendored Defuddle bundle, injected into the page rather than evaluated
    /// against it: three quarters of a megabyte is a lot to hand `evaluateJavaScript`
    /// as a string, and as a user script WebKit parses it as part of the load.
    private static let defuddleBundle: String? = resource("defuddle")
    private static let defuddleScript: String? = resource("defuddle-run")

    private static func resource(_ name: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func extract(url: URL) async throws -> ExtractionResult {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw ExtractionError.badURL
        }
        guard let script = Self.script else { throw ExtractionError.scriptMissing }

        await acquire()
        defer { release() }

        let web = makeWebView()
        defer { teardown(web) }

        try await load(url, in: web)

        // Give client-side renderers a beat, then try; retry once for slow hydration.
        // The last answer is kept even when it failed, for its reason and whatever
        // metadata it did manage to find.
        var primary: ExtractionResult?
        for delay in [0.35, 1.6] {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            let attempt = try await run(script, in: web)
            primary = attempt ?? primary
            if attempt?.ok == true { break }
        }

        let second = await runDefuddle(in: web)

        if let primary, primary.ok { return merged(primary, with: second) }
        // The page defeated the app's own reading of it. Defuddle gets the last word,
        // and on the sites that habitually defeat it — a Substack post, anything that
        // ships its article inside a framework shell — usually has the right answer.
        if let second, second.ok { return second }
        throw ExtractionError.unreadable(primary?.reason ?? second?.reason ?? "")
    }

    /// The Defuddle pass, which never throws: a second opinion that failed to arrive is
    /// not a reason to lose the reading the app already has.
    private func runDefuddle(in web: WKWebView) async -> ExtractionResult? {
        guard Self.defuddleBundle != nil, let script = Self.defuddleScript else { return nil }
        return try? await run(script, in: web)
    }

    /// The app's own reading of the page, with the Defuddle pass filling the gaps: the
    /// Markdown sidecar always, and any single piece of metadata the first pass missed.
    /// Defuddle reads schema.org data, which is often where a byline or a publication
    /// date is the only place it is stated.
    private func merged(_ primary: ExtractionResult, with other: ExtractionResult?) -> ExtractionResult {
        guard let other else { return primary }
        var out = primary
        out.markdown = other.markdown
        if out.title.isEmpty { out.title = other.title }
        if out.byline.isEmpty { out.byline = other.byline }
        if out.site.isEmpty { out.site = other.site }
        if out.published.isEmpty { out.published = other.published }
        if out.excerpt.isEmpty { out.excerpt = other.excerpt }
        if out.leadImage.isEmpty { out.leadImage = other.leadImage }
        return out
    }

    // MARK: - serialization

    private func acquire() async {
        if !isBusy { isBusy = true; return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters.append(c)
        }
        isBusy = true
    }

    private func release() {
        isBusy = false
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }

    // MARK: - web view plumbing

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()          // reuse logins from the in-app browser
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.suppressesIncrementalRendering = false
        if let bundle = Self.defuddleBundle {
            // Shadowed `module`, `exports` and `define` so the bundle's UMD preamble
            // takes its browser branch and puts `Defuddle` on the window. Some pages
            // leak a global `module` of their own, and without this the library would
            // quietly hand itself to the page instead of to us.
            let source = "(function(){var module,exports,define;\n\(bundle)\n})();"
            config.userContentController.addUserScript(
                WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }

        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 1280), configuration: config)
        web.navigationDelegate = self
        web.customUserAgent = Self.desktopUserAgent
        web.isUserInteractionEnabled = false
        web.alpha = 0.01

        // WebKit throttles views that were never attached, so park it behind the UI.
        if let window = Self.activeWindow {
            window.addSubview(web)
            window.sendSubviewToBack(web)
        }
        webView = web
        return web
    }

    private func teardown(_ web: WKWebView) {
        web.stopLoading()
        web.navigationDelegate = nil
        web.removeFromSuperview()
        if webView === web { webView = nil }
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    private func load(_ url: URL, in web: WKWebView) async throws {
        var request = URLRequest(url: url)
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            continuation = c
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.finishLoad(.failure(ExtractionError.timedOut))
            }
            web.load(request)
        }
    }

    fileprivate func finishLoad(_ result: Result<Void, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard let c = continuation else { return }
        continuation = nil
        c.resume(with: result)
    }

    private func run(_ script: String, in web: WKWebView) async throws -> ExtractionResult? {
        let value = try? await web.evaluateJavaScript(script)
        guard let json = value as? String, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ExtractionResult.self, from: data)
    }

    /// Many publishers serve a stripped mobile page; ask for the desktop one, which is
    /// usually the version with the full article body in the HTML.
    static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// What Safari on an iPhone says it is. For *browsing* on a phone, as against
    /// extracting: a desktop page laid out for a thousand points and shown on three
    /// hundred and ninety comes out with its edges past the glass and its video
    /// letterboxed in a column meant for a wider one. Safari itself asks for the
    /// desktop page on an iPad and the phone page on a phone; so does the browser.
    ///
    /// With the version the device is really running, not a fixed one: YouTube reads
    /// the version to decide how to stream, and told it was iOS 17.0 — before Managed
    /// Media Source — it fell back to HLS, and its HLS for a 4K video failed to decode
    /// in the web view where Safari, saying what it was, played the same video.
    static var phoneUserAgent: String {
        let version = UIDevice.current.systemVersion
        let major = version.split(separator: ".").first.map(String.init) ?? version
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(version.replacingOccurrences(of: ".", with: "_")) " +
            "like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) " +
            "Version/\(major).0 Mobile/15E148 Safari/604.1"
    }

    /// The one the browser uses on this device.
    static var browsingUserAgent: String {
        UIDevice.current.userInterfaceIdiom == .phone ? phoneUserAgent : desktopUserAgent
    }

    static var activeWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ??
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first
    }
}

extension ArticleExtractor: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoad(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoad(.failure(ExtractionError.navigationFailed(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoad(.failure(ExtractionError.navigationFailed(error.localizedDescription)))
    }
}
