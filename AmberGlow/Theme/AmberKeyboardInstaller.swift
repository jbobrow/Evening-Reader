import SwiftUI
import UIKit

/// Builds and holds the panel's keyboard for one field.
///
/// Shared by the single-line field and the multiline note editor. The board is the same
/// either way — the same keys, the same ramp, the same self-drawn container — and the
/// only thing that differs is who the keys are sent to, which is what `onKey` is for.
/// It is set after the board exists, because the board is built before there is anyone
/// to hand a key to.
@MainActor
final class AmberKeyboardInstaller {
    /// What UIKit is handed as the field's `inputView`.
    let container: AmberInputContainer

    /// Where the keys go. Set by whoever owns the field.
    var onKey: (AmberKey) -> Void = { _ in }

    struct Style: Equatable {
        var palette = AmberPalette()
        var showsTexture = true
        var showsDotCom = false
        var goLabel = "Go"
    }

    private let host: UIHostingController<AmberKeyboard>
    /// The board's width, as UIKit lays it out. The keys are sized from it.
    private var boardWidth: CGFloat = 0
    private var style = Style()

    private static let height: CGFloat = 330

    init() {
        host = UIHostingController(rootView: AmberKeyboard(palette: AmberPalette(),
                                                           showsTexture: true,
                                                           showsDotCom: false,
                                                           goLabel: "Go",
                                                           boardWidth: 0,
                                                           onKey: { _ in }))
        host.view.backgroundColor = .clear
        host.sizingOptions = []

        // The app supplies the container too. Left to itself the input view paints a
        // light system backdrop, which shows as a pale band above and below the keys and
        // around the home indicator — the one place a second colour could still get in.
        // `.default` style means no system material, just our fill.
        container = AmberInputContainer(
            frame: CGRect(x: 0, y: 0, width: 0, height: Self.height),
            inputViewStyle: .default
        )
        container.backgroundColor = UIColor(style.palette.color(0.80))
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

        container.onWidthChange = { [weak self] width in
            guard let self, boardWidth != width else { return }
            boardWidth = width
            render()
        }
        render()
    }

    /// The palette can change while a field is up, so the board is re-rendered rather
    /// than rebuilt — rebuilding would drop the shift and plane state.
    func apply(_ style: Style) {
        guard style != self.style else { return }
        self.style = style
        container.backgroundColor = UIColor(style.palette.color(0.80))
        render()
    }

    private func render() {
        host.rootView = AmberKeyboard(palette: style.palette,
                                      showsTexture: style.showsTexture,
                                      showsDotCom: style.showsDotCom,
                                      goLabel: style.goLabel,
                                      boardWidth: boardWidth) { [weak self] key in
            self?.onKey(key)
        }
    }
}
