import SwiftUI
import WebKit

/// Shows a saved PDF, lit like everything else.
///
/// A PDF has no document of ours to restyle, so it cannot be re-typeset the way an
/// article is. What it can be is filtered: WebKit renders the pages, and the same
/// grayscale-then-amber mapping the browser uses is applied to the rendered view, so a
/// white page becomes the panel's page and the type becomes ink. At night the mapping is
/// inverted, exactly as it is for a web page written for a light ground.
struct PDFReaderView: View {
    @Environment(DisplaySettings.self) private var settings
    @Environment(\.amber) private var amber

    let fileURL: URL

    /// Where a white page lands, matching the app's own surfaces.
    private let pageLevel = 0.88
    private let inkFloor = 0.045

    private var isNight: Bool { settings.polarity == .night }
    private var tintSign: Double { isNight ? -1 : 1 }
    private var tintColor: Color { isNight ? amber.color(0.0) : amber.color(pageLevel) }
    private var tintFloor: Double {
        guard isNight else { return inkFloor }
        let ink = amber.rgb(0.0).0
        let page = amber.rgb(pageLevel).0
        return ink > 0 ? min(1, page / ink) : inkFloor
    }

    var body: some View {
        PDFWebView(fileURL: fileURL)
            .grayscale(1)
            .contrast(tintSign * (1 - tintFloor))
            .brightness(tintFloor / 2)
            .colorMultiply(tintColor)
            .overlay { BacklightBloom(level: isNight ? 0.0 : pageLevel) }
            .ignoresSafeArea(.container, edges: .bottom)
    }
}

private struct PDFWebView: UIViewRepresentable {
    let fileURL: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // The document is on disk; nothing here should reach the network.
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.showsVerticalScrollIndicator = false
        web.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}
}
