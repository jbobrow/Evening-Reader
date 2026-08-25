import SwiftUI
import UIKit

/// What a page reports about its current selection.
struct WebSelection: Equatable {
    var text: String
    /// In the web view's own coordinate space (viewport points).
    var rect: CGRect
    var isEditable: Bool
}

enum EditAction: Hashable {
    case cut, copy, paste, search

    var label: String {
        switch self {
        case .cut: return "Cut"
        case .copy: return "Copy"
        case .paste: return "Paste"
        case .search: return "Search"
        }
    }
}

/// The edit callout, drawn by the app.
///
/// `UIEditMenuInteraction` has no appearance API — it is presented in its own window,
/// above everything the app draws, in system light chrome. On an amber panel it is the
/// one piece of furniture that stays stubbornly grey. So the system menu is suppressed
/// (see `WebKeyboardBridge`) and this is shown in its place.
struct AmberEditMenu: View {
    @Environment(\.amber) private var amber

    let actions: [EditAction]
    var perform: (EditAction) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                if index > 0 {
                    amber.color(0.62, opacity: 0.45)
                        .frame(width: 1, height: 18)
                }
                Button { perform(action) } label: {
                    Text(action.label)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(amber.ink)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(EditMenuButtonStyle())
            }
        }
        .background {
            Capsule().fill(amber.color(0.93))
        }
        .overlay {
            Capsule().strokeBorder(amber.color(0.62, opacity: 0.5), lineWidth: 1)
        }
        .clipShape(Capsule())
        .shadow(color: amber.color(0.0, opacity: 0.22), radius: 14, y: 4)
    }
}

private struct EditMenuButtonStyle: ButtonStyle {
    @Environment(\.amber) private var amber
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? amber.color(0.84) : .clear)
    }
}

/// Positions the callout against the selection, keeping it on screen.
struct AmberEditMenuOverlay: View {
    let selection: WebSelection
    let container: CGSize
    let actions: [EditAction]
    var perform: (EditAction) -> Void

    /// Roughly what the capsule measures; used only to keep it inside the container.
    private var estimatedWidth: CGFloat { CGFloat(actions.count) * 78 }
    private let height: CGFloat = 40

    var body: some View {
        let gap: CGFloat = 10
        let above = selection.rect.minY - height - gap
        let below = selection.rect.maxY + gap
        let y = above > 8 ? above : min(below, container.height - height - 8)
        let x = min(max(selection.rect.midX - estimatedWidth / 2, 8),
                    max(8, container.width - estimatedWidth - 8))

        AmberEditMenu(actions: actions, perform: perform)
            .fixedSize()
            .position(x: x + estimatedWidth / 2, y: y + height / 2)
            .transition(.opacity.combined(with: .scale(scale: 0.94)))
    }
}

/// The page-side half: reports what is selected, and where, so the app can put its own
/// callout there. Shared by the reader and the browser so both behave identically.
enum SelectionReporter {
    static func script(handler: String) -> String {
        """
        (function () {
          if (window.__agSelectionWired) return;
          window.__agSelectionWired = true;

          var post = function (payload) {
            try { window.webkit.messageHandlers.\(handler).postMessage(payload); } catch (e) {}
          };

          var report = function () {
            var sel = window.getSelection();
            if (!sel || sel.isCollapsed || sel.rangeCount === 0) { post({ name: "selection", text: "" }); return; }
            var text = String(sel);
            if (!text.trim()) { post({ name: "selection", text: "" }); return; }
            var r = sel.getRangeAt(0).getBoundingClientRect();
            var el = document.activeElement;
            var editable = !!(el && (el.isContentEditable ||
                                     /^(input|textarea)$/i.test(el.tagName || "")));
            post({ name: "selection", text: text, editable: editable,
                   x: r.left, y: r.top, w: r.width, h: r.height });
          };

          var pending;
          var schedule = function (delay) {
            clearTimeout(pending);
            pending = setTimeout(report, delay);
          };

          document.addEventListener("selectionchange", function () { schedule(140); }, { passive: true });
          // Keep the callout pinned to the words as the page moves under it.
          window.addEventListener("scroll", function () { schedule(0); }, { passive: true });
          window.addEventListener("resize", function () { schedule(0); }, { passive: true });
        })();
        """
    }
}

/// Runs an edit action against whichever web view is showing the selection.
@MainActor
enum WebEditor {
    static func perform(_ action: EditAction, on web: WKWebViewLike, selection: WebSelection,
                        search: (String) -> Void) {
        switch action {
        case .copy:
            UIPasteboard.general.string = selection.text
            clearSelection(on: web)
        case .cut:
            UIPasteboard.general.string = selection.text
            web.runJavaScript("document.execCommand('delete');")
        case .paste:
            guard let text = UIPasteboard.general.string,
                  let encoded = try? JSONEncoder().encode(text),
                  let literal = String(data: encoded, encoding: .utf8) else { return }
            web.runJavaScript("document.execCommand('insertText', false, \(literal));")
        case .search:
            search(selection.text)
            clearSelection(on: web)
        }
    }

    static func clearSelection(on web: WKWebViewLike) {
        web.runJavaScript("window.getSelection && window.getSelection().removeAllRanges();")
    }
}

/// Small seam so the editor can drive either web view without importing their models.
/// Main-actor bound because every conformer is: without this the conformance crosses
/// isolation, which is a warning today and an error under Swift 6.
@MainActor
protocol WKWebViewLike {
    func runJavaScript(_ source: String)
}
