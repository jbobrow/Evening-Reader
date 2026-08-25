import SwiftUI
import UIKit
import WebKit
import ObjectiveC

/// Puts the panel's keyboard behind text fields *inside* web pages.
///
/// An app's own `UITextField` will take any view as its `inputView`. The text fields in a
/// web page will not: they belong to `WKContentView`, a private view inside `WKWebView`
/// whose `inputView` is read-only. The way in is to build a subclass of it at runtime
/// that overrides `inputView`, and re-point the live instance at that subclass — the same
/// technique apps have long used to suppress WebKit's accessory bar. The properties being
/// overridden (`inputView`, `inputAccessoryView`) are public `UIResponder` surface; what
/// is private is the identity of the class being subclassed.
///
/// That makes this the one fragile thing in the app, so it is written to fail safe: if the
/// content view cannot be found or the subclass cannot be built, nothing is changed and
/// the system keyboard appears as it always did.
@MainActor
final class WebKeyboardBridge {
    static let shared = WebKeyboardBridge()
    private init() {}

    private weak var web: WKWebView?
    /// Held directly: once the class is swapped its name no longer matches the lookup.
    private weak var content: UIView?
    private var host: UIHostingController<AmberKeyboard>?
    private var container: UIInputView?
    private var attachedTo: ObjectIdentifier?

    /// Set false to leave web fields on the system keyboard.
    static var isEnabled = true

    private static let height: CGFloat = 330

    // MARK: - Attaching

    func attach(to web: WKWebView, palette: AmberPalette, showsTexture: Bool) {
        guard Self.isEnabled else { return }
        self.web = web

        buildKeyboardIfNeeded(palette: palette, showsTexture: showsTexture)
        refresh(palette: palette, showsTexture: showsTexture)

        guard let content = Self.installOverrides(on: web) else { return }
        let id = ObjectIdentifier(content)
        guard attachedTo != id else { return }
        attachedTo = id
        self.content = content
        content.reloadInputViews()
    }

    /// Re-points a web view's content view at our subclass. Separate from `attach`
    /// because the reader wants the edit-menu suppression without wanting a keyboard.
    /// Returns the content view, or nil if WebKit's internals did not look as expected —
    /// in which case nothing is modified and the system chrome appears as it always did.
    @discardableResult
    static func installOverrides(on web: WKWebView) -> UIView? {
        guard let content = contentView(of: web) else { return nil }
        if String(describing: type(of: content)).hasPrefix("AmberGlow_") { return content }
        guard let subclass = subclass(for: content) else { return nil }
        object_setClass(content, subclass)
        content.inputAssistantItem.leadingBarButtonGroups = []
        content.inputAssistantItem.trailingBarButtonGroups = []
        removeEditMenu(from: web)
        return content
    }

    func refresh(palette: AmberPalette, showsTexture: Bool) {
        host?.rootView = keyboard(palette: palette, showsTexture: showsTexture)
        container?.backgroundColor = UIColor(palette.color(0.80))
    }

    private func buildKeyboardIfNeeded(palette: AmberPalette, showsTexture: Bool) {
        guard host == nil else { return }
        let host = UIHostingController(rootView: keyboard(palette: palette, showsTexture: showsTexture))
        host.view.backgroundColor = .clear
        host.sizingOptions = []

        let container = UIInputView(frame: CGRect(x: 0, y: 0, width: 0, height: Self.height),
                                    inputViewStyle: .default)
        container.backgroundColor = UIColor(palette.color(0.80))
        container.allowsSelfSizing = true
        container.autoresizingMask = [.flexibleWidth]

        host.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: container.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        self.host = host
        self.container = container
    }

    private func keyboard(palette: AmberPalette, showsTexture: Bool) -> AmberKeyboard {
        AmberKeyboard(palette: palette,
                      showsTexture: showsTexture,
                      showsDotCom: false,
                      goLabel: "Go") { [weak self] key in
            self?.handle(key)
        }
    }

    /// The view the keyboard should be handed to UIKit as.
    static var inputView: UIView? { shared.container }

    // MARK: - Keys

    private func handle(_ key: AmberKey) {
        guard let web else { return }
        let target = content ?? Self.contentView(of: web)
        let input = target as? UIKeyInput
        switch key {
        case .char(let s): input?.insertText(s)
        case .space:       input?.insertText(" ")
        case .dotCom:      input?.insertText(".com")
        case .backspace:   input?.deleteBackward()
        case .go:          submitFocusedField(in: web)
        case .hide:        web.endEditing(true)
        case .selectAll:   (target as? UIResponder)?.perform(NSSelectorFromString("selectAll:"), with: nil)
        case .cut:         (target as? UIResponder)?.perform(NSSelectorFromString("cut:"), with: nil)
        case .copy:        (target as? UIResponder)?.perform(NSSelectorFromString("copy:"), with: nil)
        case .paste:       (target as? UIResponder)?.perform(NSSelectorFromString("paste:"), with: nil)
        case .shift, .plane: break
        }
    }

