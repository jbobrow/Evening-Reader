import SwiftUI

struct LibraryPane: View {
    @Environment(Library.self) private var library
    @Environment(DisplaySettings.self) private var settings
    @Environment(\.amber) private var amber

    @Binding var scope: Library.Scope
    @Binding var search: String
    @Binding var selection: SavedArticle.ID?

    var onAdd: () -> Void
    var onBrowse: () -> Void
    var onClose: (() -> Void)?
    var onOpened: () -> Void
    var onGlow: () -> Void
    var panelOpen: Bool
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
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text("AMBER GLOW")
                    .font(.system(size: 13, weight: .bold, design: .default))
                    .tracking(2.6)
                    .foregroundStyle(amber.inkStrong)
                Text("\(library.count(scope: .unread)) unread")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.6)
                    .foregroundStyle(amber.inkFaint)
            }
            Spacer()
            AmberIconButton(symbol: "plus", action: onAdd)
            AmberIconButton(symbol: "globe", action: onBrowse)
            AmberIconButton(symbol: "sun.max", isActive: panelOpen, action: onGlow)
            if let onClose {
                AmberIconButton(symbol: "sidebar.left", action: onClose)
            }
        }
        .padding(.horizontal, 16)
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
                Button {
                    library.addFromClipboard()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.clipboard")
                        Text("Save the link on your clipboard")
                        Spacer()
                    }
                    .font(.system(size: 13))
                }
                .buttonStyle(AmberButtonStyle(kind: .outline, size: 13))
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
        items.append(AmberMenuItem(title: "Copy Link", symbol: "link") {
            UIPasteboard.general.url = item.url
        })
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
                Text("Share a page to Amber Glow from Safari, paste a link, or browse the web here.")
                    .font(.system(size: 13))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(amber.inkFaint)
                Button("Add a link", action: onAdd)
                    .buttonStyle(AmberButtonStyle(kind: .solid, size: 14))
                    .padding(.top, 4)
            }
        }
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
        VStack(alignment: .leading, spacing: 6) {
            Text(article.displayTitle)
                .font(.system(size: 16, weight: .medium, design: .serif))
                .foregroundStyle(article.readAt == nil ? amber.inkStrong : amber.inkMuted)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Text(article.host)
                    .lineLimit(1)
                if article.state == .ready {
                    Text("·")
                    Text("\(article.estimatedMinutes) min")
                }
                if isWorking || article.state == .pending {
                    Text("·")
                    HStack(spacing: 4) {
                        Image(systemName: "text.viewfinder")
                        Text("reading")
                    }
                } else if article.state == .failed {
                    Text("·")
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                        Text("no article text")
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
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? amber.color(0.90) : .clear)
        .overlay(alignment: .leading) {
            if isSelected { amber.color(0.20).frame(width: 3) }
        }
    }
}
