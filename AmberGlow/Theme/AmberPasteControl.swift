import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The system's paste button, on the ramp.
///
/// Reading the pasteboard from code — `UIPasteboard.general.string`, or `paste(_:)` sent to
/// a field — is what brings up the system's "would like to paste from" dialog, and that
/// dialog cannot be restyled or stood in for: it is the system asking on the reader's
/// behalf, not the app, and an amber dialog of our own in front of it would only be a
/// second question before the grey one. `UIPasteControl` is the one way round it. The tap
/// on the control *is* the permission, so the contents arrive without a question — and
/// its face (fill, ink, corners) is ours to set. What is not ours is the type: the label
/// is set by the system at the body size, so the control is drawn at that size and scaled
/// to the key it stands in.
struct AmberPasteControl: UIViewRepresentable {
    var palette: AmberPalette
    /// Where on the ramp the face sits.
    var fill: Double
    /// What the label should come out at. The system sets it at 14pt (the body size at
    /// the smallest content size, which is what the control is held to) and the whole
    /// control is scaled from there.
    var fontSize: CGFloat = 14
    var cornerStyle: UIButton.Configuration.CornerStyle = .medium
    var showsIcon = false
    var onPaste: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PasteControlHost {
        let host = PasteControlHost()
        host.sink.onPaste = { [weak coordinator = context.coordinator] text in
            coordinator?.onPaste(text)
        }
        apply(to: host)
        return host
    }

    func updateUIView(_ host: PasteControlHost, context: Context) {
        context.coordinator.onPaste = onPaste
        apply(to: host)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PasteControlHost, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 80, height: proposal.height ?? 32)
    }

    private func apply(to host: PasteControlHost) {
        let config = UIPasteControl.Configuration()
        config.baseBackgroundColor = UIColor(palette.color(fill))
        config.baseForegroundColor = UIColor(palette.ink)
        config.cornerStyle = cornerStyle
        config.displayMode = showsIcon ? .iconAndLabel : .labelOnly
        host.set(configuration: config, scale: fontSize / 14)
    }

    final class Coordinator {
        var onPaste: (String) -> Void = { _ in }
    }
}

/// Holds the control at the system's size and scales it to the space it is given.
final class PasteControlHost: UIView {
    let sink = PasteSink()
    private var control: UIPasteControl?
    private var scale: CGFloat = 1
    private var configuration: UIPasteControl.Configuration?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(configuration: UIPasteControl.Configuration, scale: CGFloat) {
        // The control takes its configuration once, at creation, so a change of palette
        // means a fresh one. The face is compared first so the usual update is free.
        if let existing = self.configuration,
           existing.baseBackgroundColor == configuration.baseBackgroundColor,
           existing.baseForegroundColor == configuration.baseForegroundColor,
           existing.cornerStyle == configuration.cornerStyle,
           existing.displayMode == configuration.displayMode,
           self.scale == scale, control != nil {
            return
        }
        self.configuration = configuration
        self.scale = scale
        control?.removeFromSuperview()
        let fresh = UIPasteControl(configuration: configuration)
        fresh.target = sink
        // The smallest content size holds the label at 14pt, which is the size the rest
        // of the app's callouts set their labels in — from there any other size is a
        // scale away.
        fresh.traitOverrides.preferredContentSizeCategory = .extraSmall
        addSubview(fresh)
        control = fresh
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let control, bounds.width > 0, bounds.height > 0 else { return }
        control.transform = .identity
        control.bounds = CGRect(x: 0, y: 0,
                                width: bounds.width / scale, height: bounds.height / scale)
        control.center = CGPoint(x: bounds.midX, y: bounds.midY)
        control.transform = CGAffineTransform(scaleX: scale, y: scale)
    }
}

/// Where a paste control delivers what it was given.
///
/// A `UIPasteControl` hands the pasteboard's items to a responder rather than returning
/// them, so this stands in as that responder: it accepts text and links, reads the text
/// out of whichever it is handed, and passes it on.
final class PasteSink: UIResponder {
    var onPaste: (String) -> Void = { _ in }

    override init() {
        super.init()
        let configuration = UIPasteConfiguration(forAccepting: NSString.self)
        configuration.addTypeIdentifiers(forAccepting: NSURL.self)
        pasteConfiguration = configuration
    }

    override func paste(itemProviders: [NSItemProvider]) {
        guard let provider = itemProviders.first else { return }
        let deliver: (String) -> Void = { [weak self] text in
            DispatchQueue.main.async { self?.onPaste(text) }
        }
        if provider.canLoadObject(ofClass: NSURL.self), !provider.canLoadObject(ofClass: NSString.self) {
            _ = provider.loadObject(ofClass: NSURL.self) { url, _ in
                if let url = url as? URL { deliver(url.absoluteString) }
            }
        } else {
            _ = provider.loadObject(ofClass: NSString.self) { string, _ in
                if let string = string as? String { deliver(string) }
                else if provider.canLoadObject(ofClass: NSURL.self) {
                    _ = provider.loadObject(ofClass: NSURL.self) { url, _ in
                        if let url = url as? URL { deliver(url.absoluteString) }
                    }
                }
            }
        }
    }
}

