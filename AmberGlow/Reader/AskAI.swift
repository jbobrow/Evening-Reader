import SwiftUI
import FoundationModels

/// Whether there is a model on this device to ask.
///
/// The framework is weak-linked and every use of it is gated: on anything before iOS 26,
/// or on a device without Apple Intelligence, this is simply false and the reader never
/// sees the option. Asked fresh each time rather than answered once at launch — the
/// reader can turn Apple Intelligence on in Settings, and the model can still be
/// downloading the first few times a page is opened.
@MainActor
enum AppleIntelligence {
    static var isAvailable: Bool {
        guard #available(iOS 26.0, *) else { return false }
        return SystemLanguageModel.default.availability == .available
    }

    /// Why not, when not. Only ever shown if availability changed between the callout
    /// being drawn and the sheet being opened.
    static var absence: String {
        guard #available(iOS 26.0, *) else {
            return "Asking about a passage needs iOS 26 or later."
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            return ""
        case .unavailable(.deviceNotEligible):
            return "This device doesn't run Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is turned off. Turn it on in Settings to ask about a passage."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still downloading its model. Try again in a little while."
        case .unavailable:
            return "Apple Intelligence isn't available right now."
        }
    }
}

/// One passage, and a conversation about it.
///
/// The session is kept for the life of the sheet, so a second question is asked in the
/// light of the first — "and why does that matter?" is a question about the answer, not
/// about the passage, and starting fresh each time would throw that away.
@available(iOS 26.0, *)
@MainActor
@Observable
final class PassageChat {
    /// What has been said, oldest first. A plain transcript rather than the session's,
    /// because what is drawn is the reader's question and the model's prose, and the
    /// session's own entries carry the instructions and the passage too.
    struct Turn: Identifiable {
        let id = UUID()
        var question: String
        var answer: String
    }

    private(set) var turns: [Turn] = []
    private(set) var isAnswering = false
    private(set) var problem: String?

    @ObservationIgnored private var session: LanguageModelSession?
    @ObservationIgnored private var work: Task<Void, Never>?

    /// The passage, and roughly how much of it the model is given. The on-device model
    /// has a small context, and a highlight of a paragraph or two is what this is for —
    /// a chapter handed over whole would spend the whole window on the prompt.
    private static let passageLimit = 1500

    func ask(_ question: String, about passage: String, from title: String) {
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty, !isAnswering else { return }

        let text = String(passage.prefix(Self.passageLimit))
        let session = session ?? LanguageModelSession(instructions: """
            You are answering a reader's questions about a passage from something they \
            are reading. Answer from the passage itself and from ordinary background \
            knowledge. Be concrete and brief — a few sentences, no preamble, no bullet \
            lists unless the answer really is a list. If the passage does not settle the \
            question, say what it does and does not say rather than guessing.

            The reading is titled "\(title)".

            The passage:
            \(text)
            """)
        self.session = session

        problem = nil
        let turn = Turn(question: asked, answer: "")
        turns.append(turn)
        isAnswering = true

        work = Task { [weak self] in
            do {
                // Each snapshot is the whole answer so far, not the next few words, so
                // the turn is replaced rather than appended to.
                for try await snapshot in session.streamResponse(to: asked) {
                    guard let self, !Task.isCancelled,
                          let i = self.turns.firstIndex(where: { $0.id == turn.id }) else { return }
                    self.turns[i].answer = snapshot.content
                }
            } catch is CancellationError {
                // Nothing to say: the reader closed the sheet.
            } catch {
                self?.fail(error)
            }
            self?.isAnswering = false
        }
    }

    func cancel() {
        work?.cancel()
        work = nil
        isAnswering = false
    }

    private func fail(_ error: Error) {
        // A half-written answer that stopped is worse than none: leave the question, drop
        // the fragment, and say what happened underneath it.
        if let last = turns.indices.last { turns[last].answer = "" }
        if let generation = error as? LanguageModelSession.GenerationError {
            switch generation {
            case .exceededContextWindowSize:
                problem = "That's more than the on-device model can hold at once. Try a shorter passage."
            case .guardrailViolation:
                problem = "Apple Intelligence declined to answer that one."
            case .assetsUnavailable:
                problem = "Apple Intelligence isn't ready yet on this device."
            default:
                problem = generation.localizedDescription
            }
        } else {
            problem = error.localizedDescription
        }
    }
}

