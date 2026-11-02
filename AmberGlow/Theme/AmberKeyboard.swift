import SwiftUI
import UIKit

/// The keys the panel's own keyboard can send.
enum AmberKey: Hashable {
    case char(String)
    case shift
    case backspace
    case plane(AmberKeyboard.Plane)
    case space
    case dotCom
    case go
    case hide
    /// Editing actions. These live on the keyboard because the system edit callout is
    /// suppressed in the app's own fields — it is presented in its own window in system
    /// chrome and cannot be given a colour.
    case selectAll
    case cut
    case copy
    /// Carries the text: the key is the system's own paste control (see
    /// `AmberPasteControl`), which hands the clipboard over itself rather than
    /// reporting a tap — that is what lets it be read without the system asking first.
    case paste(String)
    /// Hand this field to the system keyboard, whose bar is where Password AutoFill
    /// lives. Offered on web fields only.
    case autofill
    /// Words heard by the board's mic, settled and ready to type in — see
    /// `AmberDictation.insert`, which also spaces them off from the word before.
    case dictation(String)
}

/// A keyboard drawn by the app, on the app's ramp.
///
/// The system keyboard is rendered by another process and composited by the window
/// server, so no filter the app can apply will ever reach it — it stays stubbornly grey
/// and blue above an amber panel. A `UITextField` will however accept any view as its
/// `inputView`, which is a far smaller thing than a keyboard extension: no install, no
/// "Allow Full Access", no system-wide switch, and it only appears for this app's fields.
struct AmberKeyboard: View {
    enum Plane: Hashable { case letters, numbers, symbols }

    var palette: AmberPalette
    var showsTexture: Bool
    var showsDotCom: Bool
    var goLabel: String
    /// Whether to offer the way to the system keyboard for AutoFill. The app's own fields
    /// have nothing to fill; a login form on a web page does.
    var showsAutofill: Bool = false
    /// Width of the board, handed down from UIKit. The keyboard is a field's `inputView`,
    /// so it is not in the app's view tree and has no size class to read — and measuring
    /// itself from the inside feeds a layout change back into the layout being computed,
    /// which is enough to stop the input view being presented at all.
    var boardWidth: CGFloat
    var onKey: (AmberKey) -> Void

    @State private var plane: Plane = .letters
    @State private var shifted = false
    @State private var capsLocked = false
    /// The character the last key with accents typed, as it was typed — capital or not —
    /// so a hold on it offers its accents in the same case. Shift has let go by then.
    @State private var lastTyped: String?
    @State private var accents: AccentPopup?
    @StateObject private var dictation = AmberDictation()

    /// The board's own coordinate space, which the keys report their holds in and the
    /// accent popup is laid out in.
    static let space = "amberBoard"

    private var amber: AmberPalette { palette }

    // MARK: - Metrics

    /// Width available to a row of keys, once the board's own padding is taken off.
    private var rowWidth: CGFloat { max(0, boardWidth - 12) }

    /// What one letter key in the top row comes out at — ten of them and nine gaps.
    private var keyWidth: CGFloat { max(0, (rowWidth - 9 * gap) / 10) }

    private let gap: CGFloat = 6

    /// How tall the board stands, from the hairline at its top to the foot of the bottom
    /// row: the edit strip, four rows of keys, the gaps between them and the padding
    /// around them. The container is sized to this, so no slack is left to be shared out
    /// above and below the keys.
    static let height: CGFloat = 8 + 31 + 4 * keyHeight + 4 * 7 + 6
    static let keyHeight: CGFloat = 46

    /// Shift and backspace take whatever is left of the third row once its seven letters
    /// have kept the width the top row gave them, so a key is the same size wherever it
    /// sits. On a wide panel that would leave two enormous slabs, so they stop at 74.
    private var modifierWidth: CGFloat {
        guard keyWidth > 0 else { return 74 }
        return max(38, min(74, (rowWidth - 8 * gap - 7 * keyWidth) / 2))
    }

    /// True where the bottom row's fixed keys would not leave the space bar room to be
    /// a space bar — every phone in portrait.
    private var isNarrow: Bool { boardWidth > 0 && boardWidth < 500 }

    // MARK: - Layout

