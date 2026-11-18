import Foundation
import Combine

/// What is being typed in Zhuyin before it becomes text: the syllables finished so far,
/// the one still being spelt, and what they could be written as.
///
/// Nothing reaches the field until a candidate is chosen — the composition is shown in
/// the board's own strip instead of as marked text in the field, which is how it can
/// work the same in the app's fields and in a web page's, and stay on the ramp.
@MainActor
final class ZhuyinComposer: ObservableObject {
    /// A syllable that has its tone, as the lexicon spells it: `ㄓㄨㄥˋ`. First tone is
    /// no mark at all.
    @Published private(set) var syllables: [String] = []
    /// The syllable being spelt, slot by slot.
    @Published private(set) var pending = Syllable()
    /// The likeliest way to write the whole composition, then everything the leading
    /// syllables can be written as — longest stretch first.
    @Published private(set) var candidates: [Candidate] = []

    struct Candidate: Hashable {
        var value: String
        /// How many leading syllables choosing it uses up.
        var span: Int
    }

    struct Syllable: Equatable {
        var initial: Character?
        var medial: Character?
        var final: Character?

        var isEmpty: Bool { initial == nil && medial == nil && final == nil }
        var text: String { String([initial, medial, final].compactMap { $0 }) }
    }

    enum Kind: Int, Comparable {
        case initial, medial, final, tone
        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    static let initials = Set("ㄅㄆㄇㄈㄉㄊㄋㄌㄍㄎㄏㄐㄑㄒㄓㄔㄕㄖㄗㄘㄙ")
    static let medials = Set("ㄧㄨㄩ")
    static let finals = Set("ㄚㄛㄜㄝㄞㄟㄠㄡㄢㄣㄤㄥㄦ")
    static let tones = Set("ˊˇˋ˙")

    static func kind(of symbol: Character) -> Kind? {
        if initials.contains(symbol) { return .initial }
        if medials.contains(symbol) { return .medial }
        if finals.contains(symbol) { return .final }
        if tones.contains(symbol) { return .tone }
        return nil
    }

    /// More than this and the leading words are let go of into the field, so the strip
    /// never has to hold a paragraph.
    private static let maxSyllables = 16
    /// The longest phrase looked for when building a sentence.
    private static let maxSpan = 8

    private let lexicon = ZhuyinLexicon.shared
    private let memory = ZhuyinMemory()

    var isComposing: Bool { !syllables.isEmpty || !pending.isEmpty }

    // MARK: - Typing

    /// A Zhuyin key. Returns text that has to go into the field now — the leading words,
    /// once the composition has grown past what the strip holds.
    @discardableResult
    func type(_ symbol: Character) -> String? {
        guard let kind = Self.kind(of: symbol) else { return nil }
        if kind == .tone {
            applyTone(symbol)
        } else {
            place(symbol, as: kind)
        }
        return overflow()
    }

    /// Space: first tone for a syllable being spelt. Returns the composition to type in
    /// when there is nothing being spelt — space chooses the likeliest sentence.
    func space() -> String? {
        if !pending.isEmpty {
            if lexicon.contains(pending.text) { closePending(tone: nil) }
            return overflow()
        }
        return commitAll()
    }

    /// Back one key: the slot last filled, or the tone of the last syllable.
    func backspace() {
        if pending.final != nil {
            pending.final = nil
        } else if pending.medial != nil {
            pending.medial = nil
        } else if pending.initial != nil {
            pending.initial = nil
        } else if let last = syllables.popLast() {
            // The tone goes first, so the syllable comes back to be spelt again. First
            // tone has no mark to take off, so its last letter goes instead.
            var toneless = last
            if let mark = toneless.last, Self.tones.contains(mark) {
                toneless.removeLast()
                pending = Self.syllable(from: toneless)
            } else {
                pending = Self.syllable(from: toneless)
                if pending.final != nil { pending.final = nil }
                else if pending.medial != nil { pending.medial = nil }
                else { pending.initial = nil }
            }
        }
        refresh()
    }

    /// Takes a candidate: its text goes into the field and the syllables it spells are
    /// let go of. What it was chosen over is remembered, so next time it comes first.
    func choose(_ candidate: Candidate) -> String {
        let span = min(candidate.span, syllables.count)
        if span > 0 {
            let reading = syllables[..<span].joined(separator: "-")
            // Choosing the sentence is choosing nothing in particular; only a word picked
            // from the list says something about this reader.
            if !(candidate == candidates.first && span == syllables.count) {
                memory.remember(candidate.value, for: reading)
            }
            syllables.removeFirst(span)
        }
        refresh()
        return candidate.value
    }

    /// Everything composed, as it would be written, ready to type in; the board is
    /// cleared. A syllable still being spelt with no tone yet goes in as its letters.
    func commitAll() -> String? {
        guard isComposing else { return nil }
        var text = syllables.isEmpty ? "" : bestSentence(syllables).joined()
        if !pending.isEmpty {
            if lexicon.contains(pending.text),
               let top = lexicon.top(for: pending.text) {
                text += memory.preferred(for: pending.text) ?? top.value
            } else {
                text += pending.text
            }
        }
        reset()
        return text
    }

    func reset() {
        syllables = []
        pending = Syllable()
        candidates = []
    }

