import SwiftUI

/// What an app shows on its About page. Each app fills one in; `AboutView`
/// itself is the same across all of Jon Bobrow's apps, so this file can be
/// copied between them unchanged, along with Signature.swift.
struct AboutApp {
    var name: String
    var icon: Image
    /// A sentence or two on what the app does.
    var description: String
    var website: URL?
    var support: URL?
    var privacy: URL?
    /// Small print at the bottom, such as where the data comes from.
    var credits: String?
    /// The number in the app's App Store link. Adds "Share this app" and
    /// "Rate this app".
    var appStoreID: String?

    var appStore: URL? {
        appStoreID.flatMap { URL(string: "https://apps.apple.com/app/id\($0)") }
    }
}

/// How an app that paints its own surfaces dresses its About page: the ink
/// for text and icons, and the face of each row. Apps on the system's colors
/// leave it alone.
struct AboutStyle {
    var ink: Color = .primary
    var secondaryInk: Color = .secondary
    var faintInk: Color = AboutStyle.tertiaryLabel
    /// Behind each row. `nil` keeps the list's own.
    var rowBackground: Color?
    /// Between rows. `nil` keeps the list's own.
    var separator: Color?
    /// Draws each group of rows as a card outlined in this colour — the outline and
    /// the lines between rows both — over whatever is behind the page, instead of
    /// the system's grouped list. For an app that lights its own page and wants it
    /// to show through. `nil` keeps the list.
    var cardOutline: Color?

    #if canImport(UIKit)
    static let tertiaryLabel = Color(uiColor: .tertiaryLabel)
    #else
    static let tertiaryLabel = Color(nsColor: .tertiaryLabelColor)
    #endif
}

extension EnvironmentValues {
    @Entry var aboutStyle = AboutStyle()
    /// Set inside a card, where each row draws its own padding and its own line.
    @Entry fileprivate var aboutRowInCard = false
}

/// The About page: icon, name, version and description, the app's own rows
/// (like "How it works"), sharing and rating it, links to its website,
/// support and privacy policy, and "Apps by Jon Bobrow" in his hand, linking
/// to the rest of the apps.
struct AboutView<AppRows: View>: View {
    let app: AboutApp
    @ViewBuilder var appRows: AppRows

    @Environment(\.aboutStyle) private var style

    /// Every app links here.
    static var moreApps: URL { URL(string: "https://app.jonbobrow.com")! }

    var body: some View {
        if let outline = style.cardOutline {
            cards(outline: outline)
        } else {
            list
        }
    }

    /// The groups as outlined cards, laid out by hand rather than by `List`, which
    /// gives a group no outline of its own.
    private func cards(outline: Color) -> some View {
        ScrollView {
            VStack(spacing: 28) {
                header
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 4)
                if AppRows.self != EmptyView.self || app.appStore != nil {
                    card(outline: outline) { appAndStoreRows }
                }
                card(outline: outline) { webRows }
                footer
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
    }

    /// One group. Every row draws a line along its top, in the outline's colour; the
    /// first one's lies under the outline itself, so only the lines between rows show.
    private func card<Rows: View>(outline: Color,
                                  @ViewBuilder rows: () -> Rows) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return VStack(spacing: 0) { rows() }
            .buttonStyle(.plain)
            .environment(\.aboutRowInCard, true)
            .background(style.rowBackground ?? .clear, in: shape)
            .clipShape(shape)
            .overlay { shape.strokeBorder(outline, lineWidth: 1) }
    }

