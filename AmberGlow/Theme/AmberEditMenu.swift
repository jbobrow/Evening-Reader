import SwiftUI
import UIKit

/// What a page reports about its current selection.
struct WebSelection: Equatable {
    var text: String
    /// In the web view's own coordinate space (viewport points).
    var rect: CGRect
    var isEditable: Bool
    /// The caret at each end of the selection — a line tall, next to no width — in the
    /// same space as `rect`. What `SelectionGrips` puts its grab zones around. Nil for a
    /// run selected inside a text control, which has handles of its own to offer.
    var start: CGRect? = nil
    var end: CGRect? = nil

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

/// Whether a page has text selected. Reported upward so that what is drawn over the
/// page can keep clear of the selection's handles while there are handles to reach for
/// — see the drawer's edge strip, which sits over the page's left margin.
struct PageHasSelection: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
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
    /// Where pasted text goes. Paste is the one item not answered through `perform`: it
    /// is drawn as the system's own paste control (see `AmberPasteControl`), which is
    /// what lets the clipboard be read without the system asking first, and that control
    /// hands over the text itself rather than reporting a tap.
    var onPaste: ((String) -> Void)? = nil

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
                if action == .paste {
                    AmberPasteControl(palette: amber, fill: 0.93, fontSize: 14,
                                      cornerStyle: .capsule) { text in
                        onPaste?(text)
                    }
                    .frame(width: action.width, height: EditAction.height)
                } else {
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
    @Environment(\.amber) private var amber

    let selection: WebSelection
    let container: CGSize
    let actions: [EditAction]
    var perform: (EditAction) -> Void
    var onPaste: ((String) -> Void)? = nil

    /// Where the callout stands, in the window, so that when Copy takes it down the word
    /// that the copy happened can be put up in the same place — after this view is gone.
    @State private var placed: CGRect = .zero

    private let margin: CGFloat = 8

    /// Room left between the callout and the words for the selection's handles.
    ///
    /// WebKit draws a grab dot above the start of a selection and below its end, and
    /// takes a touch from well around each. The callout is drawn over the page, so
    /// wherever it overlaps that zone it takes the touch instead — and a callout 10pt
    /// off the words sat squarely on the start handle, which then could not be moved.
    private let handleClearance: CGFloat = 28

    var body: some View {
        let height = EditAction.height
        let available = max(140, container.width - margin * 2)
        let width = min(EditAction.width(of: actions), available)
        let above = selection.rect.minY - height - handleClearance
        let below = selection.rect.maxY + handleClearance
        let y = above > margin ? above : min(below, container.height - height - margin)
        let x = min(max(selection.rect.midX - width / 2, margin),
                    max(margin, container.width - width - margin))

        AmberEditMenu(actions: actions, width: width, perform: { action in
            if action == .copy {
                CopiedFlash.show(over: placed, in: Self.window, palette: amber)
            }
            perform(action)
        }, onPaste: onPaste)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { placed = $0 }
            .position(x: x + width / 2, y: y + height / 2)
            .transition(.opacity.combined(with: .scale(scale: 0.94)))
    }

    /// The window the global coordinate space belongs to.
    private static var window: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
    }
}

/// Grab zones for the two ends of a selection, well larger than WebKit's own.
///
/// WebKit's handles are a thin bar with a small dot, and only take a touch from close
/// around the dot — too small a target to find with a thumb over text, and nothing on
/// `WKWebView` makes it bigger. So the app lays a zone of its own over each end and
/// moves the selection itself (see `__agSel` in `SelectionReporter`); WebKit's handles
/// follow the selection as it changes, so what the reader sees is unchanged.
///
/// Each zone runs from the middle of its line out past the dot — up above the start,
/// down below the end — so on a one-line selection the two cannot fight over a touch.
struct SelectionGrips: View {
    let selection: WebSelection?
    let web: WKWebViewLike
    /// True while an end is being dragged. The selection is reported as gone for as long
    /// as that lasts, and whatever stands aside for it must go on standing aside.
    @Binding var isGripping: Bool

    enum Grip: String { case start, end }

    /// A drag in progress: which end, where the zones were when it began, and how far
    /// the touch landed from the caret — kept, so the caret follows the thumb without
    /// jumping under it.
    private struct Hold {
        var grip: Grip
        var start: CGRect
        var end: CGRect
        var offset: CGSize
    }

