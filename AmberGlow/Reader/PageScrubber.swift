import SwiftUI

/// The page-side half of the scrubber: measures the document in screenfuls, and runs
/// the continuous scroll. Shared by the reader and the browser so a page is the same
/// thing in both. The velocity loop lives here rather than being ticked from Swift so
/// the movement lands on the page's own animation frames.
enum DocumentPager {
    static func script(handler: String) -> String {
        """
        (function () {
          if (window.__agPager) return;
          var post = function (payload) {
            payload.name = "pages";
            try { window.webkit.messageHandlers.\(handler).postMessage(payload); } catch (e) {}
          };
          var pager = {
            velocity: 0, raf: null, lastFrame: 0,
            report: function () {
              var h = window.innerHeight || 1;
              var doc = document.documentElement.scrollHeight;
              var total = Math.max(1, Math.ceil(doc / h));
              var page = Math.min(total, Math.floor(window.scrollY / h) + 1);
              var max = doc - h;
              var pct = max > 0 ? Math.min(1, Math.max(0, window.scrollY / max)) : 0;
              post({ page: page, total: total, percent: pct });
            },
            autoScroll: function (v) {
              pager.velocity = v;
              if (v === 0) {
                if (pager.raf) { cancelAnimationFrame(pager.raf); pager.raf = null; }
                return;
              }
              if (pager.raf) return;
              pager.lastFrame = performance.now();
              var step = function (t) {
                var dt = Math.min(0.05, (t - pager.lastFrame) / 1000);
                pager.lastFrame = t;
                window.scrollBy(0, pager.velocity * dt);
                pager.raf = requestAnimationFrame(step);
              };
              pager.raf = requestAnimationFrame(step);
            }
          };
          window.__agPager = pager;

          var pending;
          var schedule = function () {
            if (pending) return;
            pending = requestAnimationFrame(function () { pending = null; pager.report(); });
          };
          window.addEventListener("scroll", schedule, { passive: true });
          window.addEventListener("resize", schedule, { passive: true });
          window.addEventListener("load", schedule);
          document.addEventListener("DOMContentLoaded", schedule);
          schedule();
        })();
        """
    }
}

/// Where the reader is, and a way to travel.
///
/// This stands in for the scroll indicator, which is the one piece of furniture the ramp
/// could not reach — a grey bar over an amber page. It says the same thing in the app's
/// own terms (a page count rather than a bar), and unlike an indicator it can be used:
/// press and drag, and the distance from where you started sets the speed. Direction
/// comes from whether you pull up or down, speed from how far — so a small pull nudges
/// a page at a time and a long one covers a chapter, without ever leaving the control.
/// Where the reader is, and a way to travel.
///
/// This stands in for the scroll indicator, which is the one piece of furniture the ramp
/// could not reach — a grey bar over an amber page. At rest it is only a readout. Tapping
/// it springs a scrub track up out of the pill: the thumb settles above its resting place
/// with guide lines running above and below, so the axis you can pull along is visible
/// before you pull it. Down goes forward, up goes back, and how far you pull sets the
/// speed. Springing the thumb upward first is what makes downward travel possible at all
/// — anchored in a corner, a drag toward the bezel has nowhere to go.
struct PageScrubber: View {
    @Environment(\.amber) private var amber

    let page: Int
    let total: Int
    let percent: Double
    /// Long-pressing the pill switches this, so the choice lives on the thing it
    /// describes rather than in a settings panel two taps away.
    @Binding var style: DisplaySettings.ProgressStyle
    /// Height of the page the control has to live in.
    var available: CGFloat
    /// Points per second, signed. Zero stops.
    var scroll: (Double) -> Void

    @State private var isOpen = false
    /// Vertical travel of the thumb from its resting place.
    @State private var travel: CGFloat = 0
    @State private var isDragging = false
    @State private var lastTouch = Date()
    @State private var idleTimer: Task<Void, Never>?
    /// Showing the percent/pages chooser in place of the readout.
    @State private var styleMenu = false
    @State private var pressTimer: Task<Void, Never>?
    @State private var pressHandled = false

