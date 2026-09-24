import SwiftUI

/// The first thing a new reader is shown once the name has faded: how an article gets
/// here from somewhere else.
///
/// Evening Reader is mostly filled from outside itself — a page found in Safari, a link in
/// Mail — and the way in is the share sheet, which the app has no say over and which
/// iOS does not always put the extension in plain sight. Left to find that alone, a new
/// reader opens an empty library and sees nothing to do. So it is shown once, on a first
/// launch with nothing in the library, and can be asked for again from the add panel.
struct OnboardingSheet: View {
    @Environment(DisplaySettings.self) private var settings

    var body: some View {
        // The palette is set once at the root, and a presentation hosted apart from the
        // window (on Mac, running the iPad build) does not reliably inherit it.
        OnboardingPages()
            .environment(\.amber, settings.palette)
    }

    private static let seenKey = "onboarding.seen"

    /// Whether the guide has been shown on this device. Kept per device rather than in
    /// the shared settings: a second device is a new share sheet to find the app in.
    static var hasBeenSeen: Bool {
        get { UserDefaults.standard.bool(forKey: seenKey) }
        set { UserDefaults.standard.set(newValue, forKey: seenKey) }
    }
}

private struct OnboardingPages: View {
    @Environment(\.amber) private var amber
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var page = 0

    private struct Step {
        let caption: String
        let title: String
        let body: String
        var note: String?
    }

    private let steps: [Step] = [
        Step(caption: "Welcome",
             title: "Save it now, read it tonight",
             body: "Evening Reader keeps the articles you come across during the day, stripped down to the words and lit warm for reading after dark."),
        Step(caption: "Step one",
             title: "Tap Share",
             body: "In Safari — or any app with a link in it — tap the Share button on the page you want to keep."),
        Step(caption: "Step two",
             title: "Choose Save to Evening Reader",
             body: "Pick Evening Reader from the row of apps in the share sheet.",
             note: "Not there? Scroll the row of apps to the end and tap More, then Edit, and add Evening Reader to your favorites so it stays up front."),
        Step(caption: "Step three",
             title: "It's waiting here",
             body: "The article lands in your library, ready to read — and it's kept on this device, so it's there even with no connection."),
    ]

    private var isLast: Bool { page == steps.count - 1 }
    private var isCompact: Bool { sizeClass == .compact }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if !isLast {
                    Button("Skip") { finish() }
                        .buttonStyle(AmberButtonStyle(kind: .quiet))
                }
            }
            .frame(height: 34)
            .padding(.horizontal, 16)
            .padding(.top, 12)

            TabView(selection: $page) {
                ForEach(steps.indices, id: \.self) { index in
                    stepView(steps[index], index: index)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GlowSurface(level: 0.9))
        .statusBarHidden(true)
    }

    private func stepView(_ step: Step, index: Int) -> some View {
        ScrollView {
            VStack(spacing: isCompact ? 28 : 36) {
                illustration(for: index)
                    .frame(height: 200)
                    .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 12) {
                    AmberCaption(text: step.caption)
                    Text(step.title)
                        .font(.system(size: isCompact ? 26 : 30, weight: .semibold, design: .serif))
                        .foregroundStyle(amber.inkStrong)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(step.body)
                        .font(.system(size: 16, design: .serif))
                        .lineSpacing(4)
                        .foregroundStyle(amber.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let note = step.note {
                        Text(note)
                            .font(.system(size: 13))
                            .lineSpacing(3)
                            .foregroundStyle(amber.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: 460)
            .padding(.horizontal, isCompact ? 26 : 32)
            .padding(.top, isCompact ? 12 : 40)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder
    private func illustration(for index: Int) -> some View {
        switch index {
        case 0: LitPageIllustration()
        case 1: ShareButtonIllustration()
        case 2: ShareSheetIllustration()
        default: LibraryIllustration()
        }
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 8) {
                ForEach(steps.indices, id: \.self) { index in
                    Capsule()
                        .fill(index == page ? amber.ink : amber.color(0.62))
                        .frame(width: index == page ? 18 : 7, height: 7)
                }
            }
            .animation(.drawer, value: page)
            .accessibilityElement()
            .accessibilityLabel("Page \(page + 1) of \(steps.count)")

            Spacer()

            Button(isLast ? "Start reading" : "Next") {
                if isLast { finish() } else { withAnimation(.drawer) { page += 1 } }
            }
            .buttonStyle(AmberButtonStyle(kind: .solid))
        }
        .frame(maxWidth: 460)
        .padding(.horizontal, isCompact ? 26 : 32)
        .padding(.bottom, 24)
        .padding(.top, 12)
        .frame(maxWidth: .infinity)
    }

    private func finish() {
        OnboardingSheet.hasBeenSeen = true
        dismiss()
    }
}

// MARK: - Illustrations
//
// Drawn from the ramp rather than from screenshots, so they arrive in whatever glow the
// reader has — and do not go out of date with the next iOS share sheet.

/// A raised card in the ramp, the one surface every illustration is drawn on.
private struct Plate<Content: View>: View {
    @Environment(\.amber) private var amber
    var width: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: width)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(amber.pageRaised)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(amber.rule, lineWidth: 1))
                    .shadow(color: amber.color(0.2, opacity: 0.12), radius: 14, y: 6)
            )
    }
}

