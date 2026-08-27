import SwiftUI

/// A book's table of contents.
///
/// Neither existing list fits it: `AmberMenu` is drawn for four items at a fixed 226pt
/// width, not sixty chapters, and `PageScrubber` is a velocity control whose physical
/// language has nothing to do with a list. This reuses the presentation `AddLinkSheet`
/// already established — full screen on compact, a fitted card on regular, `GlowSurface`
/// behind it — because that is this app's one existing answer to "a panel on the glass".
struct ContentsSheet: View {
    @Environment(\.amber) private var amber
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    let article: SavedArticle
    let chapters: [BookChapter]
    /// The anchor of whichever chapter the reader is at right now, so it can be marked —
    /// same idea as `ArticleRow` marking the selected item, not a separate affordance.
    let currentAnchor: String?
    var onSelect: (BookChapter) -> Void

    private var isCompact: Bool { sizeClass == .compact }

    var body: some View {
        if isCompact {
            VStack(spacing: 0) {
                header
                Hairline()
                list
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(GlowSurface(level: 0.9))
            .statusBarHidden(true)
        } else {
            VStack(spacing: 0) {
                header
                Hairline()
                list
            }
            .frame(width: 380)
            .frame(maxHeight: 520)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Contents")
                    .font(.system(size: 18, weight: .semibold, design: .serif))
                    .foregroundStyle(amber.inkStrong)
                Text(article.displayTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(amber.inkMuted)
                    .lineLimit(1)
            }
            Spacer()
            AmberIconButton(symbol: "xmark") { dismiss() }
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(chapters.enumerated()), id: \.offset) { _, chapter in
                    Button {
                        onSelect(chapter)
                        dismiss()
                    } label: {
                        row(for: chapter)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func row(for chapter: BookChapter) -> some View {
        let isCurrent = chapter.href == currentAnchor
            || (currentAnchor?.hasPrefix(chapter.href + "-") ?? false)
        return HStack(spacing: 8) {
            Text(chapter.title)
                .font(.system(size: 14.5, weight: isCurrent ? .semibold : .regular, design: .serif))
                .foregroundStyle(isCurrent ? amber.inkStrong : amber.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 8)
        }
        .padding(.leading, 16 + CGFloat(chapter.depth) * 16)
        .padding(.trailing, 16)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isCurrent ? amber.color(0.90) : .clear)
        .overlay(alignment: .leading) {
            if isCurrent { amber.color(0.20).frame(width: 3) }
        }
        .contentShape(Rectangle())
    }
}
