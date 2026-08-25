import SwiftUI

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
    case paste
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
    var onKey: (AmberKey) -> Void

    @State private var plane: Plane = .letters
    @State private var shifted = false
    @State private var capsLocked = false

    private var amber: AmberPalette { palette }

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
                HStack(spacing: 6) {
                    if index == 2 { leadingRowKey }
                    ForEach(row, id: \.self) { key in
                        AmberKeyCap(label: display(key), palette: amber) {
                            onKey(.char(display(key)))
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

    /// Where Select All / Cut / Copy / Paste live, in place of the grey shortcuts bar.
    private var editStrip: some View {
        HStack(spacing: 6) {
            stripKey("Select All", .selectAll)
            stripKey("Cut", .cut)
            stripKey("Copy", .copy)
            stripKey("Paste", .paste)
        }
        .padding(.bottom, 1)
    }

    private func stripKey(_ label: String, _ key: AmberKey) -> some View {
        Button { onKey(key) } label: {
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(amber.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(amber.color(0.86))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(amber.color(0.66, opacity: 0.4), lineWidth: 1)
                        }
                }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var leadingRowKey: some View {
        if plane == .letters {
            AmberKeyCap(symbol: capsLocked ? "capslock.fill" : (shifted ? "shift.fill" : "shift"),
                        palette: amber, kind: .modifier, width: 74, isActive: shifted || capsLocked) {
                if capsLocked { capsLocked = false; shifted = false }
                else if shifted { capsLocked = true }
                else { shifted = true }
                onKey(.shift)
            }
        } else {
            AmberKeyCap(label: plane == .numbers ? "#+=" : "123",
                        palette: amber, kind: .modifier, width: 74) {
                plane = plane == .numbers ? .symbols : .numbers
                onKey(.plane(plane))
            }
        }
    }

    private var backspaceKey: some View {
        AmberKeyCap(symbol: "delete.left", palette: amber, kind: .modifier,
                    width: 74, repeats: true) { onKey(.backspace) }
    }

    private var bottomRow: some View {
        HStack(spacing: 6) {
            AmberKeyCap(label: plane == .letters ? "123" : "ABC",
                        palette: amber, kind: .modifier, width: 74) {
                plane = plane == .letters ? .numbers : .letters
                onKey(.plane(plane))
            }
            if showsDotCom {
                AmberKeyCap(label: ".", palette: amber, kind: .modifier, width: 52) {
                    onKey(.char("."))
                }
            }
            AmberKeyCap(label: "space", palette: amber, kind: .space) { onKey(.space) }
            if showsDotCom {
                AmberKeyCap(label: ".com", palette: amber, kind: .modifier, width: 74) {
                    onKey(.dotCom)
                }
            }
            AmberKeyCap(label: goLabel, palette: amber, kind: .go, width: 92) { onKey(.go) }
            AmberKeyCap(symbol: "keyboard.chevron.compact.down",
                        palette: amber, kind: .modifier, width: 60) { onKey(.hide) }
        }
    }

    private func display(_ key: String) -> String {
        guard plane == .letters, shifted || capsLocked else { return key }
        return key.uppercased()
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
    var action: () -> Void

    init(label: String, palette: AmberPalette, kind: Kind = .letter, width: CGFloat? = nil,
         isActive: Bool = false, repeats: Bool = false, action: @escaping () -> Void) {
        self.label = label; self.symbol = nil; self.palette = palette; self.kind = kind
        self.width = width; self.isActive = isActive; self.repeats = repeats; self.action = action
    }

    init(symbol: String, palette: AmberPalette, kind: Kind = .letter, width: CGFloat? = nil,
         isActive: Bool = false, repeats: Bool = false, action: @escaping () -> Void) {
        self.label = nil; self.symbol = symbol; self.palette = palette; self.kind = kind
        self.width = width; self.isActive = isActive; self.repeats = repeats; self.action = action
    }

    @State private var pressed = false
    @State private var repeater: Timer?

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
        .frame(height: 46)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressed else { return }
                    pressed = true
                    action()
                    if repeats { startRepeating() }
                }
                .onEnded { _ in
                    pressed = false
                    stopRepeating()
                }
        )
        .onDisappear { stopRepeating() }
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

    private func stopRepeating() {
        repeater?.invalidate()
        repeater = nil
    }
}