    private var rows: [[String]] {
        switch plane {
        case .letters:
            return [["q","w","e","r","t","y","u","i","o","p"],
                    ["a","s","d","f","g","h","j","k","l"],
                    ["z","x","c","v","b","n","m"]]
        case .numbers:
            return [["1","2","3","4","5","6","7","8","9","0"],
                    ["-","/",":",";","(",")","$","&","@","\""],
                    [".",",","?","!","'"]]
        case .symbols:
            return [["[","]","{","}","#","%","^","*","+","="],
                    ["_","\\","|","~","<",">","€","£","¥","•"],
                    [".",",","?","!","'"]]
        }
    }

    var body: some View {
        VStack(spacing: 7) {
            editStrip
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: gap) {
                    if index == 2 { leadingRowKey }
                    ForEach(row, id: \.self) { key in
                        AmberKeyCap(label: display(key), palette: amber,
                                    hold: hold(for: key)) {
                            lastTyped = display(key)
                            send(.char(display(key)))
                            if shifted && !capsLocked { shifted = false }
                        }
                    }
                    if index == 2 { backspaceKey }
                }
                .padding(.horizontal, index == 1 && plane == .letters ? 22 : 0)
            }
            bottomRow
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topLeading) {
            if let accents {
                AccentPopupView(popup: accents, palette: amber)
                    .offset(x: accents.frame.minX, y: accents.frame.minY)
                    .allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: Self.space)
        // Put away with the mic still open: there is no field left to type into.
        .onDisappear { dictation.cancel() }
        .background {
            ZStack {
                amber.color(0.80)
                if showsTexture { PixelGrid(opacity: 0.05) }
                // A hairline where the keyboard meets the page, so it reads as a
                // separate plane without introducing a second background colour.
                VStack { amber.color(0.60, opacity: 0.5).frame(height: 1); Spacer() }
            }
            .ignoresSafeArea()
        }
    }

    /// Every key goes out through here. A key pressed while the mic is open types what
    /// has been heard first, so the words land before the key and not after it.
    private func send(_ key: AmberKey) {
        switch key {
        case .shift, .plane: break
        default: dictation.commitNow()
        }
        onKey(key)
    }

    /// Where Select All / Cut / Copy / Paste live, in place of the grey shortcuts bar —
    /// and where the mic is, which turns the strip into what it is hearing.
    private var editStrip: some View {
        Group {
            if dictation.isActive {
                listeningStrip
            } else if case .refused(let reason) = dictation.state {
                Text(reason)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(amber.inkMuted)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
            } else {
                HStack(spacing: gap) {
                    stripKey("Select All", .selectAll)
                    stripKey("Cut", .cut)
                    stripKey("Copy", .copy)
                    pasteKey
                    if showsAutofill {
                        stripKey("AutoFill", symbol: "key.fill", .autofill)
                    }
                    if AmberDictation.isOffered {
                        micKey
                    }
                }
            }
        }
        .padding(.bottom, 1)
    }

    private var micKey: some View {
        Button {
            dictation.start { send(.dictation($0)) }
        } label: {
            Image(systemName: "mic")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(amber.ink)
                .frame(width: 44, height: 30)
                .background { stripKeyFace }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dictate")
    }

    /// The strip while the mic is open: what has been heard so far, newest words kept in
    /// view, and the way to stop. Stopping types it in.
    private var listeningStrip: some View {
        HStack(spacing: gap) {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(amber.color(0.92))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(amber.color(0.30)))
                    .symbolEffect(.pulse, isActive: dictation.state == .listening)
                Text(dictation.transcript.isEmpty
                     ? (dictation.state == .starting ? "Starting…" : "Listening…")
                     : dictation.transcript)
                    .font(.system(size: 13.5, weight: dictation.transcript.isEmpty ? .medium : .regular))
                    .foregroundStyle(dictation.transcript.isEmpty ? amber.inkMuted : amber.ink)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 2)
            .padding(.trailing, 8)
            .frame(height: 30)
            .background { stripKeyFace }

            Button { dictation.stop() } label: {
                Text("Done")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(amber.color(0.92))
                    .frame(width: 64, height: 30)
                    .background {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(amber.color(0.30))
                    }
            }
            .buttonStyle(.plain)
            .disabled(dictation.state == .finishing)
            .opacity(dictation.state == .finishing ? 0.6 : 1)
        }
    }

    private func stripKey(_ label: String, symbol: String? = nil, _ key: AmberKey) -> some View {
        Button { send(key) } label: {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .medium))
                }
                Text(label)
                    .font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(amber.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background { stripKeyFace }
        }
        .buttonStyle(.plain)
    }

    /// The Paste key is the system's control in the app's clothes: it is the one way to
    /// take the clipboard without the system putting up its own grey question first.
    private var pasteKey: some View {
        AmberPasteControl(palette: amber, fill: 0.86, fontSize: 12.5, cornerStyle: .medium) {
            send(.paste($0))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background { stripKeyFace }
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(amber.color(0.66, opacity: 0.4), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private var stripKeyFace: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(amber.color(0.86))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(amber.color(0.66, opacity: 0.4), lineWidth: 1)
            }
    }

    @ViewBuilder
    private var leadingRowKey: some View {
        if plane == .letters {
            AmberKeyCap(symbol: capsLocked ? "capslock.fill" : (shifted ? "shift.fill" : "shift"),
                        palette: amber, kind: .modifier, width: modifierWidth,
                        isActive: shifted || capsLocked) {
                if capsLocked { capsLocked = false; shifted = false }
                else if shifted { capsLocked = true }
                else { shifted = true }
                send(.shift)
            }
        } else {
            AmberKeyCap(label: plane == .numbers ? "#+=" : "123",
                        palette: amber, kind: .modifier, width: modifierWidth) {
                plane = plane == .numbers ? .symbols : .numbers
                send(.plane(plane))
            }
        }
    }

    private var backspaceKey: some View {
        AmberKeyCap(symbol: "delete.left", palette: amber, kind: .modifier,
                    width: modifierWidth, repeats: true) { send(.backspace) }
    }

    private var bottomRow: some View {
        // On a phone the fixed keys add up to more than the row has, and the space bar is
        // what gets squeezed out. The keys that stay step down, and the one that puts the
        // keyboard away goes entirely: on a phone it is the least earned key on the board,
        // since the Go key already finishes the field and a tap outside already dismisses
        // it. What it leaves behind goes to the space bar.
        HStack(spacing: gap) {
            AmberKeyCap(label: plane == .letters ? "123" : "ABC",
                        palette: amber, kind: .modifier, width: modifierWidth) {
                plane = plane == .letters ? .numbers : .letters
                send(.plane(plane))
            }
            if showsDotCom {
                AmberKeyCap(label: ".", palette: amber, kind: .modifier,
                            width: isNarrow ? keyWidth : 52) {
                    send(.char("."))
                }
            }
            AmberKeyCap(label: "space", palette: amber, kind: .space) { send(.space) }
            if showsDotCom {
                AmberKeyCap(label: ".com", palette: amber, kind: .modifier,
                            width: isNarrow ? 62 : 74) {
                    send(.dotCom)
                }
            }
            AmberKeyCap(label: goLabel, palette: amber, kind: .go,
                        width: isNarrow ? 72 : 92) { send(.go) }
            if !isNarrow {
                AmberKeyCap(symbol: "keyboard.chevron.compact.down",
                            palette: amber, kind: .modifier, width: 60) { send(.hide) }
            }
        }
    }

    private func display(_ key: String) -> String {
        guard plane == .letters, shifted || capsLocked else { return key }
        return key.uppercased()
    }

    // MARK: - Accents

    /// What a hold on a key offers, after the system keyboard's own English layout. The
    /// key has already typed its own character by the time the popup is up — keys go on
    /// touch down, so fast typing never comes out of order — and choosing one swaps it.
    private static let alternates: [String: [String]] = [
        "a": ["à", "á", "â", "ä", "æ", "ã", "å", "ā"],
        "c": ["ç", "ć", "č"],
        "e": ["è", "é", "ê", "ë", "ē", "ė", "ę"],
        "i": ["î", "ï", "í", "ī", "į", "ì"],
        "l": ["ł"],
        "n": ["ñ", "ń"],
        "o": ["ô", "ö", "ò", "ó", "œ", "ø", "ō", "õ"],
        "s": ["ß", "ś", "š"],
        "u": ["û", "ü", "ù", "ú", "ū"],
        "y": ["ÿ"],
        "z": ["ž", "ź", "ż"],
        "0": ["°"],
        "-": ["–", "—", "•"],
        "/": ["\\"],
        "$": ["€", "£", "¥", "¢", "₩", "₹", "₽"],
        "&": ["§"],
        "\"": ["“", "”", "„", "«", "»"],
        "'": ["‘", "’", "‚", "‹", "›"],
        ".": ["…"],
        "?": ["¿"],
        "!": ["¡"],
        "%": ["‰"]
    ]

    private static func alternates(for typed: String) -> [String] {
        let lower = typed.lowercased()
        guard let options = alternates[lower] else { return [] }
        guard typed != lower else { return options }
        // Capitals, where a letter has one of its own — ß does not.
        return options.compactMap { $0.uppercased().count == 1 ? $0.uppercased() : nil }
    }

    private func hold(for key: String) -> KeyHold? {
        guard Self.alternates[key] != nil else { return nil }
        return KeyHold(
            begin: { keyFrame in openAccents(over: keyFrame) },
            move: { point in
                guard var popup = accents else { return }
                popup.select(at: point)
                if popup.selected != accents?.selected { accents = popup }
            },
            end: {
                defer { accents = nil }
                guard let popup = accents, let index = popup.selected else { return }
                send(.backspace)
                send(.char(popup.options[index]))
                lastTyped = popup.options[index]
            }
        )
    }

    private func openAccents(over key: CGRect) {
        guard let typed = lastTyped else { return }
        var options = Self.alternates(for: typed)
        guard !options.isEmpty else { return }

        let inset: CGFloat = 4
        let cell = max(keyWidth, 30)
        let width = cell * CGFloat(options.count) + inset * 2
        let height: CGFloat = 46
        // Over the key, reading rightward from it — or leftward from it where the board
        // runs out, the way the system's popup turns at the right-hand keys.
        // Turned, it runs backwards too, so the likeliest accents stay nearest the finger.
        var x = key.minX - inset
        if x + width > boardWidth - 4 {
            x = key.maxX + inset - width
            options.reverse()
        }
        x = max(4, min(x, boardWidth - 4 - width))
        // The bottom tucks onto the key's top edge. Over the top row it sits on the edit
        // strip, which is what that strip's height leaves room for.
        let y = max(2, key.minY + 3 - height)

        var popup = AccentPopup(options: options,
                                frame: CGRect(x: x, y: y, width: width, height: height),
                                key: key, cell: cell, inset: inset)
        popup.select(at: CGPoint(x: key.midX, y: key.midY))
        accents = popup
    }
}

