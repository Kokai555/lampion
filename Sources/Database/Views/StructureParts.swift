import SwiftUI
import AppKit

// Building blocks for the Structure tab (StructureView.swift).

/// A rounded card with a header row (tinted icon, title, count, trailing actions) and full-width rows below.
struct StructureCard<Actions: View, Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    var count: Int? = nil
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content

    var body: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    IconTile(symbol: symbol, tint: tint, size: 24)
                    Text(title).font(.headline)
                    if let count { CountBadge(count: count) }
                    Spacer(minLength: 12)
                    actions
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                Divider()
                content
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

/// The small grey number next to a card title.
struct CountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption.weight(.medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 1.5)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

/// A row that highlights under the pointer and reports whether it is hovered, so it can reveal its actions.
struct HoverRow<Content: View>: View {
    var onDoubleClick: (() -> Void)? = nil
    @ViewBuilder var content: (_ hovering: Bool) -> Content
    @State private var hovering = false

    var body: some View {
        content(hovering)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(hovering ? 0.045 : 0))
            .contentShape(Rectangle())
            // Highlight and revealed actions fade instead of blinking; scoped to this row's hover only.
            .animation(DBMotion.hover, value: hovering)
            .onHover { hovering = $0 }
            .modifier(DoubleClick(action: onDoubleClick))
    }
}

private struct DoubleClick: ViewModifier {
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content.onTapGesture(count: 2, perform: action)
        } else {
            content
        }
    }
}

/// Small borderless icon button for row actions (edit, delete).
struct RowIconButton: View {
    let symbol: String
    let help: String
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(destructive ? AnyShapeStyle(Color.red.opacity(0.85)) : AnyShapeStyle(.secondary))
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Upper-case grey label above a list, like the facts on the overview.
struct ColumnHeading: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .kerning(0.4)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
    }
}

/// A column name in a soft grey box, used for index columns and foreign keys.
struct NameChip: View {
    let name: String
    var emphasized = false

    var body: some View {
        Text(name)
            .font(.system(size: 11, weight: emphasized ? .semibold : .regular, design: .monospaced))
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.07)))
    }
}

/// A capsule label with free text, for PRIMARY / UNIQUE / FULLTEXT on indexes.
struct TagBadge: View {
    let title: String
    var symbol: String? = nil
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 8.5, weight: .bold)) }
            Text(title).font(.system(size: 9.5, weight: .semibold))
        }
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.15)))
        .foregroundStyle(color)
        .fixedSize()
    }
}

/// "ON DELETE  CASCADE" as a small grey chip.
struct RuleChip: View {
    let label: String
    let rule: String

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            Text(rule.isEmpty ? "—" : rule)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(rule == "CASCADE" ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
        }
        .padding(.horizontal, 6).padding(.vertical, 2.5)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .fixedSize()
        .help("\(label.capitalized): \(rule)")
    }
}

/// The CREATE statement, coloured. Its own view so the tokenizer runs only when the SQL changes,
/// not every time the Structure tab redraws.
struct HighlightedSQL: View, Equatable {
    let sql: String

    var body: some View {
        Text(StructureSQL.highlighted(sql))
            .font(DBStyle.mono)
            .lineSpacing(2)
            .textSelection(.enabled)
            .fixedSize(horizontal: true, vertical: true)
            .padding(16)
    }
}

/// SQL with keyword colouring, using the editor's tokenizer (read-only).
enum StructureSQL {
    static func highlighted(_ sql: String) -> AttributedString {
        var out = AttributedString(sql)
        for token in SQLSyntax.tokenize(sql) where token.kind != .error {
            guard let r = Range(token.range, in: sql), let ar = Range(r, in: out) else { continue }
            out[ar].foregroundColor = Color(nsColor: SQLSyntax.color(token.kind))
        }
        return out
    }
}