/// Lines of text standing in for a paragraph.
private struct TextLines: View {
    @Environment(\.amber) private var amber
    var widths: [CGFloat]
    var level: Double = 0.62

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(widths.indices, id: \.self) { i in
                Capsule().fill(amber.color(level)).frame(width: widths[i], height: 5)
            }
        }
    }
}

private struct LitPageIllustration: View {
    @Environment(\.amber) private var amber

    var body: some View {
        Plate(width: 200) {
            VStack(alignment: .leading, spacing: 14) {
                Capsule().fill(amber.inkStrong).frame(width: 120, height: 9)
                Capsule().fill(amber.inkFaint).frame(width: 70, height: 5)
                TextLines(widths: [160, 152, 164, 110], level: 0.36)
                TextLines(widths: [158, 164, 96], level: 0.36)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityHidden(true)
    }
}

private struct ShareButtonIllustration: View {
    @Environment(\.amber) private var amber

    var body: some View {
        Plate(width: 240) {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    Capsule().fill(amber.color(0.3)).frame(width: 130, height: 8)
                    TextLines(widths: [196, 184, 200, 140])
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)

                amber.rule.frame(height: 1)

                HStack {
                    toolbarIcon("chevron.left")
                    Spacer()
                    toolbarIcon("chevron.right")
                    Spacer()
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(amber.color(0.94))
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(amber.fillActive))
                        .overlay(Circle().strokeBorder(amber.inkStrong, lineWidth: 2).padding(-5))
                    Spacer()
                    toolbarIcon("book")
                    Spacer()
                    toolbarIcon("square.on.square")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
        }
        .accessibilityHidden(true)
    }

    private func toolbarIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(amber.inkFaint)
    }
}

private struct ShareSheetIllustration: View {
    @Environment(\.amber) private var amber

    var body: some View {
        Plate(width: 290) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 6).fill(amber.color(0.74))
                        .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 6) {
                        Capsule().fill(amber.color(0.3)).frame(width: 120, height: 6)
                        Capsule().fill(amber.color(0.6)).frame(width: 80, height: 5)
                    }
                }

                HStack(alignment: .top, spacing: 14) {
                    otherApp("message.fill")
                    otherApp("envelope.fill")
                    ours
                    otherApp("ellipsis", label: "More")
                }
            }
            .padding(18)
        }
        .accessibilityHidden(true)
    }

    private var ours: some View {
        VStack(spacing: 6) {
            Image(systemName: "book.pages.fill")
                .font(.system(size: 22))
                .foregroundStyle(amber.color(0.94))
                .frame(width: 52, height: 52)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(amber.fillActive))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(amber.inkStrong, lineWidth: 2).padding(-5))
            Text("Evening Reader")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(amber.inkStrong)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 60)
    }

    private func otherApp(_ symbol: String, label: String? = nil) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 19))
                .foregroundStyle(amber.inkFaint)
                .frame(width: 52, height: 52)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(amber.color(0.8)))
            if let label {
                Text(label).font(.system(size: 10)).foregroundStyle(amber.inkMuted)
            } else {
                Capsule().fill(amber.color(0.66)).frame(width: 34, height: 5).padding(.top, 4)
            }
        }
        .frame(width: 52)
    }
}

private struct LibraryIllustration: View {
    @Environment(\.amber) private var amber

    var body: some View {
        Plate(width: 260) {
            VStack(spacing: 0) {
                row(title: 150, highlighted: true)
                amber.rule.frame(height: 1).padding(.leading, 16)
                row(title: 120, highlighted: false)
                amber.rule.frame(height: 1).padding(.leading, 16)
                row(title: 170, highlighted: false)
            }
            .padding(.vertical, 6)
        }
        .accessibilityHidden(true)
    }

    private func row(title: CGFloat, highlighted: Bool) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(highlighted ? amber.inkStrong : .clear)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 7) {
                Capsule().fill(highlighted ? amber.inkStrong : amber.color(0.4))
                    .frame(width: title, height: 7)
                Capsule().fill(amber.color(0.62)).frame(width: 90, height: 5)
            }
            Spacer()
            if highlighted {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(amber.inkMuted)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}
