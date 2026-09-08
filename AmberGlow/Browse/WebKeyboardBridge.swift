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
    private init() {
        keyboardObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.wantsSystemKeyboard,
                      Date().timeIntervalSince(self.loanStarted) > 0.5 else { return }
                // The loan ends the moment the keyboard is down, whatever took it
                // down — the reader letting the field go, or the password picker
                // coming up over it. Ended here, while nothing is showing, what comes
                // back is the panel's own board, presented fresh from the bottom.
                // Ended later, with the system keyboard up, it would have to be
                // swapped out in place, and UIKit draws that swap as the new board
                // flying in from the top corner — which was seen on the phone after
                // every pick from 1Password.
                self.endLoan()
                // Reloaded now, while hidden, and not left to the re-showing: UIKit
                // brings back the keyboard it last had without asking again, and
                // that was the system's — seen coming up, then swapped, after the
                // pick. With the field still the first responder the reload changes
                // what is waiting to come back, and shows nothing itself.
                if self.content?.isFirstResponder == true {
                    self.content?.reloadInputViews()
                }
            }
        }
    }

    /// The page says which field has the focus, which decides whether the AutoFill key
    /// is offered. A new field while the system keyboard is still up also ends the loan
    /// — the fallback, since the loan normally ends while the keyboard is down (see the
    /// hide observer), and a swap with a keyboard showing is the one UIKit animates.
    func focusedField(isLogin: Bool) {
        if focusedFieldIsLogin != isLogin {
            focusedFieldIsLogin = isLogin
            host?.rootView = keyboard(palette: palette, showsTexture: showsTexture)
        }
        if wantsSystemKeyboard {
            endLoan()
            swapKeyboard(on: content)
        }
    }

    /// Changes what the field shows without the change being drawn.
    ///
    /// UIKit animates a change of input view while the keyboard is up, and animates the
    /// incoming view from wherever it last was. For the panel's keyboard coming back
    /// from the loan that is nowhere in particular — it was taken out of the hierarchy
    /// with a frame at the origin — which reads as a board flying in from the top
    /// corner to settle behind the one on its way out. So it is put where it will end
    /// up first, and the swap is made with animation off.
    private func swapKeyboard(on target: UIView?) {
        if let container, container.superview == nil, let window = target?.window {
            // In the window's terms, since that is how a view with no superview is read:
            // at the foot of the glass, where the keyboard is.
            container.frame = CGRect(x: 0, y: window.bounds.height - Self.height,
                                     width: window.bounds.width, height: Self.height)
        }
        UIView.performWithoutAnimation { target?.reloadInputViews() }
    }

    private func endLoan() {
        wantsSystemKeyboard = false
        veil.hide()
    }

    private weak var web: WKWebView?
    /// Held directly: once the class is swapped its name no longer matches the lookup.
    private weak var content: UIView?
    private var host: UIHostingController<AmberKeyboard>?
    private var container: AmberInputContainer?
    private var attachedTo: ObjectIdentifier?
    /// What the keyboard is currently drawn with, so a width change can re-render it
    /// without the caller having to hand the palette over again.
    private var palette = AmberPalette()
    private var showsTexture = true
    /// The board's width, as UIKit lays it out. The keys are sized from it.
    private var boardWidth: CGFloat = 0

    /// Set false to leave web fields on the system keyboard.
    static var isEnabled = true

    /// True while the reader has asked for the system keyboard instead — for AutoFill.
    ///
    /// Password AutoFill, from the system's Passwords or from a manager like 1Password,
    /// is offered on the system keyboard's own bar, which is drawn out of process and
    /// cannot be reached from here; there is no API a browser can call to bring the
    /// picker up on its own. So the AutoFill key on the panel's keyboard steps aside
    /// for it: the field is handed the system keyboard, grey and all, for as long as it
    /// is up. Once the keyboard goes away the panel's own is back for the next field.
    private(set) var wantsSystemKeyboard = false
    /// When the loan began. The swap that starts it can post a hide of its own on the
    /// way to the system keyboard, which must not be taken for the keyboard going down.
    private var loanStarted = Date.distantPast
    /// Whether the field with the focus is one AutoFill has anything for. The key that
    /// steps aside is offered on those and nowhere else: on a search box it would only
    /// be a way to a grey keyboard.
    private var focusedFieldIsLogin = false
    /// What is drawn over the system keyboard while it is on loan.
    private let veil = KeyboardVeil()

    private static let height: CGFloat = 330

    private var keyboardObserver: NSObjectProtocol?

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
        // The content view in its dark dress, for good. The system keyboard takes its
        // light or dark look from the first responder's own traits — and that is the
        // content view, not the web view. Darkened alone it gets every system keyboard
        // that ever surfaces here, on loan for AutoFill or brought back by the system
        // after a password picker, in dark; the page, which reads the web view's
        // traits, goes on believing it is light. WebKit's own pickers for a page's
        // date and select fields come out dark for the same reason, which is no loss.
        content.overrideUserInterfaceStyle = .dark
        content.inputAssistantItem.leadingBarButtonGroups = []
        content.inputAssistantItem.trailingBarButtonGroups = []
        removeEditMenu(from: web)
        return content
    }

    func refresh(palette: AmberPalette, showsTexture: Bool) {
        self.palette = palette
        self.showsTexture = showsTexture
        host?.rootView = keyboard(palette: palette, showsTexture: showsTexture)
        container?.backgroundColor = UIColor(palette.color(0.80))
    }

    private func buildKeyboardIfNeeded(palette: AmberPalette, showsTexture: Bool) {
        guard host == nil else { return }
        let host = UIHostingController(rootView: keyboard(palette: palette, showsTexture: showsTexture))
        host.view.backgroundColor = .clear
        host.sizingOptions = []

        let container = AmberInputContainer(
            frame: CGRect(x: 0, y: 0, width: 0, height: Self.height),
            inputViewStyle: .default
        )
        container.onWidthChange = { [weak self] width in
            guard let self, self.boardWidth != width else { return }
            self.boardWidth = width
            self.host?.rootView = self.keyboard(palette: self.palette,
                                                showsTexture: self.showsTexture)
        }
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
                      goLabel: "Go",
                      showsAutofill: focusedFieldIsLogin,
                      boardWidth: boardWidth) { [weak self] key in
            self?.handle(key)
        }
    }

    /// The view the keyboard should be handed to UIKit as — or nothing, while the
    /// system's has been asked for.
    static var inputView: UIView? { shared.wantsSystemKeyboard ? nil : shared.container }

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
        case .selectAll:   target?.perform(NSSelectorFromString("selectAll:"), with: nil)
        case .cut:         target?.perform(NSSelectorFromString("cut:"), with: nil)
        case .copy:
            target?.perform(NSSelectorFromString("copy:"), with: nil)
            if let container {
                CopiedFlash.show(in: container, center: CGPoint(x: container.bounds.midX, y: 23),
                                 palette: palette)
            }
        case .paste(let text):
            // Typed in rather than sent as `paste:` — that would have the content view
            // read the pasteboard itself, and the system ask about it.
            input?.insertText(text)
        case .autofill:
            wantsSystemKeyboard = true
            loanStarted = Date()
            swapKeyboard(on: target)
            veil.show(over: web.window?.windowScene, palette: palette)
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

        // inputView -> the app's keyboard; or, while the system's has been asked for,
        // whatever WebKit would have offered.
        let inputSel = #selector(getter: UIView.inputView)
        if let method = class_getInstanceMethod(base, inputSel) {
            typealias Original = @convention(c) (AnyObject, Selector) -> UIView?
            let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
            let inputBlock: @convention(block) (AnyObject) -> UIView? = { obj in
                MainActor.assumeIsolated {
                    WebKeyboardBridge.shared.wantsSystemKeyboard
                        ? original(obj, inputSel)
                        : WebKeyboardBridge.inputView
                }
            }
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
                // Left as it comes while the system keyboard is on loan: the bar is
                // part of what was asked for.
                if MainActor.assumeIsolated({ WebKeyboardBridge.shared.wantsSystemKeyboard }) {
                    return item
                }
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

/// Puts down WebKit's own page indicator over a PDF — the blurred grey capsule that rises
/// in the corner while the document is scrolled and fades out after it.
///
/// It says what the app's own pill already says, a few points away from it and in another
/// language entirely. There is no API to decline it, so it is found by class name and
/// hidden, which is the same trade this file's keyboard makes: if WebKit renames or
/// restructures the view, nothing is found and nothing is touched. The indicator comes
/// back, which is untidy, and that is the whole of the damage.
///
/// Only the browser needs this now. A saved PDF is opened by `PDFReaderView`, which had
/// this and three other problems with being a web view and is one no longer — but a PDF
/// *browsed to* is still a page in a web view, and still grows the capsule.
@MainActor
final class SystemPageIndicator {
    private weak var view: UIView?
    /// When the hunt last ran, so a document that never has one is not searched on every
    /// frame of every scroll.
    private var lastSearch: CFTimeInterval = 0

    /// `isHidden` rather than removal — WebKit animates the thing's alpha to show and
    /// hide it, and a hidden view stays hidden through that. Called again on every scroll
    /// rather than once, since the view can be rebuilt underneath us.
    func hide(in web: WKWebView) {
        if let view {
            view.isHidden = true
            return
        }
        // WebKit builds the indicator lazily, so the first look usually finds nothing and
        // the search has to stay open. A budget of tries cannot do that: scroll events
        // spend it in a fraction of a second, long before there is anything to find, and
        // the indicator is then never taken down at all. Time bounds it instead — a walk
        // of a dozen views, four times a second at worst.
        let now = CACurrentMediaTime()
        guard now - lastSearch > 0.25 else { return }
        lastSearch = now
        guard let found = Self.find(in: web) else { return }
        view = found
        found.isHidden = true
    }

    private static func find(in view: UIView) -> UIView? {
        if isIndicator(view) { return view }
        for sub in view.subviews {
            if let found = find(in: sub) { return found }
        }
        return nil
    }

    /// The indicator has had more than one name, and matching one spelling of it is how
    /// this came to be hidden on the simulator and showing on the phone.
    ///
    /// Through iOS 18 it is PDFKit's `PDFPageLabelView`. On iOS 26 that class is still
    /// there, but WebKit puts up its own `WKPDFPageNumberIndicator` instead, so the old
    /// name matches nothing and the indicator stays. Both were read out of the two
    /// runtimes rather than guessed at.
    ///
    /// Matching the shape of the name rather than either spelling covers the two that
    /// exist and stands some chance against the next rename. It is still a name, and
    /// still fails the same safe way: nothing found, nothing touched.
    private static func isIndicator(_ view: UIView) -> Bool {
        let name = String(describing: type(of: view))
        guard name.contains("PDF") else { return false }
        return name.contains("PageLabel")
            || name.contains("PageNumber")
            || name.contains("PageIndicator")
    }
}

/// A pane of amber under the system keyboard, for the time it is on loan.
///
/// The keyboard is drawn by another process and no filter of the app's reaches it; nor
/// can a window of the app's get above it — whatever level it is given, the keyboard
/// stays on top. What the keyboard does do is let the ground show through: its material
/// blurs whatever lies beneath, and takes on the colour. So the pane goes *under* it,
/// over the app, exactly where the keyboard stands, and the keyboard comes out with the
/// warmth of the panel in its ground rather than the grey of nothing. Asked for in its
/// dark dress (see `.autofill`), that is a dark keyboard lit from below in amber.
@MainActor
final class KeyboardVeil {
    private var window: UIWindow?
    private let pane = UIView()
    private var observers: [NSObjectProtocol] = []
    /// Where the keyboard last was, in screen coordinates. Kept from the start rather
    /// than from the moment the veil is asked for: by then the keyboard has already
    /// announced itself, and there would be nothing to put the pane over.
    private var keyboardFrame: CGRect = .zero

    init() {
        observers = [UIResponder.keyboardWillChangeFrameNotification,
                     UIResponder.keyboardDidShowNotification,
                     UIResponder.keyboardWillHideNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.follow(note) }
            }
        }
    }

    func show(over scene: UIWindowScene?, palette: AmberPalette) {
        guard let scene else { return }
        if window == nil {
            let window = UIWindow(windowScene: scene)
            // Above the app's own windows, sheets included; the keyboard is above it
            // regardless, and is meant to be.
            window.windowLevel = .alert + 1
            window.backgroundColor = .clear
            window.isUserInteractionEnabled = false
            // A window of its own would otherwise bring the status bar back with it.
            window.rootViewController = VeilController()
            window.rootViewController?.view.backgroundColor = .clear
            window.rootViewController?.view.addSubview(pane)
            window.isHidden = false
            self.window = window
        }
        pane.backgroundColor = UIColor(palette.color(0.15)).withAlphaComponent(0.7)
        place()
    }

    func hide() {
        window?.isHidden = true
        window = nil
        pane.removeFromSuperview()
    }

    private func follow(_ note: Notification) {
        guard let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        else { return }
        keyboardFrame = note.name == UIResponder.keyboardWillHideNotification ? .zero : frame
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        UIView.animate(withDuration: duration) { self.place() }
    }

    private func place() {
        guard let window else { return }
        let local = window.convert(keyboardFrame, from: nil)
        pane.frame = local.intersection(window.bounds)
    }

    private final class VeilController: UIViewController {
        override var prefersStatusBarHidden: Bool { true }
        override var prefersHomeIndicatorAutoHidden: Bool { true }
    }
}
