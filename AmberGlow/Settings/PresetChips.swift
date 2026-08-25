import SwiftUI

/// Lays children out in rows, wrapping when a row runs out of width. Preset names vary
/// in length, so a fixed grid would either clip them or leave holes.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = rows(for: subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } +
            lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

/// One saved glow. Tapping applies it; the ✕ forgets it.
struct PresetChip: View {
    @Environment(\.amber) private var amber

    let preset: GlowPreset
    let isActive: Bool
    var apply: () -> Void
    var remove: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            // A dot of the glow itself, so the list is scannable by colour, not just name.
            Circle()
                .fill(swatch)
                .frame(width: 11, height: 11)
                .overlay(Circle().strokeBorder(amber.color(0.35, opacity: 0.45), lineWidth: 1))

            Text(preset.name)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(isActive ? amber.color(0.92) : amber.ink)
                .lineLimit(1)

            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(isActive ? amber.color(0.92).opacity(0.7) : amber.inkFaint)
                    .padding(3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 9)
        .padding(.trailing, 6)
        .padding(.vertical, 7)
        .background {
            Capsule().fill(amber.color(isActive ? 0.28 : 0.79))
        }
        .overlay {
            Capsule().strokeBorder(amber.color(isActive ? 0.28 : 0.62, opacity: 0.5), lineWidth: 1)
        }
        .contentShape(Capsule())
        .onTapGesture(perform: apply)
    }

    /// The page colour this preset would produce.
    private var swatch: Color {
        AmberPalette(warmth: preset.warmth, glow: preset.glow,
                     contrast: preset.contrast, polarity: preset.polarity).color(0.86)
    }
}