    /// How far above the pill the thumb settles, where there is room for it.
    private let restAtFullSize: CGFloat = 188
    /// Travel at which the speed curve tops out — reached as the thumb meets the
    /// outermost guide line, so the marks read as the speed range. Held short of `rest`
    /// so a full downward pull still stops clear of the pill rather than landing on it.
    private let travelAtFullSize: CGFloat = 110
    /// The guide track's full span. Its gap is symmetric, so its centre is the thumb's,
    /// and it is sized so the outermost mark sits at `fullTravel`.
    private let trackAtFullSize: CGFloat = 264

    /// Everything above the pill, drawn full size where the page can hold it and shrunk
    /// where it cannot. A phone in landscape leaves barely 330pt of page, and the track
    /// wants 376 — unscaled it would climb over the chrome at the top. The parts scale
    /// together, so the guide marks go on reading as the speed range rather than drifting
    /// away from the travel they describe.
    private var scale: CGFloat {
        let needed = restAtFullSize + trackAtFullSize / 2 + 56
        guard available > 0, available < needed else { return 1 }
        return max(0.55, available / needed)
    }

    private var rest: CGFloat { restAtFullSize * scale }
    private var fullTravel: CGFloat { travelAtFullSize * scale }
    private var trackHeight: CGFloat { trackAtFullSize * scale }
    /// How far the readout reaches leftward while held, to clear the finger.
    private let reach: CGFloat = 118
    private let deadZone: CGFloat = 10
    /// Seconds of stillness before the track puts itself away.
    private let idleTimeout: Double = 3.0

    /// Roughly how long a full pull takes to cross the whole document.
    ///
    /// Speed cannot be a fixed number of points per second. The same article set to a
    /// phone's column is several times the scroll extent it has on a wide panel — the
    /// measure is half as wide, so the text is twice as long — and a rate that reads as
    /// brisk on the iPad barely moves the page on the phone. Tying the speed to the
    /// length of the document instead makes a full pull mean the same thing on both.
    private let fullPullSeconds: Double = 5

