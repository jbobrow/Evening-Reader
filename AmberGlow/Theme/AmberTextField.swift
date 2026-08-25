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
        private var host: UIHostingController<AmberKeyboard>?
        private var container: AmberInputContainer?
        /// The board's width, as UIKit lays it out. The keys are sized from it.
        private var boardWidth: CGFloat = 0

        init(_ parent: AmberTextField) { self.parent = parent }

        func installKeyboard(_ parent: AmberTextField, on field: UITextField) {
            let host = UIHostingController(rootView: keyboard(for: parent))
            host.view.backgroundColor = .clear
            host.sizingOptions = []
            self.host = host

            // The app supplies the container too. Left to itself the input view paints a
            // light system backdrop, which shows as a pale band above and below the keys
            // and around the home indicator — the one place a second colour could still
            // get in. `.default` style means no system material, just our fill.
            let container = AmberInputContainer(
                frame: CGRect(x: 0, y: 0, width: 0, height: Self.height),
                inputViewStyle: .default
            )
            container.onWidthChange = { [weak self] width in
                guard let self, self.boardWidth != width else { return }
                self.boardWidth = width
                self.host?.rootView = self.keyboard(for: self.parent)
            }
            container.backgroundColor = UIColor(parent.palette.color(0.80))
            container.allowsSelfSizing = true
            container.translatesAutoresizingMaskIntoConstraints = true
            container.autoresizingMask = [.flexibleWidth]

            host.view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: container.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])

            self.container = container
            field.inputView = container
        }

        /// The palette can change while a field is up, so the keyboard is re-rendered
        /// rather than rebuilt — rebuilding would drop the shift and plane state.
        func refreshKeyboard(_ parent: AmberTextField) {
            host?.rootView = keyboard(for: parent)
            container?.backgroundColor = UIColor(parent.palette.color(0.80))
        }

        private static let height: CGFloat = 330

        private func keyboard(for parent: AmberTextField) -> AmberKeyboard {
            AmberKeyboard(palette: parent.palette,
                          showsTexture: parent.showsTexture,
                          showsDotCom: parent.showsDotCom,
                          goLabel: parent.goLabel,
                          boardWidth: boardWidth) { [weak self] key in
                self?.handle(key)
            }
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
            case .paste:
                field.paste(nil)
            case .shift, .plane:
                break   // handled inside the keyboard's own state
            }
        }

        @objc func editingChanged(_ field: UITextField) {
            parent.text = field.text ?? ""
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            if parent.isFocused { parent.isFocused = false }
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
