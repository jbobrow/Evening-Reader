import Foundation

/// Every Zhuyin reading the keyboard knows, and what each one can be written as.
///
/// Built by `Tools/zhuyin-lexicon.py` from McBopomofo's word list (MIT, see
/// McBopomofo-LICENSE.txt): one line per reading, readings in byte order, each
/// followed by its candidates in descending score —
///
///     ㄓㄨㄥ-ㄨㄣˊ<TAB>中文 -4.123<TAB>…
///
/// The file is mapped rather than read, and only an index of where each line starts
/// is built from it, so the six megabytes cost next to nothing until a line is
/// actually looked up. It lives in the app, not on a server: the board types offline
/// like everything else here.
final class ZhuyinLexicon: @unchecked Sendable {
    struct Entry: Equatable {
        var value: String
        var score: Double
    }

    static let shared = ZhuyinLexicon()

    private let data: Data
    /// Where each line starts. One more than there are lines, so the last line's end is known.
    private let starts: [Int]

    private init() {
        guard let url = Bundle.main.url(forResource: "ZhuyinLexicon", withExtension: "txt"),
              let data = try? Data(contentsOf: url, options: .alwaysMapped) else {
            self.data = Data()
            self.starts = [0]
            return
        }
        self.data = data
        var starts = [0]
        starts.reserveCapacity(140_000)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count,
                  let hit = memchr(base + offset, 0x0A, raw.count - offset) {
                offset = base.distance(to: UnsafeRawPointer(hit)) + 1
                starts.append(offset)
            }
        }
        if starts.last != data.count { starts.append(data.count) }
        self.starts = starts
    }

    var isEmpty: Bool { starts.count < 2 }

    /// Whether anything is read this way — how the keyboard decides a syllable is one.
    func contains(_ reading: String) -> Bool { line(for: reading) != nil }

    /// What a reading can be written as, likeliest first.
    func entries(for reading: String) -> [Entry] {
        guard let range = line(for: reading) else { return [] }
        let text = String(decoding: data[range], as: UTF8.self)
        var fields = text.split(separator: "\t")
        fields.removeFirst()
        return fields.compactMap { field in
            guard let space = field.lastIndex(of: " "),
                  let score = Double(field[field.index(after: space)...]) else { return nil }
            return Entry(value: String(field[..<space]), score: score)
        }
    }

    /// The likeliest way to write a reading.
    func top(for reading: String) -> Entry? {
        // Only the first field is wanted, so stop parsing there.
        guard let range = line(for: reading) else { return nil }
        let text = String(decoding: data[range], as: UTF8.self)
        let fields = text.split(separator: "\t", maxSplits: 2)
        guard fields.count > 1, let space = fields[1].lastIndex(of: " "),
              let score = Double(fields[1][fields[1].index(after: space)...]) else { return nil }
        return Entry(value: String(fields[1][..<space]), score: score)
    }

    /// The bytes of the line for this reading, without its newline — by binary search
    /// over the readings, which the file keeps in byte order.
    private func line(for reading: String) -> Range<Int>? {
        let key = Array(reading.utf8)
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Range<Int>? in
            var low = 0, high = starts.count - 2
            while low <= high {
                let mid = (low + high) / 2
                let start = starts[mid]
                var end = starts[mid + 1]
                if end > start, raw[end - 1] == 0x0A { end -= 1 }
                switch compare(key, raw, from: start, to: end) {
                case .orderedSame: return start..<end
                case .orderedAscending: high = mid - 1
                case .orderedDescending: low = mid + 1
                }
            }
            return nil
        }
    }

    /// The key against the reading at the head of a line, which runs up to its first tab.
    private func compare(_ key: [UInt8], _ raw: UnsafeRawBufferPointer,
                         from start: Int, to end: Int) -> ComparisonResult {
        var i = 0, j = start
        while true {
            let lineDone = j >= end || raw[j] == 0x09
            let keyDone = i >= key.count
            if keyDone && lineDone { return .orderedSame }
            if keyDone { return .orderedAscending }
            if lineDone { return .orderedDescending }
            if key[i] != raw[j] { return key[i] < raw[j] ? .orderedAscending : .orderedDescending }
            i += 1; j += 1
        }
    }
}