    /// Points per second at the end of the pull. `total` is the document measured in
    /// screenfuls, which is the pager's own unit, so the two multiply out to its length.
    private var maxSpeed: Double {
        let viewport = max(320, Double(available))
        return max(1500, viewport * Double(total) / fullPullSeconds)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if isOpen {
                // Track and thumb share one centre, so the handle always lands in the
                // middle of the guide lines. Positioning them separately is what let
                // them drift apart.
                ZStack {
                    track
                    thumb
                }
                .frame(height: trackHeight)
                .offset(y: -(rest - trackHeight / 2))
            }
            if styleMenu { chooser } else { pill }
        }
        .frame(height: isOpen ? rest + trackHeight / 2 + 56 : 46, alignment: .bottom)
        // How much room this is taking, for the ground drawn beneath it. Measured rather
        // than computed so it follows the spring rather than jumping ahead of it.
        //
        // Nothing while the pill is at rest. The ground is for the open track — a tall
        // thing standing over a page it has to be read against. The pill on its own is a
        // small enough mark to carry its own border, and a pool sitting under it always
        // would be a permanent bright patch in the corner of every page.
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: ScrubberFootprint.self,
                                       value: isOpen ? geo.size.height : 0)
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.72), value: isOpen)
        .onChange(of: percent) { _, _ in
            // A scroll the reader made themselves — put the track away.
            guard isOpen, !isDragging,
                  Date().timeIntervalSince(lastTouch) > 0.6 else { return }
            close()
        }
        .onDisappear { idleTimer?.cancel(); pressTimer?.cancel() }
    }

    /// The percent/pages chooser. It takes the pill's place rather than sitting above it:
    /// the whole control is pinned by its right edge, so replacing the pill lets the
    /// chooser grow leftward from exactly where the pill was, instead of shoving it aside.
    private var chooser: some View {
        HStack(spacing: 0) {
            option("Percent", .percent)
            amber.color(0.62, opacity: 0.45).frame(width: 1, height: 18)
            option("Pages", .pages)
        }
        .background { Capsule().fill(amber.color(0.93)) }
        .overlay { Capsule().strokeBorder(amber.color(0.62, opacity: 0.5), lineWidth: 1) }
        .clipShape(Capsule())
        .shadow(color: amber.color(0.0, opacity: 0.22), radius: 14, y: 4)
        .transition(.scale(scale: 0.86, anchor: .trailing).combined(with: .opacity))
    }

    private func option(_ title: String, _ value: DisplaySettings.ProgressStyle) -> some View {
        let selected = style == value
        return Text(title)
            .font(.system(size: 13, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? amber.color(0.92) : amber.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background { selected ? amber.color(0.28) : Color.clear }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onEnded { v in
                    guard abs(v.translation.width) < 12,
                          abs(v.translation.height) < 12 else { return }
                    choose(value)
                }
            )
    }

    /// Current leftward reach of the readout.
    private var reachNow: CGFloat { isDragging ? reach : 0 }

    // MARK: - Readout

    private var shortLabel: String {
        style == .percent ? "\(Int((percent * 100).rounded()))%" : "\(page) of \(total)"
    }

    private var pill: some View {
        HStack(spacing: 7) {
            Image(systemName: "book.pages")
                .font(.system(size: 14))
            if !isOpen {
                Text(shortLabel)
                    .font(.system(size: 12.5, weight: .medium))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(isOpen ? amber.color(0.92) : amber.ink)
        .padding(.horizontal, isOpen ? 10 : 12)
        .padding(.vertical, 9)
        .background { Capsule().fill(amber.color(isOpen ? 0.26 : 0.86)) }
        .overlay {
            Capsule().strokeBorder(amber.color(isOpen ? 0.26 : 0.62, opacity: 0.5), lineWidth: 1)
        }
        .shadow(color: amber.color(0.0, opacity: 0.16), radius: 10, y: 4)
        .contentShape(Capsule())
        // One gesture, timed by hand. Neither `.onTapGesture` nor `.onLongPressGesture`
        // survives here — over a web view WebKit's own recognisers take the touch — so
        // tap and long press are both measured from the zero-distance drag that does win.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard pressTimer == nil, !pressHandled,
                          abs(value.translation.width) < 12,
                          abs(value.translation.height) < 12 else { return }
                    pressTimer = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        guard !Task.isCancelled else { return }
                        pressHandled = true
                        showStyleMenu()
                    }
                }
                .onEnded { value in
                    pressTimer?.cancel()
                    pressTimer = nil
                    let wasLongPress = pressHandled
                    pressHandled = false
                    guard !wasLongPress,
                          abs(value.translation.width) < 12,
                          abs(value.translation.height) < 12 else { return }
                    if styleMenu { dismissStyleMenu() }
                    else if isOpen { close() }
                    else { open() }
                }
        )
    }

    /// The thumb: the readout, enlarged, and the thing you actually drag.
    private var thumb: some View {
        VStack(spacing: 1) {
            if style == .percent {
                Text("\(Int((percent * 100).rounded()))%")
                    .font(.system(size: 30, weight: .semibold, design: .serif))
                    .monospacedDigit()
                    .foregroundStyle(amber.inkStrong)
            } else {
                Text("\(page)")
                    .font(.system(size: 30, weight: .semibold, design: .serif))
                    .monospacedDigit()
                    .foregroundStyle(amber.inkStrong)
                Text("of \(total)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(amber.inkMuted)
            }
        }
        .frame(minWidth: 84)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(amber.color(0.93))
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(amber.color(0.62, opacity: 0.55), lineWidth: 1)
            }
            // Reaches back under the finger. Negative padding grows the shape without
            // changing the measured width, so the guide marks stay centred on the pill.
            .padding(.trailing, -reachNow)
        }
        .shadow(color: amber.color(0.0, opacity: isDragging ? 0.28 : 0.2),
                radius: isDragging ? 20 : 12, y: 5)
        // Held, the readout slides out to the left so the hand is not sitting on the
        // number it is being used to read.
        .offset(x: -reachNow, y: travel)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    isDragging = true
                    lastTouch = Date()
                    travel = max(-fullTravel, min(fullTravel, value.translation.height))
                    scroll(velocity(for: travel))
                }
                .onEnded { _ in
                    isDragging = false
                    lastTouch = Date()
                    scroll(0)
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.7)) { travel = 0 }
                    startIdleTimer()
                }
        )
        .animation(.spring(response: 0.28, dampingFraction: 0.76), value: isDragging)
        .transition(.scale(scale: 0.4, anchor: .bottom).combined(with: .opacity))
    }

    /// Guide lines above and below: the axis, and a hint that further means faster.
    private var track: some View {
        VStack(spacing: 0) {
            chevron("chevron.up")
            marks(reversed: true)
            // Flexible, and the halves above and below it are identical, which is what
            // makes the VStack's centre the centre of this gap.
            Spacer(minLength: 120 * scale)
            marks(reversed: false)
            chevron("chevron.down")
        }
        .frame(height: trackHeight)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private func chevron(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(amber.color(0.52, opacity: 0.7))
            .padding(.vertical, 5)
    }

    /// Lines lengthen as they get further out, so the speed ramp is legible at a glance.
    private func marks(reversed: Bool) -> some View {
        let steps = Array(0..<5)
        return VStack(spacing: 10 * scale) {
            ForEach(reversed ? steps.reversed() : steps, id: \.self) { i in
                let t = Double(i) / 4.0
                Capsule()
                    .fill(amber.color(0.5, opacity: 0.28 + 0.34 * t))
                    .frame(width: 10 + 20 * t, height: 2)
            }
        }
    }

    // MARK: - Behaviour

    private func showStyleMenu() {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
            isOpen = false
            travel = 0
            styleMenu = true
        }
        lastTouch = Date()
        startIdleTimer()
    }

    private func dismissStyleMenu() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { styleMenu = false }
    }

    private func choose(_ value: DisplaySettings.ProgressStyle) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        style = value
        dismissStyleMenu()
    }

    private func open() {
        isOpen = true
        travel = 0
        lastTouch = Date()
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        startIdleTimer()
    }

    private func close() {
        idleTimer?.cancel()
        idleTimer = nil
        scroll(0)
        isOpen = false
        isDragging = false
        travel = 0
    }

    private func startIdleTimer() {
        idleTimer?.cancel()
        idleTimer = Task { @MainActor in
            while !Task.isCancelled {
                let idle = Date().timeIntervalSince(lastTouch)
                if idle >= idleTimeout {
                    if !isDragging {
                        close()
                        if styleMenu { dismissStyleMenu() }
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64((idleTimeout - idle) * 1_000_000_000))
                if Task.isCancelled { return }
            }
        }
    }

    /// Down is forward. Distance from the resting place sets the speed, squared so the
    /// first half of the pull stays gentle enough to land on a particular page.
    private func velocity(for travel: CGFloat) -> Double {
        let distance = abs(Double(travel))
        guard distance > Double(deadZone) else { return 0 }
        let t = min(1, (distance - Double(deadZone)) / Double(fullTravel - deadZone))
        return t * t * maxSpeed * (travel > 0 ? 1 : -1)
    }
}