    @State private var hold: Hold?

    private static let space = "SelectionGrips"
    private let width: CGFloat = 48
    /// How far a zone reaches past its line — the dot's side. Matches the room the
    /// callout leaves, so the two meet rather than overlap.
    private let reach: CGFloat = 28

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let ends {
                let (start, end) = ends
                zone(.start, frame: CGRect(x: start.minX - width / 2, y: start.minY - reach,
                                           width: width, height: start.height / 2 + reach),
                     start: start, end: end)
                zone(.end, frame: CGRect(x: end.minX - width / 2, y: end.midY,
                                         width: width, height: end.height / 2 + reach),
                     start: start, end: end)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .coordinateSpace(.named(Self.space))
    }

    /// Mid-drag the zones stay where the drag began: the page stops reporting the
    /// selection until it is let go, and a zone that moved would lose the touch.
    private var ends: (CGRect, CGRect)? {
        if let hold { return (hold.start, hold.end) }
        guard let start = selection?.start, let end = selection?.end else { return nil }
        return (start, end)
    }

    private func zone(_ grip: Grip, frame: CGRect, start: CGRect, end: CGRect) -> some View {
        Color.clear
            .frame(width: frame.width, height: frame.height)
            .contentShape(Rectangle())
            .position(x: frame.midX, y: frame.midY)
            // A zero-distance drag, which is what wins a touch over WebKit's own
            // recognisers — see the page scrubber.
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                    .onChanged { value in
                        if hold == nil {
                            let caret = grip == .start ? start : end
                            hold = Hold(grip: grip, start: start, end: end,
                                        offset: CGSize(width: caret.minX - value.startLocation.x,
                                                       height: caret.midY - value.startLocation.y))
                            isGripping = true
                            web.runJavaScript("window.__agSel && window.__agSel.begin('\(grip.rawValue)');")
                        }
                        guard let hold, value.translation != .zero else { return }
                        let x = value.location.x + hold.offset.width
                        let y = value.location.y + hold.offset.height
                        web.runJavaScript(String(format: "window.__agSel && window.__agSel.move(%.1f, %.1f);", x, y))
                    }
                    .onEnded { _ in
                        web.runJavaScript("window.__agSel && window.__agSel.end();")
                        hold = nil
                        isGripping = false
                    }
            )
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

          // Whether the callout is up. While it is, a change to the selection is the
          // reader dragging one of its handles: the callout is taken down at once, the
          // way the system's own steps aside, and put back where the selection comes to
          // rest. Left up, it would be redrawn over the words mid-drag, in the way of
          // the very handles being reached for.
          var showing = false;
          var send = function (payload) {
            showing = !!payload.text;
            post(payload);
          };

          // While a grip is being dragged, the fixed end of the selection — see `__agSel`.
          var grip = null;

          // The caret at one end of a range, as tall as the selection is painted. A
          // range's boxes only cover the glyphs, but WebKit paints a selected line from
          // the foot of its glyphs up through all the leading above them, and draws the
          // start handle's dot at the top of that — under a generous line height, well
          // clear of the glyphs themselves.
          // A collapsed range usually has a box of its own; where it has none, the edge
          // of the first or last box stands in.
          var caret = function (range, atEnd) {
            var c = range.cloneRange();
            c.collapse(!atEnd);
            var rs = c.getClientRects(), box;
            if (rs.length) {
              box = { x: rs[0].left, y: rs[0].top, h: rs[0].height };
            } else {
              var all = range.getClientRects();
              if (!all.length) return null;
              var q = atEnd ? all[all.length - 1] : all[0];
              box = { x: atEnd ? q.right : q.left, y: q.top, h: q.height };
            }
            var node = atEnd ? range.endContainer : range.startContainer;
            var el = node.nodeType === 1 ? node : node.parentElement;
            var line = el ? parseFloat(getComputedStyle(el).lineHeight) : NaN;
            if (line > box.h) { box.y -= line - box.h; box.h = line; }
            return box;
          };

