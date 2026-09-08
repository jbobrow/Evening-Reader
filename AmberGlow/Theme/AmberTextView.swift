import SwiftUI
import UIKit

/// The panel's keyboard behind a paragraph rather than a line.
///
/// `AmberTextField` is the right control for a URL or a query — one line, a Go key, and
/// a submit. A note is neither: it is a sentence or two about a passage, and a note that
/// can only ever show its first thirty characters is a note the reader cannot read back.
/// So this is the same field, wrapped, with the same board behind it.
///
/// There is no return key on the board and none is wanted here. "Multiline" means the
/// note wraps and is read whole, not that it holds paragraphs — `goLabel` still ends the
/// editing, as it does everywhere else in the app.
struct AmberTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool

    var placeholder: String
    var palette: AmberPalette
    var showsTexture: Bool
    var goLabel: String = "Done"
    var fontSize: CGFloat = 15
    /// How tall the field stands when empty. It scrolls past this rather than growing,
    /// so the card it sits in keeps the size the reader last saw it at.
    var lines: Int = 4
    var onSubmit: () -> Void = {}

    var height: CGFloat {
        let line = UIFont.systemFont(ofSize: fontSize).lineHeight
        return ceil(line * CGFloat(lines) + 4)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// A field taken down while it still has the keyboard would take the keyboard with
    /// it in one step. Letting go first gives it its usual way down.
    static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) {
        if view.isFirstResponder { view.resignFirstResponder() }
    }

    func makeUIView(context: Context) -> UITextView {
        let view = AmberInputTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.autocorrectionType = .no
        view.autocapitalizationType = .sentences
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.textContentType = .none
        // The text starts at the leading edge, like every other field in the app; a
        // `UITextView` otherwise insets its own by 5pt and sits half a character in.
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.showsVerticalScrollIndicator = false
        view.alwaysBounceVertical = false
        context.coordinator.view = view
        context.coordinator.installKeyboard(self, on: view)
        Self.removeEditMenu(from: view)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text { view.text = text }
        apply(style: view)
        Self.removeEditMenu(from: view)
        context.coordinator.refreshKeyboard(self)

        DispatchQueue.main.async {
            if isFocused, !view.isFirstResponder { view.becomeFirstResponder() }
            if !isFocused, view.isFirstResponder { view.resignFirstResponder() }
        }
    }

    /// Same move as `AmberTextField`'s: the callout is contributed through an
    /// interaction rather than only through the responder chain, so refusing the actions
    /// is not enough on its own.
    static func removeEditMenu(from view: UITextView) {
        for interaction in view.interactions where interaction is UIEditMenuInteraction {
            view.removeInteraction(interaction)
        }
    }

    private func apply(style view: UITextView) {
        view.font = .systemFont(ofSize: fontSize)
        view.textColor = UIColor(palette.ink)
        view.tintColor = UIColor(palette.inkStrong)
        (view as? AmberInputTextView)?.setPlaceholder(placeholder,
                                                      color: UIColor(palette.inkFaint),
                                                      font: .systemFont(ofSize: fontSize))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: AmberTextView
        weak var view: UITextView?
        private let board = AmberKeyboardInstaller()
        /// The callout over a selection, drawn by the app since the system's is refused.
        private let callout = FieldCallout()

        init(_ parent: AmberTextView) { self.parent = parent }

        deinit {
            let callout = self.callout
            Task { @MainActor in callout.hide() }
        }

        func installKeyboard(_ parent: AmberTextView, on view: UITextView) {
            board.onKey = { [weak self] key in self?.handle(key) }
            refreshKeyboard(parent)
            view.inputView = board.container
        }

        func refreshKeyboard(_ parent: AmberTextView) {
            board.apply(AmberKeyboardInstaller.Style(palette: parent.palette,
                                                     showsTexture: parent.showsTexture,
                                                     showsDotCom: false,
                                                     goLabel: parent.goLabel))
        }

        private func handle(_ key: AmberKey) {
            guard let view else { return }
            switch key {
            case .char(let s):  view.insertText(s)
            case .space:        view.insertText(" ")
            case .dotCom:       view.insertText(".com")
            case .backspace:    view.deleteBackward()
            case .go, .hide:
                view.resignFirstResponder()
                parent.isFocused = false
                if case .go = key { parent.onSubmit() }
            case .selectAll:    view.selectAll(nil)
            case .cut:          view.cut(nil)
            case .copy:
                view.copy(nil)
                CopiedFlash.show(in: board.container,
                                 center: CGPoint(x: board.container.bounds.midX, y: 23),
                                 palette: parent.palette)
            case .paste(let text): view.insertText(text)
            case .autofill, .shift, .plane: break   // handled inside the keyboard's own state
            }
        }

        private func performFromCallout(_ action: EditAction) {
            guard let view else { return }
            switch action {
            case .cut: view.cut(nil)
            case .copy: view.copy(nil)
            default: break
            }
            callout.hide()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            callout.update(for: textView, palette: parent.palette,
                           perform: { [weak self] in self?.performFromCallout($0) },
                           onPaste: { [weak self] text in
                               self?.view?.insertText(text)
                               self?.callout.hide()
                           })
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text ?? ""
            (textView as? AmberInputTextView)?.refreshPlaceholder()
            callout.hide()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused { parent.isFocused = false }
            callout.hide()
        }
    }
}

/// Suppresses the system chrome the app cannot paint, and draws the placeholder a
/// `UITextView` does not have one of.
private final class AmberInputTextView: UITextView {
    private let prompt = UILabel()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        prompt.numberOfLines = 0
        prompt.isUserInteractionEnabled = false
        addSubview(prompt)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setPlaceholder(_ text: String, color: UIColor, font: UIFont) {
        prompt.text = text
        prompt.textColor = color
        prompt.font = font
        refreshPlaceholder()
    }

    func refreshPlaceholder() {
        prompt.isHidden = !(text ?? "").isEmpty
        setNeedsLayout()
    }

    override var text: String! {
        didSet { refreshPlaceholder() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        prompt.frame = CGRect(x: 0, y: 0, width: bounds.width,
                              height: prompt.sizeThatFits(CGSize(width: bounds.width,
                                                                 height: .greatestFiniteMagnitude)).height)
    }

    override var inputAssistantItem: UITextInputAssistantItem {
        let item = super.inputAssistantItem
        item.leadingBarButtonGroups = []
        item.trailingBarButtonGroups = []
        return item
    }

    /// The actions are not lost: they moved to the keyboard's own edit strip, and
    /// calling `cut(_:)`/`copy(_:)`/`paste(_:)` directly still works.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        false
    }
}