/// How much room the scrubber is taking, or zero when it is closed and wants no ground.
/// Reported upward because the ground beneath it has to be drawn by the page rather than
/// by the control — see `ScrubberGround`.
struct ScrubberFootprint: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The ground the scrubber sits on: the panel's own surface, brought back up over the
/// page and masked to a soft pool, so the readout is not left competing with whatever
/// paragraph happens to be behind it.
///
/// It is a second copy of `GlowSurface`, not a fill of the page colour, because the page
/// is not a flat colour. The surface carries the backlight bloom over it and the pixel
/// lattice through it, so it is *brighter* than `color(0.88)` across most of the glass —
/// and painting that colour on top of it therefore comes out darker than the page it is
/// meant to disappear into. Drawing the same surface again cannot drift from it at any
/// glow, warmth or polarity: where the mask is solid the page is replaced by itself, so
/// the text under it goes and nothing else changes, and the falloff is a cross-fade
/// between two identical colours rather than a wash of a third one.
///
/// That is also why it lives out here rather than inside the control. It has to be laid
/// over the page at the page's own size — a copy sized to the pool would centre the bloom
/// on the pool, and come out brighter than its surroundings instead of darker.
struct ScrubberGround: View {
    /// How tall the control is right now, so the pool covers it and no more.
    var height: CGFloat

    var body: some View {
        GlowSurface()
            .compositingGroup()
            .mask(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 70, style: .continuous)
                    .fill(.white)
                    .frame(width: 240, height: height + 120)
                    // Off the right edge and off the bottom rather than curving back in.
                    // There is no page out there to keep, and a shape that closes on
                    // every side reads as an object laid on the page instead of the page
                    // simply being all there is in that corner.
                    .padding(.trailing, -90)
                    .padding(.bottom, -50)
                    .blur(radius: 28)
            }
            .allowsHitTesting(false)
    }
}