/// How a key that has a hold behaviour reports it, in the board's coordinate space.
struct KeyHold {
    var begin: (CGRect) -> Void
    var move: (CGPoint) -> Void
    var end: () -> Void
}

/// The row of accents shown over a held key.
struct AccentPopup: Equatable {
    var options: [String]
    var frame: CGRect
    /// The key it was opened over — drawing the finger well clear of it, downward, is
    /// how a choice is let go of.
    var key: CGRect
    var cell: CGFloat
    var inset: CGFloat
    var selected: Int?

    mutating func select(at point: CGPoint) {
        guard point.y < key.maxY + 36 else { selected = nil; return }
        let index = Int(((point.x - frame.minX - inset) / cell).rounded(.down))
        selected = min(max(index, 0), options.count - 1)
    }
}

private struct AccentPopupView: View {
    var popup: AccentPopup
    var palette: AmberPalette

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(popup.options.enumerated()), id: \.offset) { index, option in
                let chosen = index == popup.selected
                Text(option)
                    .font(.system(size: 21))
                    .foregroundStyle(chosen ? palette.color(0.92) : palette.inkStrong)
                    .frame(width: popup.cell, height: popup.frame.height - popup.inset * 2)
                    .background {
                        if chosen {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(palette.color(0.30))
                        }
                    }
            }
        }
        .padding(popup.inset)
        .frame(width: popup.frame.width, height: popup.frame.height)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(palette.color(0.95))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(palette.color(0.60, opacity: 0.6), lineWidth: 1)
                }
                .shadow(color: palette.color(0.2, opacity: 0.25), radius: 6, y: 2)
        }
    }
}

