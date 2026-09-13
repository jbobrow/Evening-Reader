import SwiftUI
import ImageIO

struct LibraryPane: View {
    @Environment(Library.self) private var library
    @Environment(DisplaySettings.self) private var settings
    @Environment(\.amber) private var amber

    @Binding var scope: Library.Scope
    @Binding var search: String
    @Binding var selection: SavedArticle.ID?

    var onAdd: () -> Void
    /// Back to the front page this list was pushed in over.
    var onBack: () -> Void
    var onOpened: () -> Void
    var onRequestDelete: (SavedArticle) -> Void
    /// Which row's menu is open, and where in the pane it should hang.
    @State private var rowMenu: (article: SavedArticle, y: CGFloat)?
    @State private var rowFrames: [SavedArticle.ID: CGRect] = [:]
    @State private var searchFocused = false

    private var items: [SavedArticle] { library.list(scope: scope, search: search) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            controls
            Hairline()
            list
        }
        .coordinateSpace(name: "libraryPane")
        .overlay { rowMenuOverlay }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 2) {
            AmberIconButton(symbol: "chevron.left", action: onBack)
            VStack(alignment: .leading, spacing: 1) {
                Text("Library")
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                    .foregroundStyle(amber.inkStrong)
                Text("\(library.count(scope: .unread)) unread")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.6)
                    .foregroundStyle(amber.inkFaint)
            }
            .padding(.leading, 4)
            Spacer()
            AmberIconButton(symbol: "plus", action: onAdd)
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(amber.inkFaint)
                AmberTextField(text: $search,
                               isFocused: $searchFocused,
                               placeholder: "Search",
                               palette: settings.palette,
                               showsTexture: settings.showTexture,
                               goLabel: "Done",
                               fontSize: 14,
                               onSubmit: {})
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

            AmberSegmented(selection: $scope, options: Library.Scope.allCases, label: \.label)

            if library.clipboardMayHoldLink && scope != .archive {
                // The offer, with the system's paste control as the key that takes it
                // up — the one way to read the clipboard without the system asking.
                HStack(spacing: 10) {
                    Image(systemName: "doc.on.clipboard")
                    Text("Save the link on your clipboard")
                    Spacer(minLength: 8)
                    // Held at the size the system wants for it. Squeezed below its
                    // own minimum the control keeps its face and drops its label.
                    AmberPasteControl(palette: settings.palette, fill: 0.70, fontSize: 13,
                                      cornerStyle: .medium) { pasted in
                        library.add(pasted: pasted)
                    }
                    .frame(width: 84, height: 34)
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(amber.ink)
                .padding(.leading, 14)
                .padding(.trailing, 5)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(amber.color(0.82, opacity: 0.9))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(amber.color(0.40), lineWidth: 1))
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if items.isEmpty {
                    emptyState
                        .padding(.top, 60)
                        .padding(.horizontal, 22)
                } else {
                    ForEach(items) { item in
                        ArticleRow(article: item, isSelected: item.id == selection)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selection = item.id
                                library.markRead(item)
                                library.noteOpened(item)
                                onOpened()
                            }
                            // Track where the row sits so the menu can hang off it. The
                            // overlay must not take touches or it would eat the tap.
                            .overlay {
                                GeometryReader { geo in
                                    let frame = geo.frame(in: .named("libraryPane"))
                                    Color.clear
                                        .onAppear { rowFrames[item.id] = frame }
                                        .onChange(of: frame) { _, new in rowFrames[item.id] = new }
                                }
                                .allowsHitTesting(false)
                            }
                            // Long press opens the app's own menu. `.contextMenu` would
                            // be a white card in its own window; this one is on the ramp.
                            .onLongPressGesture(minimumDuration: 0.4) {
                                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                                withAnimation(.easeOut(duration: 0.16)) {
                                    rowMenu = (item, rowFrames[item.id]?.maxY ?? 0)
                                }
                            }
                        Hairline(inset: 14)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func menuItems(for item: SavedArticle) -> [AmberMenuItem] {
        var items: [AmberMenuItem] = []
        if item.isArchived {
            items.append(AmberMenuItem(title: "Move to Unread", symbol: "tray.and.arrow.up") {
                library.setArchived(item, false)
            })
        } else {
            items.append(AmberMenuItem(title: "Archive", symbol: "archivebox") {
                library.setArchived(item, true)
            })
        }
        if item.state == .failed {
            items.append(AmberMenuItem(title: "Try Reading Again", symbol: "arrow.clockwise") {
                library.retry(item)
            })
        }
        // A book's `url` is a synthetic identity, not an address — nothing anyone would
        // want on the clipboard.
        if !item.isBook {
            items.append(AmberMenuItem(title: "Copy Link", symbol: "link") {
                UIPasteboard.general.url = item.url
            })
        }
        items.append(AmberMenuItem(title: "Remove", symbol: "trash", isDestructive: true) {
            onRequestDelete(item)
        })
        return items
    }

    /// The row menu, floating over the pane.
    @ViewBuilder
    private var rowMenuOverlay: some View {
        if let rowMenu {
            GeometryReader { geo in
                AmberScrim(opacity: 0.18) {
                    withAnimation(.easeOut(duration: 0.16)) { self.rowMenu = nil }
                }
                AmberMenu(items: menuItems(for: rowMenu.article)) {
                    withAnimation(.easeOut(duration: 0.16)) { self.rowMenu = nil }
                }
                .fixedSize()
                .padding(.leading, 16)
                // Hang below the row, unless that would run past the bottom of the pane.
                .offset(y: min(rowMenu.y + 6, max(0, geo.size.height - 230)))
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
            }
        }
    }


    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: scope == .archive ? "archivebox" : "book.closed")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(amber.inkFaint)
            Text(scope == .archive ? "Nothing archived yet." : "Nothing to read yet.")
                .font(.system(size: 16, design: .serif))
                .foregroundStyle(amber.inkMuted)
            if scope != .archive {
                Text("Share a page to Evening Reader from Safari, share a book from Files, or paste a link.")
                    .font(.system(size: 13))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(amber.inkFaint)
                    // The pane is as wide as the phone, and a line of 13pt run right
                    // across it is a paragraph of a sentence.
                    .frame(maxWidth: 300)
                Button("Add a link", action: onAdd)
                    .buttonStyle(AmberButtonStyle(kind: .solid, size: 14))
                    .padding(.top, 4)
            }
            syncNote
        }
    }

    /// Where the library is living. Worth saying only when the shelf is empty, which is
    /// the one moment the question comes up: on a new device an empty library and a
    /// library that has not arrived yet look exactly alike, and the difference is the
    /// whole of what the reader is trying to find out.
    @ViewBuilder
    private var syncNote: some View {
        switch library.syncState {
        case .cloud:
            EmptyView()
        case .searching:
            noteRow(symbol: "icloud", text: "Looking for your iCloud library…")
        case .local:
            noteRow(symbol: "icloud.slash",
                    text: "iCloud isn't available, so this library stays on this device. Turn on iCloud Drive for Evening Reader in Settings to see what you saved elsewhere.")
        }
    }

    private func noteRow(symbol: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 11))
            Text(text)
                .font(.system(size: 12))
                .lineSpacing(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .foregroundStyle(amber.inkFaint)
        .frame(maxWidth: 300)
        .padding(.top, 18)
    }
}

