import SwiftUI
import AppKit

/// How a card is emphasised while something is hovered.
enum DesignerCardState: Equatable {
    case normal, dimmed, highlighted
}

/// One table or view on the diagram: a header, then its columns with key icons and compact types.
/// Its size comes from `DesignerCardLayout`, so the lines can be computed without measuring views.
/// Equatable, so moving another card or panning does not redraw it.
struct DesignerCard: View, Equatable {
    let table: DesignerTable
    let layout: DesignerCardLayout
    let state: DesignerCardState
    /// Columns that take part in a relation of this table (FK icon).
    let foreignColumns: Set<String>
    /// Foreign keys into other databases, column → `db.table.column`.
    let externalTargets: [String: String]
    /// Rows to highlight (the hovered relation's columns).
    let highlighted: Set<String>
    /// The row a relation drag would connect to.
    let dropTarget: String?
    /// The row a relation drag started from.
    let dragSource: String?
    /// The pointer is over the card: show the drag handles (tables only) and row tooltips.
    let hovered: Bool

    private var tint: Color { DBStyle.tint(isView: table.isView) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            ForEach(layout.rows, id: \.self) { i in
                row(table.columns[i])
            }
            if layout.hidden > 0 {
                Text("+ \(layout.hidden) more column\(layout.hidden == 1 ? "" : "s")")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, DesignerMetrics.horizontalPadding + DesignerMetrics.iconSlot)
                    .frame(height: DesignerMetrics.rowHeight)
            }
            if table.columns.isEmpty {
                Text("No columns").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    .padding(.leading, DesignerMetrics.horizontalPadding)
                    .frame(height: DesignerMetrics.rowHeight)
            }
            Spacer(minLength: 0)
        }
        .frame(width: layout.width, height: layout.height, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(state == .highlighted ? tint.opacity(0.85) : Color.primary.opacity(0.12),
                              lineWidth: state == .highlighted ? 1.5 : 1)
        )
        .shadow(color: .black.opacity(state == .highlighted ? 0.16 : 0.07), radius: state == .highlighted ? 8 : 3, y: 1.5)
        .overlay(alignment: .topLeading) { handles }
        .opacity(state == .dimmed ? 0.35 : 1)
        .animation(DBMotion.hover, value: state)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(table.isView ? "View" : "Table") \(table.name), \(table.columns.count) columns")
    }

    private var header: some View {
        HStack(spacing: 8) {
            IconTile(symbol: DBStyle.symbol(isView: table.isView), tint: tint, size: 20, glyphScale: 0.55)
            Text(table.name)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if table.isView {
                TagBadge(title: "VIEW", color: DBStyle.viewTint)
            }
        }
        .padding(.horizontal, DesignerMetrics.horizontalPadding)
        .frame(height: DesignerMetrics.headerHeight - 1)
        .background(tint.opacity(state == .highlighted ? 0.13 : 0.07))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10, style: .continuous))
    }

    private func row(_ c: DesignerColumn) -> some View {
        let isFK = foreignColumns.contains(c.name) || externalTargets[c.name] != nil
        let lit = highlighted.contains(c.name) || dropTarget == c.name || dragSource == c.name
        return HStack(spacing: 0) {
            HStack(spacing: 2) {
                if c.isPrimary {
                    Image(systemName: "key.fill").foregroundStyle(KeyKind.primary.color)
                }
                if isFK {
                    Image(systemName: "link").foregroundStyle(KeyKind.foreign.color)
                }
            }
            .font(.system(size: 9, weight: .bold))
            .frame(width: DesignerMetrics.iconSlot, alignment: .leading)
            Text(c.name)
                .font(.system(size: 11.5, weight: c.isPrimary ? .semibold : .regular, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
                .layoutPriority(1)
            Spacer(minLength: 10)
            DesignerTypeChip(type: c.type)
        }
        .padding(.horizontal, DesignerMetrics.horizontalPadding)
        .frame(height: DesignerMetrics.rowHeight)
        .background(rowBackground(c.name, lit: lit))
        .help(hovered ? rowHelp(c, isFK: isFK) : "")
    }

    @ViewBuilder
    private func rowBackground(_ column: String, lit: Bool) -> some View {
        if dropTarget == column {
            Color.accentColor.opacity(0.22)
        } else if lit {
            KeyKind.foreign.color.opacity(0.14)
        } else {
            Color.clear
        }
    }

    private func rowHelp(_ c: DesignerColumn, isFK: Bool) -> String {
        var parts = ["\(c.name) · \(c.type)"]
        if c.isPrimary { parts.append("primary key") } else if c.key == "UNI" { parts.append("unique") } else if c.key == "MUL" { parts.append("indexed") }
        parts.append(c.nullable ? "NULL allowed" : "NOT NULL")
        if let ext = externalTargets[c.name] { parts.append("refers to \(ext)") }
        return parts.joined(separator: " · ")
    }

    /// The small circles on the right edge of each row: drag one onto another table's column to add a relation.
    @ViewBuilder
    private var handles: some View {
        if (hovered && !table.isView) || dragSource != nil {
            ZStack(alignment: .topLeading) {
                ForEach(Array(layout.rows.enumerated()), id: \.element) { row, i in
                    let name = table.columns[i].name
                    Circle()
                        .fill(dragSource == name ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
                        .frame(width: DesignerMetrics.handleRadius * 2, height: DesignerMetrics.handleRadius * 2)
                        .offset(x: layout.width - DesignerMetrics.handleRadius,
                                y: DesignerMetrics.headerHeight + (CGFloat(row) + 0.5) * DesignerMetrics.rowHeight - DesignerMetrics.handleRadius)
                }
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}

/// A compact, tinted type label (lighter than `TypeChip`, without a tooltip per row).
struct DesignerTypeChip: View {
    let type: String

    var body: some View {
        let family = SQLTypeFamily(type: type)
        Text(DesignerType.compact(type))
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(family.color.opacity(0.12)))
            .foregroundStyle(family.color)
            .fixedSize()
    }
}