          var report = function () {
            // Mid-drag the callout stays down; the selection is reported where it
            // comes to rest, when the grip lets go.
            if (grip) return;
            var el = document.activeElement;
            // A run selected inside a text control is not part of the document's
            // selection: getSelection() has nothing to say about it, and a range over
            // it has no size. The control itself knows both — what is selected, and
            // where it stands.
            if (el && /^(input|textarea)$/i.test(el.tagName || "") &&
                typeof el.selectionStart === "number" && el.selectionEnd > el.selectionStart) {
              var run = String(el.value || "").substring(el.selectionStart, el.selectionEnd);
              if (!run.trim()) { send({ name: "selection", text: "" }); return; }
              var b = el.getBoundingClientRect();
              send({ name: "selection", text: run, editable: !el.readOnly && !el.disabled,
                     x: b.left, y: b.top, w: b.width, h: b.height });
              return;
            }
            var sel = window.getSelection();
            if (!sel || sel.isCollapsed || sel.rangeCount === 0) { send({ name: "selection", text: "" }); return; }
            var text = String(sel);
            if (!text.trim()) { send({ name: "selection", text: "" }); return; }
            var range = sel.getRangeAt(0);
            var r = range.getBoundingClientRect();
            var editable = !!(el && (el.isContentEditable ||
                                     /^(input|textarea)$/i.test(el.tagName || "")));
            var payload = { name: "selection", text: text, editable: editable,
                            x: r.left, y: r.top, w: r.width, h: r.height };
            var s = caret(range, false), f = caret(range, true);
            if (s && f) {
              payload.sx = s.x; payload.sy = s.y; payload.sh = s.h;
              payload.ex = f.x; payload.ey = f.y; payload.eh = f.h;
              // The callout keeps its distance from the lines, not just the glyphs.
              var top = Math.min(r.top, s.y), bottom = Math.max(r.bottom, f.y + f.h);
              payload.y = top; payload.h = bottom - top;
            }
            send(payload);
          };

          var pending;
          var schedule = function (delay) {
            clearTimeout(pending);
            pending = setTimeout(report, delay);
          };

          document.addEventListener("selectionchange", function () {
            if (showing) send({ name: "selection", text: "" });
            schedule(140);
          }, { passive: true });
          // Keep the callout pinned to the words as the page moves under it.
          window.addEventListener("scroll", function () { schedule(0); }, { passive: true });
          window.addEventListener("resize", function () { schedule(0); }, { passive: true });

          // Moves one end of the selection to a point, for the app's grab zones. The
          // other end is held where it was when the grip was taken, so dragging an end
          // past the other one turns the selection around rather than losing it.
          window.__agSel = {
            begin: function (which) {
              var sel = window.getSelection();
              if (!sel || sel.rangeCount === 0) { grip = null; return; }
              var r = sel.getRangeAt(0);
              grip = which === "start"
                ? { node: r.endContainer, offset: r.endOffset }
                : { node: r.startContainer, offset: r.startOffset };
              clearTimeout(pending);
            },
            move: function (x, y) {
              if (!grip) return;
              // Held near the top or bottom of the glass, the page runs on under it.
              var edge = 44, h = window.innerHeight;
              if (y < edge) window.scrollBy(0, -Math.ceil((edge - y) / 3));
              else if (y > h - edge) window.scrollBy(0, Math.ceil((y - h + edge) / 3));
              x = Math.min(Math.max(x, 1), window.innerWidth - 1);
              y = Math.min(Math.max(y, 1), h - 1);
              var p = document.caretRangeFromPoint && document.caretRangeFromPoint(x, y);
              if (!p) return;
              // Never down to nothing: a collapsed selection has no handles to hold.
              if (p.startContainer === grip.node && p.startOffset === grip.offset) return;
              window.getSelection().setBaseAndExtent(grip.node, grip.offset,
                                                     p.startContainer, p.startOffset);
            },
            end: function () { grip = null; schedule(0); }
          };
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
        case .search:
            search(selection.tidyText)
            clearSelection(on: web)
        case .paste, .define, .highlight, .askAI:
            // Paste never arrives here: the menu's paste item is the system's own
            // control, which delivers the text to `paste(_:on:)` directly. Reading the
            // pasteboard from here instead is what would bring up the system's dialog.
            break
        }
    }

    /// Puts pasted text into the page, over whatever is selected.
    static func paste(_ text: String, on web: WKWebViewLike) {
        guard let encoded = try? JSONEncoder().encode(text),
              let literal = String(data: encoded, encoding: .utf8) else { return }
        web.runJavaScript("document.execCommand('insertText', false, \(literal));")
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