    private func place(_ symbol: Character, as kind: Kind) {
        // A letter that belongs at or before a slot already filled starts the next
        // syllable — the last one is taken as first tone, if it is one. Otherwise it
        // takes that slot's place, which is how a wrong letter is corrected.
        let filled: [Kind] = [pending.initial.map { _ in .initial },
                              pending.medial.map { _ in .medial },
                              pending.final.map { _ in .final }].compactMap { $0 }
        if let latest = filled.max(), kind <= latest {
            if lexicon.contains(pending.text) {
                closePending(tone: nil)
            } else if kind < latest {
                // Spelt out of order and not yet a syllable: start again from here.
                pending = Syllable()
            }
        }
        switch kind {
        case .initial: pending.initial = symbol
        case .medial: pending.medial = symbol
        case .final: pending.final = symbol
        case .tone: break
        }
        refresh()
    }

    private func applyTone(_ tone: Character) {
        if !pending.isEmpty {
            let reading = pending.text + String(tone)
            if lexicon.contains(reading) { closePending(tone: tone) }
            return
        }
        // A tone on its own retones the last syllable, where that is a syllable too.
        guard let last = syllables.last else { return }
        var base = last
        if let mark = base.last, Self.tones.contains(mark) { base.removeLast() }
        let reading = base + String(tone)
        guard reading != last, lexicon.contains(reading) else { return }
        syllables[syllables.count - 1] = reading
        refresh()
    }

    private func closePending(tone: Character?) {
        syllables.append(pending.text + (tone.map(String.init) ?? ""))
        pending = Syllable()
        refresh()
    }

    /// Lets the leading words go once the composition is longer than the strip holds.
    private func overflow() -> String? {
        guard syllables.count > Self.maxSyllables else { return nil }
        let path = bestPath(syllables)
        guard let first = path.first else { return nil }
        syllables.removeFirst(first.span)
        refresh()
        return first.value
    }

    private static func syllable(from reading: String) -> Syllable {
        var s = Syllable()
        for c in reading {
            switch kind(of: c) {
            case .initial: s.initial = c
            case .medial: s.medial = c
            case .final: s.final = c
            default: break
            }
        }
        return s
    }

    // MARK: - Candidates

    private func refresh() {
        guard !syllables.isEmpty else { candidates = []; return }
        var list: [Candidate] = []
        var seen = Set<String>()
        func add(_ value: String, _ span: Int) {
            guard list.count < 400, seen.insert(value).inserted else { return }
            list.append(Candidate(value: value, span: span))
        }
        add(bestSentence(syllables).joined(), syllables.count)
        for span in stride(from: min(syllables.count, Self.maxSpan), through: 1, by: -1) {
            for value in values(for: syllables[..<span].joined(separator: "-")) {
                add(value, span)
            }
        }
        candidates = list
    }

    /// What a reading can be written as, with this reader's own choice first.
    private func values(for reading: String) -> [String] {
        var values = lexicon.entries(for: reading).map(\.value)
        if let preferred = memory.preferred(for: reading),
           let index = values.firstIndex(of: preferred) {
            values.remove(at: index)
            values.insert(preferred, at: 0)
        }
        return values
    }

    private func bestSentence(_ syllables: [String]) -> [String] {
        bestPath(syllables).map(\.value)
    }

    /// The likeliest way to split the syllables into words: each word scored by how
    /// often it turns up, and the split with the best total kept. A remembered choice
    /// counts as the likeliest for its reading.
    private func bestPath(_ syllables: [String]) -> [Candidate] {
        let n = syllables.count
        guard n > 0 else { return [] }
        var best = [Double](repeating: -.infinity, count: n + 1)
        var back = [(from: Int, value: String)?](repeating: nil, count: n + 1)
        best[0] = 0
        for end in 1...n {
            for start in max(0, end - Self.maxSpan)..<end where best[start] > -.infinity {
                let reading = syllables[start..<end].joined(separator: "-")
                guard let top = lexicon.top(for: reading) else { continue }
                var value = top.value
                var score = top.score
                if let preferred = memory.preferred(for: reading) {
                    value = preferred
                    // Nudged above the likeliest, so it wins where it would have tied.
                    score += 0.5
                }
                let total = best[start] + score
                if total > best[end] {
                    best[end] = total
                    back[end] = (start, value)
                }
            }
        }
        var path: [Candidate] = []
        var end = n
        while end > 0, let step = back[end] {
            path.append(Candidate(value: step.value, span: end - step.from))
            end = step.from
        }
        return path.reversed()
    }
}

/// The words this reader has picked over the likeliest, by reading — so 試用 they chose
/// once comes before 是用 from then on. Kept on the device, and only the last few
/// hundred.
@MainActor
final class ZhuyinMemory {
    private static let key = "zhuyin.chosen"
    private static let limit = 600

    private var chosen: [String: String]
    private var order: [String]

    init() {
        let stored = UserDefaults.standard.array(forKey: Self.key) as? [[String]] ?? []
        order = stored.compactMap { $0.count == 2 ? $0[0] : nil }
        chosen = Dictionary(stored.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil },
                            uniquingKeysWith: { _, last in last })
    }

    func preferred(for reading: String) -> String? { chosen[reading] }

    func remember(_ value: String, for reading: String) {
        guard chosen[reading] != value else { return }
        // Picking what would have come first anyway needs no remembering, unless it
        // is being picked over an older choice — then that is what is remembered.
        if chosen[reading] == nil,
           ZhuyinLexicon.shared.top(for: reading)?.value == value { return }
        chosen[reading] = value
        order.removeAll { $0 == reading }
        order.append(reading)
        if order.count > Self.limit {
            let dropped = order.removeFirst()
            chosen[dropped] = nil
        }
        UserDefaults.standard.set(order.compactMap { r in chosen[r].map { [r, $0] } },
                                  forKey: Self.key)
    }
}
