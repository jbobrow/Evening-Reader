import SwiftUI
import UIKit

/// A text field that brings the panel's own keyboard up instead of the system one.
///
/// Everything visible in this app is drawn from `AmberPalette`; the system keyboard is
/// the one surface that cannot be, since it is rendered out of process. Handing the
/// field an `inputView` replaces it for this field only, with a view the app draws.
struct AmberTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool

    var placeholder: String
    var palette: AmberPalette
    var showsTexture: Bool
    /// URL fields get `.com` and a dot key; a search field does not.
    var showsDotCom: Bool = false
    var goLabel: String = "Go"
    var monospaced: Bool = false
    var fontSize: CGFloat = 16
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// A field taken down while it still has the keyboard would take the keyboard with
    /// it in one step. Letting go first gives it its usual way down.
    static func dismantleUIView(_ view: UITextField, coordinator: Coordinator) {
        if view.isFirstResponder { view.resignFirstResponder() }
    }

    func makeUIView(context: Context) -> UITextField {
        let field = AmberInputTextField()
        field.delegate = context.coordinator
        field.borderStyle = .none
        field.backgroundColor = .clear
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.clearButtonMode = .never
        // Stop the system offering saved logins for what is only ever a URL or a query.
        field.textContentType = .none
        // A UITextField's intrinsic width follows its text, and a long URL will happily
        // push the rest of a toolbar off the screen. Let the layout decide the width.
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)),
                        for: .editingChanged)
        context.coordinator.field = field
        context.coordinator.installKeyboard(self, on: field)
        Self.removeEditMenu(from: field)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
        apply(style: field)
        Self.removeEditMenu(from: field)
        context.coordinator.refreshKeyboard(self)

        // Drive first-responder from the binding, but never fight the user for it.
        DispatchQueue.main.async {
            if isFocused, !field.isFirstResponder { field.becomeFirstResponder() }
            if !isFocused, field.isFirstResponder { field.resignFirstResponder() }
        }
    }

    /// `canPerformAction` alone does not see off the callout here: on iOS 16+ a
    /// `UITextField` also carries a `UIEditMenuInteraction`, and AutoFill is contributed
    /// through that rather than through the responder chain. Taking the interaction off
    /// is what actually removes it — the same move that worked for `WKWebView`.
    static func removeEditMenu(from field: UITextField) {
        for interaction in field.interactions where interaction is UIEditMenuInteraction {
            field.removeInteraction(interaction)
        }
    }

    private func apply(style field: UITextField) {
        let font: UIFont = monospaced
            ? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            : .systemFont(ofSize: fontSize)
        field.font = font
        field.textColor = UIColor(palette.ink)
        field.tintColor = UIColor(palette.inkStrong)
        field.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: UIColor(palette.inkFaint), .font: font]
        )
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: AmberTextField
        weak var field: UITextField?
        private let board = AmberKeyboardInstaller()
        /// The callout over a selection, drawn by the app since the system's is refused.
        private let callout = FieldCallout()

        init(_ parent: AmberTextField) { self.parent = parent }

        deinit {
            let callout = self.callout
            Task { @MainActor in callout.hide() }
        }

        func installKeyboard(_ parent: AmberTextField, on field: UITextField) {
            board.onKey = { [weak self] key in self?.handle(key) }
            refreshKeyboard(parent)
            field.inputView = board.container
        }

        func refreshKeyboard(_ parent: AmberTextField) {
            board.apply(AmberKeyboardInstaller.Style(palette: parent.palette,
                                                     showsTexture: parent.showsTexture,
                                                     showsDotCom: parent.showsDotCom,
                                                     goLabel: parent.goLabel))
        }

        private func handle(_ key: AmberKey) {
            guard let field else { return }
            switch key {
            case .char(let s):
                field.insertText(s)
            case .space:
                field.insertText(" ")
            case .dotCom:
                field.insertText(".com")
            case .backspace:
                field.deleteBackward()
            case .go:
                field.resignFirstResponder()
                parent.isFocused = false
                parent.onSubmit()
            case .hide:
                field.resignFirstResponder()
                parent.isFocused = false
            case .selectAll:
                field.selectAll(nil)
            case .cut:
                field.cut(nil)
            case .copy:
                field.copy(nil)
                CopiedFlash.show(in: board.container,
                                 center: CGPoint(x: board.container.bounds.midX, y: 23),
                                 palette: parent.palette)
            case .paste(let text):
                // Over the selection, or at the caret — what the field's own paste does.
                field.insertText(text)
            case .autofill, .shift, .plane:
                break   // handled inside the keyboard's own state
            }
        }

        /// The callout's actions. Cut and copy come off the callout, so it is taken down
        /// with them; paste arrives with its text.
        private func performFromCallout(_ action: EditAction) {
            guard let field else { return }
            switch action {
            case .cut: field.cut(nil)
            case .copy: field.copy(nil)
            default: break
            }
            callout.hide()
        }

        private func showCallout(for field: UITextField) {
            callout.update(for: field, palette: parent.palette,
                           perform: { [weak self] in self?.performFromCallout($0) },
                           onPaste: { [weak self] text in
                               self?.field?.insertText(text)
                               self?.callout.hide()
                           })
        }

        @objc func editingChanged(_ field: UITextField) {
            parent.text = field.text ?? ""
            callout.hide()
        }

        func textFieldDidChangeSelection(_ textField: UITextField) {
            showCallout(for: textField)
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            if parent.isFocused { parent.isFocused = false }
            callout.hide()
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            parent.isFocused = false
            parent.onSubmit()
            return false
        }
    }
}

/// Suppresses the system chrome the app cannot paint: the assistant bar above the
/// keyboard, and the edit callout.
private final class AmberInputTextField: UITextField {
    override var inputAssistantItem: UITextInputAssistantItem {
        let item = super.inputAssistantItem
        item.leadingBarButtonGroups = []
        item.trailingBarButtonGroups = []
        return item
    }

    /// A `UITextField` — unlike a `WKWebView` — really does build its callout from the
    /// responder chain, so refusing every action is enough to keep it away. The actions
    /// themselves are not lost: they moved to the keyboard's edit strip, and calling
    /// `cut(_:)`/`copy(_:)`/`paste(_:)` directly still works.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        false
    }
}