    /// A web field has no "return" the way a `UITextField` does — the page is listening
    /// for the key event, so send it one, then fall back to submitting the form.
    private func submitFocusedField(in web: WKWebView) {
        let js = """
        (function () {
          var el = document.activeElement;
          if (!el) return;
          ['keydown','keypress','keyup'].forEach(function (type) {
            el.dispatchEvent(new KeyboardEvent(type, {
              key: 'Enter', code: 'Enter', keyCode: 13, which: 13,
              bubbles: true, cancelable: true
            }));
          });
          var form = el.form || (el.closest ? el.closest('form') : null);
          if (form) { form.requestSubmit ? form.requestSubmit() : form.submit(); }
          el.blur();
        })();
        """
        web.evaluateJavaScript(js)
        web.endEditing(true)
    }

    // MARK: - Runtime plumbing

    /// Takes WebKit's edit callout off the content view.
    ///
    /// The callout cannot be restyled and, on iOS 16+, cannot be talked out of appearing
    /// through `canPerformAction` or the interaction's delegate — WebKit owns both. What
    /// it does hang off is a `UIEditMenuInteraction` on the content view, and both
    /// `interactions` and `removeInteraction(_:)` are ordinary public `UIView` API. The
    /// selection itself, and its handles, are drawn by WebKit separately and survive.
    static func removeEditMenu(from web: WKWebView) {
        guard let content = contentView(of: web) else { return }
        for interaction in content.interactions where interaction is UIEditMenuInteraction {
            content.removeInteraction(interaction)
        }
    }

    /// WebKit's own content view, which is what actually becomes first responder.
    private static func contentView(of web: WKWebView) -> UIView? {
        web.scrollView.subviews.first {
            // `contains` rather than `hasPrefix`: once the class has been swapped the
            // name carries our own prefix.
            let name = String(describing: type(of: $0))
            return name.contains("WKContentView") || name.contains("WKApplicationStateTrackingView")
        }
    }

    private static var built: [String: AnyClass] = [:]

    private static func subclass(for content: UIView) -> AnyClass? {
        let base: AnyClass = type(of: content)
        let name = "AmberGlow_" + NSStringFromClass(base)
        if let existing = built[name] { return existing }
        if let existing = NSClassFromString(name) {
            built[name] = existing
            return existing
        }
        guard let created = objc_allocateClassPair(base, name, 0) else { return nil }

        // inputView -> the app's keyboard.
        let inputSel = #selector(getter: UIView.inputView)
        let inputBlock: @convention(block) (AnyObject) -> UIView? = { _ in
            MainActor.assumeIsolated { WebKeyboardBridge.inputView }
        }
        if let method = class_getInstanceMethod(UIView.self, inputSel) {
            class_addMethod(created, inputSel,
                            imp_implementationWithBlock(inputBlock),
                            method_getTypeEncoding(method))
        }

        // inputAccessoryView -> nothing. WebKit's bar is system chrome we cannot paint.
        let accSel = #selector(getter: UIView.inputAccessoryView)
        let accBlock: @convention(block) (AnyObject) -> UIView? = { _ in nil }
        if let method = class_getInstanceMethod(UIView.self, accSel) {
            class_addMethod(created, accSel,
                            imp_implementationWithBlock(accBlock),
                            method_getTypeEncoding(method))
        }

        // inputAssistantItem -> emptied. On iPad the bar above the keyboard (undo, redo,
        // paste, the field-stepping chevrons) is the shortcuts bar, which is a different
        // thing from the accessory view and survives clearing that. It is fetched fresh
        // each time a field is focused, so the getter is wrapped rather than the value
        // being cleared once.
        let assistSel = #selector(getter: UIResponder.inputAssistantItem)
        if let method = class_getInstanceMethod(base, assistSel) {
            typealias Original = @convention(c) (AnyObject, Selector) -> UITextInputAssistantItem
            let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
            let block: @convention(block) (AnyObject) -> UITextInputAssistantItem = { obj in
                let item = original(obj, assistSel)
                item.leadingBarButtonGroups = []
                item.trailingBarButtonGroups = []
                return item
            }
            class_addMethod(created, assistSel,
                            imp_implementationWithBlock(block),
                            method_getTypeEncoding(method))
        }


        objc_registerClassPair(created)
        built[name] = created
        return created
    }
}
