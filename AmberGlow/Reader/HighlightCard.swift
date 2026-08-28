import SwiftUI

/// One marked passage, and the note that says why.
///
/// Shown twice over: on the page, the moment a passage is marked and again whenever the
/// mark is tapped, and in the highlights list, where it is how a note is written after
/// the fact. The passage is already saved by the time this appears — closing it without
/// typing leaves a plain highlight rather than losing one.
struct HighlightCard: View {
    @Environment(\.amber) private var amber
    @Environment(DisplaySettings.self) private var settings

    let highlight: Highlight
    /// Where it came from, when that isn't obvious — the list shows this, the page
    /// does not.
    var source: String?
    /// Whether the passage is on the page behind this card.
    ///
    /// At the source it is, and the note can be written: the words that prompted it are
    /// a few lines away, under the scrim. In the library's list they are not — the
    /// passage is quoted out of a reading you are not in — and a note written there
    /// would be written about a fragment. So that card reads rather than writes, and the
    /// way to the note is the way back to the page it came off.
    var atSource: Bool = true
    /// Offered only where there is somewhere to go: from the list, not from the page the
    /// passage is already on.
    var onOpen: (() -> Void)?
    var onRemove: () -> Void
    var onClose: () -> Void
    /// Called as the note is typed, so nothing depends on the reader finding a save
    /// button before they put the phone down.
    var onNote: (String) -> Void = { _ in }

    @State private var note: String = ""
    @State private var focused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            ScrollView {
                Text(highlight.passage)
                    .font(.system(size: 15, design: .serif))
                    .lineSpacing(4)
                    .foregroundStyle(amber.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: 150)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 13)
            .overlay(alignment: .leading) { amber.color(0.62).frame(width: 3) }

            if atSource {
                VStack(alignment: .leading, spacing: 8) {
                    AmberCaption(text: "Note")
                    noteField
                }
            } else if highlight.hasNote {
                VStack(alignment: .leading, spacing: 7) {
                    AmberCaption(text: "Note")
                    Text(highlight.note ?? "")
                        .font(.system(size: 14))
                        .lineSpacing(3)
                        .foregroundStyle(amber.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack(spacing: 10) {
                Button("Remove", action: onRemove)
                    .buttonStyle(AmberButtonStyle(kind: .outline, size: 14))
                Spacer(minLength: 8)
                if let onOpen {
                    Button("Go to it", action: onOpen)
                        .buttonStyle(AmberButtonStyle(kind: .solid, size: 14))
                }
                if atSource {
                    Button("Done") { save(); onClose() }
                        .buttonStyle(AmberButtonStyle(kind: .solid, size: 14))
                }
            }
        }
        .padding(20)
        .frame(maxWidth: 420)
        .background {
            ZStack {
                amber.color(0.93)
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(amber.color(0.62, opacity: 0.5), lineWidth: 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: amber.color(0.0, opacity: 0.28), radius: 30, y: 10)
        // Set here rather than as a @State default: the card is reused for whichever
        // mark is tapped next, and a default is only ever applied once.
        .onChange(of: highlight.id, initial: true) { _, _ in
            note = highlight.note ?? ""
        }
        // The note saves itself a moment after the typing stops. `task(id:)` cancels the
        // previous wait on every keystroke, so a sentence is one write rather than forty
        // — which matters when every write is a file in a folder that syncs. The guard
        // is what keeps loading a note from immediately saving it back.
        .task(id: note) {
            guard atSource, note != (highlight.note ?? "") else { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            onNote(note)
        }
    }

    /// The wait above is cancelled when the card goes away, so leaving takes the note
    /// with it rather than trusting the timer to have fired.
    private func save() {
        guard atSource, note != (highlight.note ?? "") else { return }
        onNote(note)
    }

    /// A note runs to a sentence or two. It is set as a paragraph, wrapped and read
    /// whole, rather than as a line with an ellipsis where the rest of it went.
    private var noteField: some View {
        let editor = AmberTextView(text: $note,
                                   isFocused: $focused,
                                   placeholder: "Why this one?",
                                   palette: settings.palette,
                                   showsTexture: settings.showTexture,
                                   fontSize: 15,
                                   onSubmit: { focused = false })
        return editor
            .frame(height: editor.height)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(amber.color(0.80))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(amber.rule, lineWidth: 1))
            )
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Highlight")
                    .font(.system(size: 17, weight: .semibold, design: .serif))
                    .foregroundStyle(amber.inkStrong)
                if let source, !source.isEmpty {
                    Text(source)
                        .font(.system(size: 11, weight: .medium))
                        .tracking(0.4)
                        .lineLimit(1)
                        .foregroundStyle(amber.inkFaint)
                }
            }
            Spacer(minLength: 12)
            AmberIconButton(symbol: "xmark") { save(); onClose() }
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 10 }
        }
    }
}