/// A book's cover, in the one list in the app that otherwise carries no pictures at all.
/// Given the same grayscale-then-amber treatment `PDFReaderView` gives a whole page, so a
/// raw full-colour cover doesn't glare next to type that is otherwise entirely ink on
/// paper.
private struct CoverThumbnail: View {
    @Environment(\.amber) private var amber
    let url: URL
    @State private var image: UIImage?

    init(url: URL) {
        self.url = url
        // One already made is used at once, so a row scrolled back into view does not
        // show its cover arriving a frame late.
        _image = State(initialValue: CoverThumbnails.cached(url))
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .grayscale(1)
                    .colorMultiply(amber.color(0.30))
            } else {
                amber.color(0.80)
            }
        }
        .frame(width: 38, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(amber.rule, lineWidth: 1)
        }
        .task(id: url) {
            if image == nil { image = await CoverThumbnails.image(for: url) }
        }
    }
}

/// Covers at the size the list draws them, made off the main thread and kept.
///
/// A cover is drawn for a bookstore, not a 38pt row: decoding one whole on the main
/// thread — which `UIImage(contentsOfFile:)` in a row's body did, on every render —
/// is a stall per book per scroll. ImageIO can decode straight to a thumbnail instead,
/// which never holds the full picture at all.
enum CoverThumbnails {
    private static let cache = NSCache<NSURL, UIImage>()
    /// Three device pixels per point, at the row's 54pt height, with some room over.
    private static let maxPixel: CGFloat = 200

    static func cached(_ url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    static func image(for url: URL) async -> UIImage? {
        if let hit = cached(url) { return hit }
        let made = await Task.detached(priority: .utility) { Self.downsample(url) }.value
        if let made { cache.setObject(made, forKey: url as NSURL) }
        return made
    }

    private nonisolated static func downsample(_ url: URL) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Row

struct ArticleRow: View {
    @Environment(Library.self) private var library
    @Environment(\.amber) private var amber

    let article: SavedArticle
    let isSelected: Bool

    private var isWorking: Bool { library.working.contains(article.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // The one image anywhere in a deliberately typographic list — kept small, and
            // present only for a book, where a bare title-and-byline reads thinner than
            // it should next to something with an actual cover.
            if article.isBook, let url = library.coverURL(for: article) {
                CoverThumbnail(url: url)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(article.displayTitle)
                    .font(.system(size: 16, weight: .medium, design: .serif))
                    .foregroundStyle(article.readAt == nil ? amber.inkStrong : amber.inkMuted)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Text(article.sourceLabel)
                        .lineLimit(1)
                    if article.state == .ready {
                        Text("·")
                        Text(article.lengthLabel)
                    }
                    if isWorking || article.state == .pending {
                        Text("·")
                        HStack(spacing: 4) {
                            Image(systemName: "text.viewfinder")
                            Text(article.isBook ? "opening" : "reading")
                        }
                    } else if article.state == .failed {
                        Text("·")
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle")
                            Text(article.isBook ? "couldn't open" : "no article text")
                        }
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .tracking(0.4)
                .foregroundStyle(amber.inkFaint)

                if article.lastScroll > 0.02 && article.lastScroll < 0.98 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(amber.color(0.74)).frame(height: 2)
                            Rectangle().fill(amber.color(0.34))
                                .frame(width: geo.size.width * article.lastScroll, height: 2)
                        }
                    }
                    .frame(height: 2)
                    .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? amber.color(0.90) : .clear)
        .overlay(alignment: .leading) {
            if isSelected { amber.color(0.20).frame(width: 3) }
        }
    }
}
