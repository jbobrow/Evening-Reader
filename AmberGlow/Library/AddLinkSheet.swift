import SwiftUI

/// Sizes a sheet to its content instead of to the platform's default card. Without this
/// the panel floats in the middle of a much larger sheet, which reads as a second window.
struct FittedSheet: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.presentationSizing(.fitted)
        } else {
            content
        }
    }
}

/// How the add panel gets on screen.
///
/// On a wide panel it is a fitted card floating over the page. A phone cannot have that:
/// a sheet there is a card presentation, which brings the system's own furniture with it
/// — the page behind shrinks onto a black backdrop, and the status bar comes back over
/// the top. Both are colours the app does not own. Full screen has none of that, and the
/// app goes on painting every pixel.
struct AddLinkPresentation<Sheet: View>: ViewModifier {
    let isCompact: Bool
    @Binding var isPresented: Bool
    @ViewBuilder var sheet: () -> Sheet

    @Environment(Library.self) private var library
    @Environment(DisplaySettings.self) private var settings

    func body(content: Content) -> some View {
        if isCompact {
            content.fullScreenCover(isPresented: $isPresented) {
                sheet()
                    // See the matching note on BrowseScreen's fullScreenCover: on Mac,
                    // running the iPad build, this presentation path doesn't reliably
                    // inherit the window's environment.
                    .environment(library)
                    .environment(settings)
            }
        } else {
            content.sheet(isPresented: $isPresented) {
                sheet()
                    .environment(library)
                    .environment(settings)
                    .presentationBackground { GlowSurface(level: 0.9) }
                    .modifier(FittedSheet())
            }
        }
    }
}

struct AddLinkSheet: View {
    @Environment(\.amber) private var amber
    @Environment(\.dismiss) private var dismiss
    @Environment(Library.self) private var library
    @Environment(DisplaySettings.self) private var settings
    @Environment(\.horizontalSizeClass) private var sizeClass

    let onAdd: (URL) -> Void

    @State private var text = ""
    @State private var problem: String?
    @State private var focused = false

    private var isCompact: Bool { sizeClass == .compact }

    /// A card on a wide panel, the whole glass on a phone — where 460pt is wider than
    /// the screen and a fixed width would hang off both edges.
    var body: some View {
        if isCompact {
            VStack(spacing: 0) {
                form
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GlowSurface(level: 0.9))
            .statusBarHidden(true)
        } else {
            form.frame(width: 460)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: isCompact ? 16 : 18) {
            HStack {
                Text("Add a link")
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                    .foregroundStyle(amber.inkStrong)
                Spacer()
                AmberIconButton(symbol: "xmark") { dismiss() }
            }

            VStack(alignment: .leading, spacing: 8) {
                AmberCaption(text: "Web address")
                AmberTextField(text: $text,
                               isFocused: $focused,
                               placeholder: "example.com/article",
                               palette: settings.palette,
                               showsTexture: settings.showTexture,
                               showsDotCom: true,
                               goLabel: "Save",
                               monospaced: true,
                               onSubmit: commit)
                    .frame(height: 22)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(amber.color(0.80))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(amber.rule, lineWidth: 1))
                    )
                if let problem {
                    Text(problem)
                        .font(.system(size: 12))
                        .foregroundStyle(amber.inkMuted)
                }
            }

            HStack(spacing: 10) {
                if library.clipboardMayHoldLink {
                    Button("Paste") {
                        if let url = UIPasteboard.general.url { text = url.absoluteString }
                        else if let s = UIPasteboard.general.string { text = s }
                    }
                    .buttonStyle(AmberButtonStyle(kind: .outline))
                }
                Spacer()
                Button("Save & read", action: commit)
                    .buttonStyle(AmberButtonStyle(kind: .solid))
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Hairline()

            VStack(alignment: .leading, spacing: 8) {
                AmberCaption(text: "Bringing in Safari's Reading List")
                Text("iOS keeps the Reading List private to Safari, so it can't be imported directly. In Safari, open a saved page, tap Share, and choose **Save to Amber Glow** — the article lands in this library, stripped down and lit.")
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .foregroundStyle(amber.inkMuted)
                if !library.usesAppGroup {
                    Text("Note: the shared app group isn't available in this build, so the share extension can't hand items over yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(amber.inkFaint)
                }
            }
        }
        .padding(isCompact ? 22 : 26)
        .onAppear { focused = true }
    }

    private func commit() {
        guard let url = BrowserModel.url(from: text) else {
            problem = "That doesn't look like a web address."
            return
        }
        onAdd(url)
        dismiss()
    }
}
