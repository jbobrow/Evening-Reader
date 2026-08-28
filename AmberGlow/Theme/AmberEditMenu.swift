import SwiftUI
import UIKit

/// What a page reports about its current selection.
struct WebSelection: Equatable {
    var text: String
    /// In the web view's own coordinate space (viewport points).
    var rect: CGRect
    var isEditable: Bool

    /// The selection with the document's own line breaks and indentation collapsed —
    /// what to put on the clipboard, or in front of a question about it.
    var tidyText: String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// One word, and one word only, which is the only shape a dictionary has an answer
    /// for. Punctuation the reader dragged over is not part of the word — a selection
    /// that ends on a full stop is still a selection of one word.
    var singleWord: String? {
        let word = tidyText.trimmingCharacters(
            in: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'’-")).inverted)
        guard word.count >= 2, word.count <= 40,
              !word.contains(where: { $0.isWhitespace }),
              word.contains(where: { $0.isLetter }) else { return nil }
        return word
    }
}

enum EditAction: Hashable {
    case cut, copy, paste, search, define, highlight, askAI

    var label: String {
        switch self {
        case .cut: return "Cut"
        case .copy: return "Copy"
        case .paste: return "Paste"
        case .search: return "Search"
        case .define: return "Define"
        case .highlight: return "Highlight"
        case .askAI: return "Ask AI"
        }
    }
}

extension EditAction {
    /// The font the callout sets its labels in. Kept here rather than at the call site
    /// because the width of an item is worked out from it below.
    static var labelFont: UIFont { .systemFont(ofSize: 14, weight: .medium) }

    /// How wide each item draws: its label, plus 15pt of padding on each side.
    ///
    /// Measured rather than estimated, because the callout has to be positioned against
    /// the selection *before* it is laid out — and with five items on a small phone the
    /// difference between a guess and the truth is the difference between a capsule
    /// centred on the words and one hanging off the edge of the glass. Measured once:
    /// there are seven labels and they never change.
    private static let widths: [EditAction: CGFloat] = {
        let font = UIFont.systemFont(ofSize: 14, weight: .medium)
        let all: [EditAction] = [.cut, .copy, .paste, .search, .define, .highlight, .askAI]
        var out: [EditAction: CGFloat] = [:]
        for action in all {
            out[action] = ceil((action.label as NSString)
                .size(withAttributes: [.font: font]).width) + 30
        }
        return out
    }()

    var width: CGFloat { Self.widths[self] ?? 78 }

    /// The whole row, dividers included.
    static func width(of actions: [EditAction]) -> CGFloat {
        actions.reduce(0) { $0 + $1.width } + CGFloat(max(0, actions.count - 1))
    }

    static let height: CGFloat = 38
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
    /// How much room the callout has been given. When the row needs more than this — a
    /// phone, and a selection that offers everything — it scrolls instead of being cut
    /// off at the edge of the glass.
    var width: CGFloat?
    var perform: (EditAction) -> Void

    var body: some View {
        let content = EditAction.width(of: actions)
        Group {
            if let width, width < content - 0.5 {
                ScrollView(.horizontal) { row.fixedSize() }
                    .scrollIndicators(.hidden)
                    .frame(width: width, height: EditAction.height)
            } else {
                row.frame(width: width, height: EditAction.height)
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

    private var row: some View {
        HStack(spacing: 0) {
            ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                if index > 0 {
                    amber.color(0.62, opacity: 0.45)
                        .frame(width: 1, height: 18)
                }
                Button { perform(action) } label: {
                    Text(action.label)
                        .font(Font(EditAction.labelFont))
                        .foregroundStyle(amber.ink)
                        .frame(width: action.width, height: EditAction.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(EditMenuButtonStyle())
            }
        }
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

    private let margin: CGFloat = 8

    var body: some View {
        let height = EditAction.height
        let available = max(140, container.width - margin * 2)
        let width = min(EditAction.width(of: actions), available)
        let gap: CGFloat = 10
        let above = selection.rect.minY - height - gap
        let below = selection.rect.maxY + gap
        let y = above > margin ? above : min(below, container.height - height - margin)
        let x = min(max(selection.rect.midX - width / 2, margin),
                    max(margin, container.width - width - margin))

        AmberEditMenu(actions: actions, width: width, perform: perform)
            .position(x: x + width / 2, y: y + height / 2)
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
///
/// Only the four that are really edits. Highlighting, defining and asking are not things
/// done *to* a selection — they are things the app does with one, and they are answered
/// by the reader rather than by the page.
@MainActor
enum WebEditor {
    static func perform(_ action: EditAction, on web: WKWebViewLike, selection: WebSelection,
                        search: (String) -> Void) {
        switch action {
        case .copy:
            UIPasteboard.general.string = selection.tidyText
            clearSelection(on: web)
        case .cut:
            UIPasteboard.general.string = selection.tidyText
            web.runJavaScript("document.execCommand('delete');")
        case .paste:
            guard let text = UIPasteboard.general.string,
                  let encoded = try? JSONEncoder().encode(text),
                  let literal = String(data: encoded, encoding: .utf8) else { return }
            web.runJavaScript("document.execCommand('insertText', false, \(literal));")
        case .search:
            search(selection.tidyText)
            clearSelection(on: web)
        case .define, .highlight, .askAI:
            break
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
