//
//  ViewController.swift
//  Evening Reader Helper
//
//  Created by Jonathan Bobrow on 11/2/26.
//

import Cocoa
import SafariServices
import WebKit

let extensionBundleIdentifier = "com.jonbobrow.AmberGlow.Saver.Extension"

class ViewController: NSViewController, WKNavigationDelegate, WKScriptMessageHandler {

    @IBOutlet var webView: WKWebView!

    override func viewDidLoad() {
        super.viewDidLoad()

        self.webView.navigationDelegate = self

        self.webView.configuration.userContentController.add(self, name: "controller")

        self.webView.loadFileURL(Bundle.main.url(forResource: "Main", withExtension: "html")!, allowingReadAccessTo: Bundle.main.resourceURL!)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        showChrome(in: webView)

        SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: extensionBundleIdentifier) { (state, error) in
            guard let state = state, error == nil else {
                // Insert code to inform the user that something went wrong.
                return
            }

            DispatchQueue.main.async {
                if #available(macOS 13, *) {
                    webView.evaluateJavaScript("show(\(state.isEnabled), true)")
                } else {
                    webView.evaluateJavaScript("show(\(state.isEnabled), false)")
                }
            }
        }
    }

    /// What opening the app did for Chrome, said under the Safari part.
    private func showChrome(in webView: WKWebView) {
        let state: String
        var detail = ""
        switch ChromeHosts.outcome {
        case .registered(let names):
            state = "ready"
            detail = ListFormatter.localizedString(byJoining: names)
        case .noBrowser:
            state = "none"
        case .notInPlace:
            state = "move"
        case .failed(let message):
            state = "failed"
            detail = message
        }
        webView.callAsyncJavaScript("showChrome(state, detail)",
                                    arguments: ["state": state, "detail": detail],
                                    in: nil, in: .page, completionHandler: nil)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.body as? String {
        case "open-preferences":
            SFSafariApplication.showPreferencesForExtension(withIdentifier: extensionBundleIdentifier) { error in
                DispatchQueue.main.async {
                    NSApplication.shared.terminate(nil)
                }
            }
        case "open-chrome-store":
            NSWorkspace.shared.open(ChromeHosts.storeURL)
        default:
            break
        }
    }

}
