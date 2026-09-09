import SwiftUI
import UIKit

// MARK: - Type

extension View {
    func amberFont(_ size: Double, weight: Font.Weight = .regular, design: Font.Design = .serif) -> some View {
        font(.system(size: size, weight: weight, design: design))
    }
}

/// Small all-caps label used for section headers and control captions.
struct AmberCaption: View {
    @Environment(\.amber) private var amber
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold, design: .default))
            .tracking(1.4)
            .foregroundStyle(amber.inkMuted)
    }
}

struct Hairline: View {
    @Environment(\.amber) private var amber
    var inset: Double = 0

    var body: some View {
        amber.rule
            .frame(height: 1)
            .padding(.horizontal, inset)
    }
}

// MARK: - Slider

/// A slider drawn from the amber ramp: a sunken track, a solid ink fill, a blocky thumb.
/// Nothing here can pick up a system accent color.
struct AmberSlider: View {
    @Environment(\.amber) private var amber

    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var ticks: Int = 0
    var leadingSymbol: String?
    var trailingSymbol: String?
    /// When set, the track shows this ramp instead of a plain fill — used by the
    /// warmth control, where the track *is* the thing being chosen.
    var trackGradient: LinearGradient?

    private let trackHeight: Double = 10
    private let thumbWidth: Double = 26
    private let thumbHeight: Double = 30

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return clamp01((value - range.lowerBound) / span)
    }

    private func set(from x: Double, usable: Double) {
        let f = clamp01((x - thumbWidth / 2) / usable)
        value = range.lowerBound + f * (range.upperBound - range.lowerBound)
    }

    var body: some View {
        HStack(spacing: 14) {
            if let leadingSymbol {
                Image(systemName: leadingSymbol)
                    .font(.system(size: 14))
                    .foregroundStyle(amber.inkMuted)
                    .frame(width: 18)
            }

            GeometryReader { geo in
                let usable = max(geo.size.width - thumbWidth, 1)
                let x = usable * fraction + thumbWidth / 2

                ZStack(alignment: .leading) {
                    // Track
                    Group {
                        if let trackGradient {
                            Capsule(style: .continuous).fill(trackGradient)
                        } else {
                            Capsule(style: .continuous).fill(amber.fill)
                        }
                    }
                    .overlay(Capsule(style: .continuous).strokeBorder(amber.rule, lineWidth: 1))
                    .frame(height: trackHeight)

                    if trackGradient == nil {
                        Capsule(style: .continuous)
                            .fill(amber.color(0.30))
                            .frame(width: max(x - thumbWidth / 2 + trackHeight, trackHeight),
                                   height: trackHeight)
                    }

                    if ticks > 1 {
                        HStack(spacing: 0) {
                            ForEach(0..<ticks, id: \.self) { i in
                                Rectangle()
                                    .fill(amber.color(0.60))
                                    .frame(width: 1, height: 4)
                                if i < ticks - 1 { Spacer(minLength: 0) }
                            }
                        }
                        .padding(.horizontal, thumbWidth / 2)
                        .offset(y: trackHeight / 2 + 8)
                    }

                    // Thumb
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(amber.color(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(amber.color(0.98, opacity: 0.35), lineWidth: 1)
                        )
                        .overlay(
                            Rectangle()
                                .fill(amber.color(0.92, opacity: 0.55))
                                .frame(width: 1, height: thumbHeight * 0.42)
                        )
                        .frame(width: thumbWidth, height: thumbHeight)
                        .position(x: x, y: geo.size.height / 2)
                }
                .frame(height: geo.size.height)
                // The slider sits in a panel that scrolls, and either the slider has
                // the touch or the page does — decided the moment the finger lands. On
                // the thumb, the slider owns everything that follows, in whatever
                // direction the finger goes; anywhere else, the page does, and the
                // slider does not move. Handled in UIKit, where a recognizer can begin
                // at touch-down and shut the scrolling out, or fail and leave it the
                // touch — a SwiftUI drag could be made to do neither. See `HandleDrag`.
                .overlay {
                    HandleDrag(handleX: x, handleWidth: thumbWidth) { centre in
                        set(from: centre, usable: usable)
                    }
                }
            }
            .frame(height: thumbHeight)

            if let trailingSymbol {
                Image(systemName: trailingSymbol)
                    .font(.system(size: 18))
                    .foregroundStyle(amber.inkMuted)
                    .frame(width: 18)
            }
        }
    }
}

/// A drag of the slider's handle, and nothing else.
///
/// The view covers the track. A touch that lands on the handle begins the drag at
/// once — before the finger has moved at all — which is what keeps the page from
/// scrolling under it: a recognizer that has begun shuts the others out. A touch that
/// lands anywhere else fails at once, and the page has it. There is no tap: the track
/// is not a control, only the handle is.
private struct HandleDrag: UIViewRepresentable {
    /// The handle's centre, in the view's coordinates.
    var handleX: CGFloat
    var handleWidth: CGFloat
    /// Where the handle's centre should move to.
    var onChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let drag = HandleRecognizer(target: context.coordinator, action: #selector(Coordinator.drag(_:)))
        view.addGestureRecognizer(drag)
        context.coordinator.recognizer = drag
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        let coordinator = context.coordinator
        coordinator.handleX = handleX
        coordinator.onChange = onChange
        // A little wider than the handle draws, for the finger's sake.
        let reach = handleWidth / 2 + 10
        coordinator.recognizer?.hits = { point in abs(point.x - handleX) <= reach }
    }