    private var list: some View {
        List {
            Section {
                header
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }

            // Skipped when there's nothing for it, rather than left as a gap
            if AppRows.self != EmptyView.self || app.appStore != nil {
                Section {
                    Group { appAndStoreRows }
                        .listRowBackground(style.rowBackground)
                        .listRowSeparatorTint(style.separator)
                }
            }

            Section {
                Group { webRows }
                    .listRowBackground(style.rowBackground)
                    .listRowSeparatorTint(style.separator)
            }

            Section {
                footer
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
    }

    /// The app's own rows, then sharing and rating it.
    @ViewBuilder private var appAndStoreRows: some View {
        appRows
        if let appStore = app.appStore {
            ShareLink(item: appStore, preview: SharePreview(app.name, image: app.icon)) {
                AboutRowLabel(title: "Share this app", systemImage: "square.and.arrow.up")
            }
            if let review = URL(string: appStore.absoluteString + "?action=write-review") {
                Link(destination: review) {
                    AboutRowLabel(title: "Rate this app", systemImage: "star")
                }
            }
        }
    }

    @ViewBuilder private var webRows: some View {
        if let website = app.website {
            AboutLink(title: "Website", systemImage: "safari", url: website)
        }
        if let support = app.support {
            AboutLink(title: "Support", systemImage: "questionmark.bubble", url: support)
        }
        if let privacy = app.privacy {
            AboutLink(title: "Privacy policy", systemImage: "hand.raised", url: privacy)
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            app.icon
                .resizable()
                .scaledToFit()
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                .accessibilityHidden(true)
            VStack(spacing: 2) {
                Text(app.name)
                    .font(.title2.bold())
                    .foregroundStyle(style.ink)
                if let version = Self.version {
                    Text(version)
                        .font(.footnote)
                        .foregroundStyle(style.secondaryInk)
                }
            }
            Text(app.description)
                .font(.body)
                .foregroundStyle(style.secondaryInk)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    private var footer: some View {
        VStack(spacing: 12) {
            if let credits = app.credits {
                Text(credits)
                    .font(.footnote)
                    .foregroundStyle(style.secondaryInk)
                    .multilineTextAlignment(.center)
            }
            Link(destination: Self.moreApps) {
                SignatureLabel(signature: .appsBy, mark: .linkOut)
            }
            .buttonStyle(.plain)
            .foregroundStyle(style.ink)   // the signature takes its gray from this
            .accessibilityHint("Opens app.jonbobrow.com")
        }
    }

    /// "Version 1.3 (14)"
    private static var version: String? {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return nil }
        let build = info?["CFBundleVersion"] as? String
        return "Version \(short)" + (build.map { " (\($0))" } ?? "")
    }
}

/// A row for an app's own section: an icon, a title, and a chevron.
struct AboutRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AboutRowLabel(title: title, systemImage: systemImage)
        }
    }
}

/// A row that opens a web page, for an app's own section.
struct AboutLink: View {
    let title: String
    let systemImage: String
    let url: URL

    var body: some View {
        Link(destination: url) {
            AboutRowLabel(title: title, systemImage: systemImage, accessory: "arrow.up.right")
        }
    }
}

/// An icon, a title, and a chevron or arrow at the trailing edge.
private struct AboutRowLabel: View {
    let title: String
    let systemImage: String
    var accessory = "chevron.right"

    @Environment(\.aboutStyle) private var style
    @Environment(\.aboutRowInCard) private var inCard

    var body: some View {
        if inCard {
            // What `List` would otherwise give a row: its height, its insets, the
            // icon in a column of its own, and the line above, from the title on.
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.body)
                    .frame(width: 26)
                    .foregroundStyle(style.ink)
                Text(title)
                    .foregroundStyle(style.ink)
                Spacer(minLength: 8)
                Image(systemName: accessory)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(style.faintInk)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .overlay(alignment: .top) {
                (style.cardOutline ?? .clear)
                    .frame(height: 1)
                    .padding(.leading, 56)
            }
            .contentShape(Rectangle())
        } else {
            HStack {
                Label(title, systemImage: systemImage)
                    .foregroundStyle(style.ink)
                Spacer()
                Image(systemName: accessory)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(style.faintInk)   // not the row's tint
            }
            .contentShape(Rectangle())
        }
    }
}