// MARK: - Callouts over the app's own fields

/// The edit callout over a `UITextField` or `UITextView` of the app's own.
///
/// The web views report their selection and the reader draws `AmberEditMenuOverlay` over
/// it in SwiftUI. A native field cannot be drawn over the same way: it is 18 points tall
/// inside a bar, and a callout has to stand clear of it, over whatever is around it. So
/// this puts the same menu into the window directly, above the selected run, and takes it
/// down again when the selection goes.
@MainActor
final class FieldCallout {
    private var host: UIHostingController<AnyView>?
    private var palette = AmberPalette()

    /// Show, move or hide the callout to match the field's current selection.
    func update(for input: UIView & UITextInput, palette: AmberPalette,
                perform: @escaping (EditAction) -> Void,
                onPaste: @escaping (String) -> Void) {
        self.palette = palette
        guard let window = input.window,
              let range = input.selectedTextRange, !range.isEmpty else { hide(); return }
        let rects = input.selectionRects(for: range).map(\.rect).filter { !$0.isEmpty }
        guard let first = rects.first else { hide(); return }
        let union = rects.dropFirst().reduce(first) { $0.union($1) }
        let anchor = input.convert(union, to: window)

        var actions: [EditAction] = [.cut, .copy]
        if UIPasteboard.general.hasStrings { actions.append(.paste) }

        let margin: CGFloat = 8, gap: CGFloat = 10
        let height = EditAction.height
        let width = min(EditAction.width(of: actions), max(140, window.bounds.width - margin * 2))
        let above = anchor.minY - height - gap
        let y = above > margin ? above : min(anchor.maxY + gap, window.bounds.height - height - margin)
        let x = min(max(anchor.midX - width / 2, margin),
                    max(margin, window.bounds.width - width - margin))
        let frame = CGRect(x: x, y: y, width: width, height: height)

        let menu = AmberEditMenu(actions: actions, width: width, perform: { [weak self] action in
            if action == .copy, let self { CopiedFlash.show(over: frame, in: window, palette: self.palette) }
            perform(action)
        }, onPaste: onPaste)
            .environment(\.amber, palette)

        if let host {
            host.rootView = AnyView(menu)
            host.view.frame = frame
            if host.view.window !== window {
                host.view.removeFromSuperview()
                window.addSubview(host.view)
            }
        } else {
            let host = UIHostingController(rootView: AnyView(menu))
            host.view.backgroundColor = .clear
            host.view.frame = frame
            host.view.alpha = 0
            window.addSubview(host.view)
            self.host = host
            UIView.animate(withDuration: 0.14) { host.view.alpha = 1 }
        }
    }

    func hide() {
        guard let host else { return }
        self.host = nil
        UIView.animate(withDuration: 0.12, animations: { host.view.alpha = 0 }) { _ in
            host.view.removeFromSuperview()
        }
    }
}

/// A word that the copy happened.
///
/// The system's callout says so by going away; with the selection often left standing
/// under it, that is a quiet signal, and from the keyboard's own Copy key there is no
/// callout to go away at all. So the app says it outright — a small capsule where the
/// callout was, or over the key, gone again in under a second.
@MainActor
enum CopiedFlash {
    /// Over a rectangle in a window's coordinates — where a callout stood.
    static func show(over frame: CGRect, in window: UIView?, palette: AmberPalette, text: String = "Copied") {
        guard let window else { return }
        show(in: window, center: CGPoint(x: frame.midX, y: frame.midY), palette: palette, text: text)
    }

    /// Centred on a point in the given view.
    static func show(in view: UIView, center: CGPoint, palette: AmberPalette, text: String = "Copied") {
        let host = UIHostingController(rootView: Pill(text: text).environment(\.amber, palette))
        host.view.backgroundColor = .clear
        let size = host.sizeThatFits(in: CGSize(width: 240, height: 80))
        var origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        origin.x = min(max(origin.x, 8), max(8, view.bounds.width - size.width - 8))
        origin.y = min(max(origin.y, 8), max(8, view.bounds.height - size.height - 8))
        host.view.frame = CGRect(origin: origin, size: size)
        host.view.alpha = 0
        host.view.isUserInteractionEnabled = false
        host.view.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        view.addSubview(host.view)
        UIView.animate(withDuration: 0.14, delay: 0, options: .curveEaseOut) {
            host.view.alpha = 1
            host.view.transform = .identity
        }
        UIView.animate(withDuration: 0.28, delay: 0.85, options: .curveEaseIn) {
            host.view.alpha = 0
        } completion: { _ in
            host.view.removeFromSuperview()
        }
    }

    private struct Pill: View {
        @Environment(\.amber) private var amber
        let text: String

        var body: some View {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                Text(text)
                    .font(Font(EditAction.labelFont))
            }
            .foregroundStyle(amber.ink)
            .padding(.horizontal, 14)
            .frame(height: EditAction.height)
            .background { Capsule().fill(amber.color(0.93)) }
            .overlay { Capsule().strokeBorder(amber.color(0.62, opacity: 0.5), lineWidth: 1) }
            .shadow(color: amber.color(0.0, opacity: 0.22), radius: 14, y: 4)
        }
    }
}