/// One key. Kinds differ only in where they sit on the ramp — never in hue.
struct AmberKeyCap: View {
    enum Kind { case letter, modifier, space, go }

    var label: String?
    var symbol: String?
    var palette: AmberPalette
    var kind: Kind = .letter
    var width: CGFloat?
    var isActive: Bool = false
    var repeats: Bool = false
    /// What a long press does, for keys with accents. The tap still happens on touch
    /// down; the hold comes after it.
    var hold: KeyHold?
    var action: () -> Void

    init(label: String, palette: AmberPalette, kind: Kind = .letter, width: CGFloat? = nil,
         isActive: Bool = false, repeats: Bool = false, hold: KeyHold? = nil,
         action: @escaping () -> Void) {
        self.label = label; self.symbol = nil; self.palette = palette; self.kind = kind
        self.width = width; self.isActive = isActive; self.repeats = repeats; self.hold = hold
        self.action = action
    }

    init(symbol: String, palette: AmberPalette, kind: Kind = .letter, width: CGFloat? = nil,
         isActive: Bool = false, repeats: Bool = false, action: @escaping () -> Void) {
        self.label = nil; self.symbol = symbol; self.palette = palette; self.kind = kind
        self.width = width; self.isActive = isActive; self.repeats = repeats; self.action = action
    }

