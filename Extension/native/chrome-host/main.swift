import Foundation

// Chrome's side of "Save to Evening Reader": a native messaging host.
//
// Chrome starts it for each message the extension sends, writes that one message to its
// standard input, reads one reply from its standard output, and lets it exit. Each is
// framed as a 32-bit length in native byte order followed by that many bytes of JSON.
// Anything on standard error goes to Chrome's log, not to the extension.

let input = FileHandle.standardInput
let output = FileHandle.standardOutput

func readMessage() -> [String: Any]? {
    guard let header = try? input.read(upToCount: 4), header.count == 4 else { return nil }
    let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    // Chrome sends at most 64 MB; an article with its Markdown is a fraction of that.
    guard length > 0, length <= 64 << 20 else { return nil }
    // A pipe hands a large message over in pieces.
    var body = Data()
    while body.count < Int(length) {
        guard let piece = try? input.read(upToCount: Int(length) - body.count), !piece.isEmpty else { return nil }
        body.append(piece)
    }
    return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
}

func send(_ reply: [String: Any]) {
    guard let body = try? JSONSerialization.data(withJSONObject: reply) else { return }
    var length = UInt32(body.count)
    output.write(Data(bytes: &length, count: 4))
    output.write(body)
}

guard let message = readMessage() else {
    FileHandle.standardError.write(Data("evening-reader-host: no message\n".utf8))
    exit(1)
}
send(await LibraryDrop.handle(message))
