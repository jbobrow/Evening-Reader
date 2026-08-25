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

struct AddLinkSheet: View {
    @Environment(\.amber) private var amber
    @Environment(\.dismiss) private var dismiss
    @Environment(Library.self) private var library
    @Environment(DisplaySettings.self) private var settings

    let onAdd: (URL) -> Void

    @State private var text = ""
    @State private var problem: String?
    @State private var focused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
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
                Text("iPadOS keeps the Reading List private to Safari, so it can't be imported directly. In Safari, open a saved page, tap Share, and choose **Save to Amber Glow** — the article lands in this library, stripped down and lit.")
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
        .padding(26)
        .frame(width: 460)
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
