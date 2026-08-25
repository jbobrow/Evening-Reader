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

/// Loads a page in an off-screen web view and runs the reader extraction script in it.
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

    private static let script: String? = {
        guard let url = Bundle.main.url(forResource: "extract", withExtension: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

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
        for delay in [0.35, 1.6] {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if let result = try await run(script, in: web), result.ok {
                return result
            }
        }
        // Last attempt so the caller gets the real reason, and any partial metadata.
        if let result = try await run(script, in: web) {
            throw ExtractionError.unreadable(result.reason)
        }
        throw ExtractionError.unreadable("")
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