    @State private var pressed = false
    @State private var repeater: Timer?
    @State private var holdTimer: Task<Void, Never>?
    @State private var holding = false
    /// Where the key sits on the board, for the popup a hold opens over it.
    @State private var frame: CGRect = .zero

    private var face: Double {
        if isActive { return 0.30 }
        switch kind {
        case .letter: return pressed ? 0.74 : 0.90
        case .modifier, .space: return pressed ? 0.70 : 0.84
        case .go: return pressed ? 0.22 : 0.30
        }
    }

    private var ink: Color {
        (kind == .go || isActive) ? palette.color(0.92) : palette.inkStrong
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(palette.color(face))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(palette.color(0.66, opacity: 0.45), lineWidth: 1)
                }
            if let label {
                Text(label)
                    .font(.system(size: label.count > 1 ? 14 : 21,
                                  weight: label.count > 1 ? .medium : .regular))
                    .foregroundStyle(ink)
            } else if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(ink)
            }
        }
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .frame(height: AmberKeyboard.keyHeight)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(AmberKeyboard.space))
        } action: { frame = $0 }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(AmberKeyboard.space))
                .onChanged { value in
                    guard !pressed else {
                        if holding { hold?.move(value.location) }
                        return
                    }
                    pressed = true
                    action()
                    if repeats { startRepeating() }
                    if let hold { startHolding(hold) }
                }
                .onEnded { _ in
                    pressed = false
                    stopRepeating()
                    holdTimer?.cancel()
                    holdTimer = nil
                    if holding {
                        holding = false
                        hold?.end()
                    }
                }
        )
        .onDisappear {
            stopRepeating()
            holdTimer?.cancel()
        }
    }

    private func startRepeating() {
        stopRepeating()
        // Hold to run on, the way a hardware key does.
        repeater = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { _ in
            let t = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { _ in
                MainActor.assumeIsolated { action() }
            }
            MainActor.assumeIsolated { repeater = t }
        }
    }

    private func startHolding(_ hold: KeyHold) {
        holdTimer?.cancel()
        holdTimer = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled, pressed else { return }
            holding = true
            hold.begin(frame)
        }
    }

    private func stopRepeating() {
        repeater?.invalidate()
        repeater = nil
    }
}

/// Carries the board's width out to the keyboard. UIKit is what decides how wide an
/// input view is, and it is the only party that knows — the keyboard lives in the
/// keyboard's window, not the app's, so a size class never reaches it.
final class AmberInputContainer: UIInputView {
    var onWidthChange: ((CGFloat) -> Void)?
    private var reported: CGFloat = 0
    /// The glass this board was last on, so it can be parked in the right place on it.
    private var screen: CGRect = .zero

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let window { screen = window.screen.bounds }
        invalidateIntrinsicContentSize()
    }

    /// How tall the board stands on the glass it is on: its keys, and below them the
    /// strip under the home indicator, which the keys keep clear of. Before it has a
    /// window, the app's is the best guess at the glass it is about to be on.
    static func height(in window: UIWindow?) -> CGFloat {
        let glass = window ?? UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        return AmberKeyboard.height + (glass?.safeAreaInsets.bottom ?? 0)
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.height(in: window))
    }

    /// Parked where the keyboard stands whenever the board is taken out of the
    /// hierarchy. UIKit animates an input view coming back from wherever it last was,
    /// and a board left at the origin comes back flying in from the top corner — which
    /// is what was seen after AutoFill, as the panel's keyboard returned behind the
    /// system's. Parked at the foot of the glass, it comes back from where it is going.
    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        guard superview == nil, screen.height > 0 else { return }
        let height = bounds.height > 0 ? bounds.height : Self.height(in: nil)
        frame = CGRect(x: 0, y: screen.height - height, width: screen.width, height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.width != reported else { return }
        reported = bounds.width
        onWidthChange?(bounds.width)
    }
}
