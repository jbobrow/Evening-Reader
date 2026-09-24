import SwiftUI

/// Everything the reader has marked.
///
/// Two lists in one, because they are the same list asked two ways. Given no `scope` it
/// is the whole library's — a second shelf, holding what was worth keeping out of
/// everything read, grouped by what it came out of and ordered so the last thing marked
/// is the first thing seen. Given one reading it is that reading's alone, which is what
/// the reader's own chrome opens: a contents page made of your own marks.
///
/// It takes the whole glass on any screen. A card would be right for a short particular
/// list — the way the contents sheet is a card — and this is neither short nor
/// particular; the passages are prose, and prose wants a measure and room to run.
struct HighlightsSheet: View {
    @Environment(Library.self) private var library
    @Environment(Highlights.self) private var highlights
    @Environment(DisplaySettings.self) private var settings
    @Environment(\.amber) private var amber
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// One reading's marks, or — when nil — the whole library's.
    var scope: SavedArticle?
    /// Take me to the passage this came off.
    var onOpen: (SavedArticle, Highlight) -> Void

    @State private var search = ""
    @State private var searchFocused = false
    @State private var showing: Showing?

    private struct Showing: Identifiable {
        let article: SavedArticle
        let highlight: Highlight
        var id: UUID { highlight.id }
    }

    private struct Group: Identifiable {
        let article: SavedArticle
        let marks: [Highlight]
        var id: UUID { article.id }
        var newest: Date { marks.map(\.createdAt).max() ?? .distantPast }
    }

    private var isCompact: Bool { sizeClass == .compact }

    /// Prose, so it gets a measure. The same one the reader itself is set to would be
    /// ideal; this is a list of fragments rather than a page of type, so it takes a
    /// little more and stops well short of the width of an iPad.
    private let measure: CGFloat = 680

    private var groups: [Group] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let source = scope.map { [$0] } ?? library.articles
        return source
            .compactMap { article -> Group? in
                var marks = highlights.list(for: article)
                if !query.isEmpty {
                    marks = marks.filter {
                        // Run together, so a search can find words either side of
                        // a paragraph break.
                        $0.paragraphs.joined(separator: " ").lowercased().contains(query)
                            || ($0.note ?? "").lowercased().contains(query)
                    }
                }
                return marks.isEmpty ? nil : Group(article: article, marks: marks)
            }
            .sorted { $0.newest > $1.newest }
    }

    private var total: Int { groups.reduce(0) { $0 + $1.marks.count } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            if !groups.isEmpty || !search.isEmpty {
                searchField
                Hairline()
            }
            if groups.isEmpty {
                empty
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GlowSurface(level: 0.9))
        .statusBarHidden(true)
        .overlay { card }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Highlights")
                    .font(.system(size: isCompact ? 22 : 26, weight: .semibold, design: .serif))
                    .foregroundStyle(amber.inkStrong)
                HStack(spacing: 6) {
                    if let scope {
                        Text(scope.displayTitle).lineLimit(1)
                        Text("·")
                    }
                    Text(total == 1 ? "1 passage" : "\(total) passages")
                }
                .font(.system(size: 11, weight: .medium))
                .tracking(0.5)
                .foregroundStyle(amber.inkFaint)
            }
            Spacer(minLength: 12)
            AmberIconButton(symbol: "xmark") { dismiss() }
        }
        .frame(maxWidth: measure)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, isCompact ? 18 : 26)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(amber.inkFaint)
            AmberTextField(text: $search,
                           isFocused: $searchFocused,
                           placeholder: "Search passages and notes",
                           palette: settings.palette,
                           showsTexture: settings.showTexture,
                           goLabel: "Done",
                           fontSize: 14,
                           onSubmit: { searchFocused = false })
                .frame(height: 19)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(amber.inkFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(amber.color(0.78))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(amber.rule, lineWidth: 1))
        )
        .frame(maxWidth: measure)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, isCompact ? 14 : 22)
        .padding(.vertical, 12)
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.marks) { mark in
                            Button { choose(mark, in: group.article) } label: {
                                row(mark)
                            }
                            .buttonStyle(.plain)
                            Hairline(inset: 4)
                        }
                    } header: {
                        // One reading's own list needs no heading over every passage —
                        // the title is already in the header, two lines up.
                        if scope == nil { sectionHeader(group) }
                    }
                }
            }
            .frame(maxWidth: measure)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, isCompact ? 12 : 20)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }

    /// In the library's list a passage belongs to something; tapping it opens its card,
    /// where the note is. In a reading's own list you are already there, so tapping goes
    /// straight to the words on the page — and brings the card with it.
    private func choose(_ mark: Highlight, in article: SavedArticle) {
        if scope == nil {
            showing = Showing(article: article, highlight: mark)
        } else {
            onOpen(article, mark)
            dismiss()
        }
    }

    private func sectionHeader(_ group: Group) -> some View {
        HStack(spacing: 6) {
            Text(group.article.displayTitle)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Text("·")
            Text("\(group.marks.count)")
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, weight: .medium))
        .tracking(0.4)
        .foregroundStyle(amber.inkFaint)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                amber.color(0.86)
                if settings.showTexture { PixelGrid() }
            }
        }
        .overlay(alignment: .bottom) { amber.rule.frame(height: 1) }
    }

    private func row(_ mark: Highlight) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(mark.passage)
                .font(.system(size: 15.5, design: .serif))
                .lineSpacing(3.5)
                .lineLimit(6)
                .multilineTextAlignment(.leading)
                .foregroundStyle(amber.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) { amber.color(0.62).frame(width: 3) }

            if let note = mark.note, !note.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "pencil.line")
                        .font(.system(size: 10))
                        .padding(.top, 2)
                    Text(note)
                        .font(.system(size: 13))
                        .lineSpacing(2.5)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(amber.inkMuted)
                .padding(.leading, 15)
            }

            HStack(spacing: 6) {
                if let chapter = mark.chapterTitle, !chapter.isEmpty {
                    Text(chapter).lineLimit(1)
                    Text("·")
                } else if let page = mark.pageIndex {
                    Text("Page \(page + 1)")
                    Text("·")
                }
                Text(mark.createdAt.formatted(date: .abbreviated, time: .omitted))
                Spacer(minLength: 0)
            }
            .font(.system(size: 10.5, weight: .medium))
            .tracking(0.4)
            .foregroundStyle(amber.inkFaint)
            .padding(.leading, 15)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var card: some View {
        if let showing {
            ZStack {
                AmberScrim { withAnimation(.easeOut(duration: 0.16)) { self.showing = nil } }
                HighlightCard(
                    highlight: showing.highlight,
                    source: showing.article.displayTitle,
                    atSource: false,
                    onOpen: {
                        onOpen(showing.article, showing.highlight)
                        dismiss()
                    },
                    onRemove: {
                        highlights.remove(showing.highlight.id, from: showing.article)
                        withAnimation(.easeOut(duration: 0.16)) { self.showing = nil }
                    },
                    onClose: { withAnimation(.easeOut(duration: 0.16)) { self.showing = nil } }
                )
                .padding(.horizontal, 18)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: search.isEmpty ? "highlighter" : "magnifyingglass")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(amber.inkFaint)
            Text(search.isEmpty ? "Nothing marked yet." : "Nothing matches that.")
                .font(.system(size: 17, design: .serif))
                .foregroundStyle(amber.inkMuted)
            if search.isEmpty {
                Text("Select a passage while reading and choose Highlight. Add a note to say why it stayed with you.")
                    .font(.system(size: 13.5))
                    .lineSpacing(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(amber.inkFaint)
                    .frame(maxWidth: 340)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
