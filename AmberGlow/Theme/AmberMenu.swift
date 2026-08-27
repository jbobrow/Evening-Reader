import SwiftUI

/// One row of an `AmberMenu`.
struct AmberMenuItem: Identifiable {
    let id = UUID()
    var title: String
    var symbol: String
    /// Destructive items sit lower on the ramp rather than turning red — the app has
    /// no second hue to spend on emphasis, so weight does the work colour usually would.
    var isDestructive = false
    var action: () -> Void
}

/// A context menu drawn by the app.
///
/// SwiftUI's `.contextMenu` and UIKit's `UIMenu` are presented in their own window with
/// system materials and no appearance API, so on an amber panel they arrive as a white
/// card. This is the same list, drawn from the ramp.
struct AmberMenu: View {
    @Environment(\.amber) private var amber

    let items: [AmberMenuItem]
    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0, item.isDestructive, !items[index - 1].isDestructive {
                    amber.color(0.62, opacity: 0.45)
                        .frame(height: 1)
                        .padding(.vertical, 4)
                }
                Button {
                    item.action()
                    dismiss()
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 13))
                            .frame(width: 18)
                        Text(item.title)
                            .font(.system(size: 14, weight: item.isDestructive ? .semibold : .regular))
                        Spacer(minLength: 12)
                    }
                    .foregroundStyle(item.isDestructive ? amber.inkStrong : amber.ink)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(AmberMenuRowStyle())
            }
        }
        .padding(.vertical, 5)
        .frame(width: 226)
        .background {
            ZStack {
                amber.color(0.93)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(amber.color(0.62, opacity: 0.5), lineWidth: 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: amber.color(0.0, opacity: 0.24), radius: 20, y: 6)
    }
}

private struct AmberMenuRowStyle: ButtonStyle {
    @Environment(\.amber) private var amber
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? amber.color(0.84) : .clear)
    }
}

/// A destructive confirmation, drawn by the app. `UIAlertController` cannot be themed
/// at all — not its background, not its buttons — so it is the one dialog that would
/// always arrive white.
struct AmberConfirm: View {
    @Environment(\.amber) private var amber

    var title: String
    var message: String
    var confirmTitle: String
    /// `nil` hides the second button entirely — for a plain acknowledgement (a book that
    /// can't be opened, say) rather than a choice between two actions.
    var cancelTitle: String? = "Keep"
    var confirm: () -> Void
    var cancel: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 19, weight: .semibold, design: .serif))
                .foregroundStyle(amber.inkStrong)

            if !message.isEmpty {
                Text(message)
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .lineLimit(5)
                    .foregroundStyle(amber.inkMuted)
            }

            HStack(spacing: 10) {
                Spacer()
                if let cancelTitle {
                    Button(cancelTitle, action: cancel)
                        .buttonStyle(AmberButtonStyle(kind: .outline, size: 14))
                }
                Button(confirmTitle, action: confirm)
                    .buttonStyle(AmberButtonStyle(kind: .solid, size: 14))
            }
            .padding(.top, 2)
        }
        .padding(22)
        // Wide enough to give the message a decent measure, but never wider than the
        // glass — on a phone the offered width is the whole screen.
        .frame(maxWidth: 380)
        .background {
            ZStack {
                amber.color(0.93)
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(amber.color(0.62, opacity: 0.5), lineWidth: 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: amber.color(0.0, opacity: 0.28), radius: 30, y: 10)
    }
}

/// Dims whatever is behind a menu or dialog, and closes it on a tap outside.
struct AmberScrim: View {
    @Environment(\.amber) private var amber
    var opacity: Double = 0.28
    var dismiss: () -> Void

    var body: some View {
        amber.color(0.02, opacity: opacity)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture(perform: dismiss)
    }
}