    final class Coordinator: NSObject {
        var handleX: CGFloat = 0
        var onChange: (CGFloat) -> Void = { _ in }
        weak var recognizer: HandleRecognizer?
        /// Where on the handle the finger landed, so the handle follows the finger
        /// from where it was rather than jumping to centre itself under it.
        private var grip: CGFloat = 0

        @objc func drag(_ g: HandleRecognizer) {
            guard let view = g.view else { return }
            let x = g.location(in: view).x
            switch g.state {
            case .began: grip = x - handleX
            case .changed: onChange(x - grip)
            default: break
            }
        }
    }
}

/// Begins on touch-down if the touch is on the handle, and fails on touch-down if not.
private final class HandleRecognizer: UIGestureRecognizer {
    var hits: (CGPoint) -> Bool = { _ in false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard state == .possible, let touch = touches.first, let view else { return }
        state = hits(touch.location(in: view)) ? .began : .failed
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        if state == .began || state == .changed { state = .changed }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        if state == .began || state == .changed { state = .ended }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        if state == .began || state == .changed { state = .cancelled }
    }
}

// MARK: - Segmented control

struct AmberSegmented<T: Hashable & Identifiable>: View {
    @Environment(\.amber) private var amber

    @Binding var selection: T
    let options: [T]
    let label: (T) -> String
    var symbol: ((T) -> String?)? = nil

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options) { option in
                let isOn = option == selection
                Button {
                    withAnimation(.easeOut(duration: 0.14)) { selection = option }
                } label: {
                    HStack(spacing: 6) {
                        if let s = symbol?(option) {
                            Image(systemName: s).font(.system(size: 12, weight: .medium))
                        }
                        Text(label(option))
                            .font(.system(size: 14, weight: isOn ? .semibold : .regular))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(isOn ? amber.color(0.93) : amber.inkMuted)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isOn ? amber.color(0.14) : .clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(amber.fill)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(amber.rule, lineWidth: 1)
                )
        )
    }
}

// MARK: - Toggle

struct AmberToggle: View {
    @Environment(\.amber) private var amber
    @Binding var isOn: Bool
    let title: String

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.14)) { isOn.toggle() }
        } label: {
            HStack {
                Text(title)
                    .font(.system(size: 15))
                    .foregroundStyle(amber.ink)
                Spacer()
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? amber.color(0.22) : amber.fill)
                        .overlay(Capsule().strokeBorder(amber.rule, lineWidth: 1))
                    Circle()
                        .fill(isOn ? amber.color(0.94) : amber.color(0.62))
                        .padding(2)
                }
                .frame(width: 46, height: 27)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Buttons

struct AmberButtonStyle: ButtonStyle {
    enum Kind { case solid, outline, quiet }

    @Environment(\.amber) private var amber
    var kind: Kind = .outline
    var size: Double = 15

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size, weight: .medium))
            .padding(.horizontal, kind == .quiet ? 8 : 18)
            .padding(.vertical, kind == .quiet ? 4 : 10)
            .foregroundStyle(foreground)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(background)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(kind == .quiet ? .clear : amber.color(0.40), lineWidth: 1)
                    )
            )
            .opacity(configuration.isPressed ? 0.62 : 1)
    }

    private var foreground: Color {
        switch kind {
        case .solid: return amber.color(0.94)
        case .outline, .quiet: return amber.ink
        }
    }

    private var background: Color {
        switch kind {
        case .solid: return amber.color(0.12)
        case .outline: return amber.color(0.82, opacity: 0.9)
        case .quiet: return .clear
        }
    }
}

/// Icon-only control for the reader chrome.
struct AmberIconButton: View {
    @Environment(\.amber) private var amber
    let symbol: String
    var isActive: Bool = false
    var size: Double = 17
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .frame(width: 38, height: 34)
                .foregroundStyle(isActive ? amber.color(0.93) : amber.ink)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isActive ? amber.color(0.16) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Card

struct AmberCard<Content: View>: View {
    @Environment(\.amber) private var amber
    var padding: Double = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(amber.color(0.93))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(amber.rule, lineWidth: 1)
                    )
            )
    }
}

// MARK: - Measuring

/// Reports the height of whatever it is put behind. A background never takes touches, so
/// this can measure a view without standing between it and the finger.
struct HeightReader: View {
    @Binding var height: CGFloat

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { height = geo.size.height }
                .onChange(of: geo.size.height) { _, new in height = new }
        }
    }
}