/// Ask about the passage you just selected.
struct AskAISheet: View {
    @Environment(\.amber) private var amber
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    let passage: String
    let title: String

    private var isCompact: Bool { sizeClass == .compact }

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                AskAIBody(passage: passage, title: title)
            } else {
                unavailable
            }
        }
        // The surface and the status bar are the presentation's business — see
        // `AmberItemPresentation`. All this owes it is a size to be fitted to.
        .frame(maxWidth: isCompact ? .infinity : 460)
        .frame(maxHeight: isCompact ? .infinity : 560)
    }

    private var unavailable: some View {
        VStack(spacing: 12) {
            Text("Not available here")
                .font(.system(size: 18, weight: .semibold, design: .serif))
                .foregroundStyle(amber.inkStrong)
            Text(AppleIntelligence.absence)
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundStyle(amber.inkMuted)
            Button("Close") { dismiss() }
                .buttonStyle(AmberButtonStyle(kind: .outline, size: 14))
        }
        .padding(26)
    }
}

@available(iOS 26.0, *)
private struct AskAIBody: View {
    @Environment(\.amber) private var amber
    @Environment(\.dismiss) private var dismiss
    @Environment(DisplaySettings.self) private var settings
    @Environment(\.horizontalSizeClass) private var sizeClass

    let passage: String
    let title: String

    @State private var chat = PassageChat()
    @State private var question = ""
    @State private var focused = false

    private var isCompact: Bool { sizeClass == .compact }

    /// Openings, for the moment before the reader knows what they want to ask. Three,
    /// because a fourth would be a menu rather than a nudge.
    private let openings = ["Explain this simply",
                            "What's the context?",
                            "Why does this matter?"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    quotedPassage
                    if chat.turns.isEmpty {
                        suggestions
                    } else {
                        ForEach(chat.turns) { turn in
                            turnView(turn)
                        }
                    }
                    if let problem = chat.problem {
                        Text(problem)
                            .font(.system(size: 12.5))
                            .lineSpacing(2)
                            .foregroundStyle(amber.inkMuted)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            Hairline()
            askField
        }
        .onDisappear { chat.cancel() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ask about this")
                    .font(.system(size: 18, weight: .semibold, design: .serif))
                    .foregroundStyle(amber.inkStrong)
                Text("Answered on this device")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.5)
                    .foregroundStyle(amber.inkFaint)
            }
            Spacer()
            AmberIconButton(symbol: "xmark") { dismiss() }
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var quotedPassage: some View {
        Text(passage)
            .font(.system(size: 14, design: .serif))
            .lineSpacing(3)
            .lineLimit(6)
            .foregroundStyle(amber.inkMuted)
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                amber.color(0.62).frame(width: 3)
            }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(openings, id: \.self) { opening in
                Button(opening) { submit(opening) }
                    .buttonStyle(AmberButtonStyle(kind: .outline, size: 13))
            }
        }
    }

    @ViewBuilder
    private func turnView(_ turn: PassageChat.Turn) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(turn.question)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(amber.inkStrong)
            if turn.answer.isEmpty {
                AmberSpinner().padding(.vertical, 4)
            } else {
                Text(turn.answer)
                    .font(.system(size: 14.5, design: .serif))
                    .lineSpacing(3.5)
                    .foregroundStyle(amber.ink)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var askField: some View {
        HStack(spacing: 10) {
            AmberTextField(text: $question,
                           isFocused: $focused,
                           placeholder: "Ask a question",
                           palette: settings.palette,
                           showsTexture: settings.showTexture,
                           goLabel: "Ask",
                           fontSize: 15,
                           onSubmit: { submit(question) })
                .frame(height: 21)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(amber.color(0.80))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(amber.rule, lineWidth: 1))
                )

            if chat.isAnswering {
                Button("Stop") { chat.cancel() }
                    .buttonStyle(AmberButtonStyle(kind: .outline, size: 14))
            } else {
                Button("Ask") { submit(question) }
                    .buttonStyle(AmberButtonStyle(kind: .solid, size: 14))
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func submit(_ text: String) {
        chat.ask(text, about: passage, from: title)
        question = ""
        focused = false
    }
}
