import SwiftUI

/// What the sheet is opened with: a blank, a site being changed, or a page the browser
/// is on that is worth keeping a door to.
struct SiteDraft: Identifiable {
    let id = UUID()
    var existing: Site?
    var name = ""
    var address = ""
    var symbol: String?

    init() {}

    init(editing site: Site) {
        existing = site
        name = site.name
        address = site.url.absoluteString
        symbol = site.symbol
    }

    init(name: String, address: String) {
        self.name = name
        self.address = address
    }
}

/// Add a site, or change one: a name, an address, and what its tile shows.
struct NewSiteSheet: View {
    @Environment(\.amber) private var amber
    @Environment(\.dismiss) private var dismiss
    @Environment(Sites.self) private var sites
    @Environment(DisplaySettings.self) private var settings
    @Environment(\.horizontalSizeClass) private var sizeClass

    let draft: SiteDraft

    @State private var name = ""
    @State private var address = ""
    @State private var symbol: String?
    @State private var nameFocused = false
    @State private var addressFocused = false
    /// The site's own icon, fetched as the address settles.
    @State private var icon: UIImage?
    @State private var fetching = false
    @State private var fetchTask: Task<Void, Never>?
    @State private var problem: String?

    /// A small fixed set. Enough to say what a site is for; few enough to choose from.
    static let symbols = [
        "books.vertical", "book", "newspaper", "camera", "play.rectangle",
        "film", "music.note", "headphones", "mic", "envelope",
        "bubble.left", "star", "bookmark", "pencil", "map",
        "leaf", "moon", "globe", "cart", "house",
    ]

    private var isCompact: Bool { sizeClass == .compact }
    private var isEditing: Bool { draft.existing != nil }

    /// What the tile will show, as it stands: the name, or the address once there is
    /// one, or nothing at all rather than a letter borrowed from nowhere.
    private var preview: Site {
        let url = BrowserModel.url(from: address) ?? URL(string: "https://")!
        return Site(name: name, url: url, symbol: nil)
    }

    /// A page on a phone, scrolling under the keyboard rather than being shoved up by
    /// it; a card on a wide panel.
    var body: some View {
        if isCompact {
            ScrollView {
                form
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(GlowSurface(level: 0.9))
            .statusBarHidden(true)
        } else {
            form.frame(width: 460)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(isEditing ? "Edit site" : "New site")
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                    .foregroundStyle(amber.inkStrong)
                Spacer()
                AmberIconButton(symbol: "xmark") { dismiss() }
            }

            VStack(alignment: .leading, spacing: 8) {
                AmberCaption(text: "Name")
                field(text: $name, focused: $nameFocused, placeholder: "Libby",
                      showsDotCom: false, goLabel: "Next", monospaced: false) {
                    addressFocused = true
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                AmberCaption(text: "Address")
                field(text: $address, focused: $addressFocused, placeholder: "libbyapp.com",
                      showsDotCom: true, goLabel: "Done", monospaced: true) {
                    fetchIcon()
                }
                if let problem {
                    Text(problem)
                        .font(.system(size: 12))
                        .foregroundStyle(amber.inkMuted)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                AmberCaption(text: "Icon")
                ownIconRow
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5),
                          spacing: 10) {
                    ForEach(Self.symbols, id: \.self) { candidate in
                        Button { symbol = candidate } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(amber.color(0.78))
                                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(amber.rule, lineWidth: 1))
                                Image(systemName: candidate)
                                    .font(.system(size: 22, weight: .regular))
                                    .foregroundStyle(amber.inkStrong)
                            }
                            .frame(height: 56)
                            .overlay(selectionRing(symbol == candidate))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Button(action: commit) {
                Text(isEditing ? "Save" : "Add to Sites")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AmberButtonStyle(kind: .solid, size: 15))
            .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(isCompact ? 22 : 26)
        .padding(.bottom, isCompact ? 12 : 0)
        .onAppear {
            name = draft.name
            address = draft.address
            symbol = draft.symbol
            if let existing = draft.existing { icon = sites.icon(for: existing) }
            if address.isEmpty { nameFocused = true } else if icon == nil { fetchIcon() }
        }
        .onChange(of: address) { _, _ in scheduleFetch() }
    }

    private var ownIconRow: some View {
        Button { symbol = nil } label: {
            HStack(spacing: 14) {
                ZStack {
                    SiteFace(site: preview, icon: icon)
                    if fetching, icon == nil {
                        AmberSpinner()
                    }
                }
                .overlay(selectionRing(symbol == nil))
                VStack(alignment: .leading, spacing: 3) {
                    Text("The site's own icon")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(amber.inkStrong)
                    Text(icon == nil && !fetching
                         ? "Its first letter until one is found."
                         : "In the panel's ink, like a page is.")
                        .font(.system(size: 12))
                        .foregroundStyle(amber.inkFaint)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func selectionRing(_ on: Bool) -> some View {
        if on {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(amber.color(0.14), lineWidth: 2)
        }
    }

    private func field(text: Binding<String>, focused: Binding<Bool>, placeholder: String,
                       showsDotCom: Bool, goLabel: String, monospaced: Bool,
                       onSubmit: @escaping () -> Void) -> some View {
        AmberTextField(text: text,
                       isFocused: focused,
                       placeholder: placeholder,
                       palette: settings.palette,
                       showsTexture: settings.showTexture,
                       showsDotCom: showsDotCom,
                       goLabel: goLabel,
                       monospaced: monospaced,
                       fontSize: 15,
                       onSubmit: onSubmit)
            .frame(height: 22)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(amber.color(0.80))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(amber.rule, lineWidth: 1))
            )
    }

    /// The address is looked up a moment after it stops changing, not on every key.
    private func scheduleFetch() {
        fetchTask?.cancel()
        fetchTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            fetchIcon()
        }
    }

    private func fetchIcon() {
        guard let url = BrowserModel.url(from: address) else { return }
        fetching = true
        Task {
            let found = await Sites.fetchIcon(for: url)
            // The address may have moved on while this one was being looked up.
            guard BrowserModel.url(from: address) == url else { return }
            icon = found
            fetching = false
        }
    }

    private func commit() {
        guard let url = BrowserModel.url(from: address) else {
            problem = "That doesn't look like a web address."
            return
        }
        var site = draft.existing ?? Site(name: "", url: url)
        site.url = url
        site.symbol = symbol
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        site.name = trimmed.isEmpty ? site.host : trimmed
        sites.save(site, icon: icon)
        dismiss()
    }
}
