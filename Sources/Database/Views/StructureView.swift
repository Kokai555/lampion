import SwiftUI
import AppKit

/// The Structure tab: one scrolling page with cards for the columns, indexes, foreign keys and the CREATE statement.
struct StructureView: View {
    @EnvironmentObject var m: DBModel
    @State private var showCreate = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isView: Bool { m.currentTableInfo?.isView == true }
    private var canEdit: Bool { !isView }

    /// Widths shared by the column header and the column rows, so they line up.
    private enum W {
        static let position: CGFloat = 22
        static let nameMin: CGFloat = 110
        static let typeMin: CGFloat = 90, typeMax: CGFloat = 190
        static let keysMin: CGFloat = 60, keysMax: CGFloat = 170
        static let defaultMin: CGFloat = 70, defaultMax: CGFloat = 170
        static let actions: CGFloat = 52
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    pageHeader
                    columnsCard.id(StructureSection.columns)
                    if !isView {
                        indexesCard.id(StructureSection.indexes)
                        foreignKeysCard.id(StructureSection.foreignKeys)
                    }
                    createCard.id(StructureSection.sql)
                }
                .frame(maxWidth: 1000)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            }
            .onAppear { reveal(m.structureSection, proxy, animated: false) }
            .onChange(of: m.structureSection) { _, section in reveal(section, proxy, animated: true) }
        }
        .alert("Done", isPresented: Binding(get: { m.infoMessage != nil }, set: { if !$0 { m.infoMessage = nil } })) {
            Button("OK") {}
        } message: { Text(m.infoMessage ?? "") }
    }

    /// Scrolls to the card for `section` (the snapshot tool and older code set `m.structureSection`).
    private func reveal(_ section: StructureSection, _ proxy: ScrollViewProxy, animated: Bool) {
        if section == .sql { showCreate = true }
        if isView && (section == .indexes || section == .foreignKeys) { return }
        DispatchQueue.main.async {
            if animated {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) { proxy.scrollTo(section, anchor: .top) }
            } else {
                proxy.scrollTo(section, anchor: .top)
            }
        }
    }

    // MARK: - Page header

    private var pageHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            if let info = m.currentTableInfo {
                if isView {
                    Label("Views are read-only here. To change one, run ALTER VIEW in the Query tab.", systemImage: "lock.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    if !info.engine.isEmpty { MetaChip(symbol: DBStyle.engineSymbol, text: info.engine) }
                    if !info.collation.isEmpty { MetaChip(symbol: DBStyle.collationSymbol, text: info.collation) }
                    if !info.rows.isEmpty { MetaChip(symbol: DBStyle.rowsSymbol, text: "≈ \(info.rows) rows") }
                    MetaChip(symbol: DBStyle.sizeSymbol, text: ByteCountFormatter.db.string(fromByteCount: info.bytes))
                }
            }
            Spacer(minLength: 12)
            if canEdit {
                Button { m.sheet = .tableOptions } label: {
                    Label("Table Options…", systemImage: "slider.horizontal.3")
                }
                .help("Engine and collation of the table")
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Columns

    private var columnsCard: some View {
        StructureCard(title: "Columns", symbol: "rectangle.split.3x1.fill", tint: DBStyle.tableTint, count: m.columns.count) {
            if canEdit {
                Button { m.sheet = .addColumn } label: { Label("Add Column", systemImage: "plus") }
                    .controlSize(.small)
            }
        } content: {
            if m.columns.isEmpty {
                emptyLine("No columns to show.")
            } else {
                columnHeader
                Divider()
                ForEach(Array(m.columns.enumerated()), id: \.element.id) { i, column in
                    if i > 0 { Divider().padding(.leading, 16 + W.position + 12) }
                    columnRow(i, column)
                }
            }
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 12) {
            ColumnHeading("#").frame(width: W.position, alignment: .trailing)
            ColumnHeading("Name").frame(minWidth: W.nameMin, maxWidth: .infinity, alignment: .leading)
            ColumnHeading("Type").frame(minWidth: W.typeMin, maxWidth: W.typeMax, alignment: .leading)
            ColumnHeading("Keys").frame(minWidth: W.keysMin, maxWidth: W.keysMax, alignment: .leading)
            ColumnHeading("Default").frame(minWidth: W.defaultMin, maxWidth: W.defaultMax, alignment: .leading)
            if canEdit { Color.clear.frame(width: W.actions, height: 1) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private func columnRow(_ i: Int, _ column: ColumnInfo) -> some View {
        HoverRow(onDoubleClick: canEdit ? { editColumn(i) } : nil) { hovering in
            HStack(spacing: 12) {
                Text("\(i + 1)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: W.position, alignment: .trailing)

                VStack(alignment: .leading, spacing: 2) {
                    Text(column.name)
                        .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    if let detail = columnDetail(column) {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                            .help(detail)
                    }
                }
                .frame(minWidth: W.nameMin, maxWidth: .infinity, alignment: .leading)

                TypeChip(type: column.type)
                    .frame(minWidth: W.typeMin, maxWidth: W.typeMax, alignment: .leading)

                HStack(spacing: 4) {
                    ForEach(badges(for: column), id: \.self) { KeyBadge(kind: $0).fixedSize() }
                }
                .frame(minWidth: W.keysMin, maxWidth: W.keysMax, alignment: .leading)

                defaultValue(column)
                    .frame(minWidth: W.defaultMin, maxWidth: W.defaultMax, alignment: .leading)

                if canEdit {
                    HStack(spacing: 2) {
                        RowIconButton(symbol: "pencil", help: "Edit Column") { editColumn(i) }
                        RowIconButton(symbol: "trash", help: "Delete Column", destructive: true) { deleteColumn(column.name) }
                    }
                    .frame(width: W.actions, alignment: .trailing)
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
                }
            }
        }
        .contextMenu {
            if canEdit {
                Button("Edit Column…") { editColumn(i) }
                Button("Delete Column…", role: .destructive) { deleteColumn(column.name) }
                Divider()
            }
            Button("Copy Name") { copy(column.name) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Column \(column.name), \(column.type)")
    }

    /// Comment, extra attributes (other than auto increment) and collation, for the line under the name.
    private func columnDetail(_ column: ColumnInfo) -> String? {
        var parts: [String] = []
        if !column.comment.isEmpty { parts.append(column.comment) }
        let extra = column.extra.replacingOccurrences(of: "auto_increment", with: "", options: .caseInsensitive).trimmed
        if !extra.isEmpty { parts.append(extra) }
        if !column.collation.isEmpty { parts.append(column.collation) }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    /// The column's badges, with FK added after the index markers when a foreign key uses the column.
    private func badges(for column: ColumnInfo) -> [KeyKind] {
        var list = column.badges
        if m.foreignKeys.contains(where: { $0.column == column.name }) {
            let at = list.prefix(while: { $0 == .primary || $0 == .unique || $0 == .index }).count
            list.insert(.foreign, at: at)
        }
        return list
    }

    @ViewBuilder
    private func defaultValue(_ column: ColumnInfo) -> some View {
        if let def = column.def {
            Text(def.isEmpty ? "''" : def)
                .font(DBStyle.monoSmall)
                .foregroundStyle(def.isEmpty ? .secondary : .primary)
                .lineLimit(1).truncationMode(.middle)
                .help(def.isEmpty ? "Empty text" : def)
        } else if column.isNullable && !column.isAutoIncrement {
            NullLabel().help("Defaults to NULL")
        } else {
            Text("—").foregroundStyle(.tertiary).help("No default value")
        }
    }

    private func editColumn(_ i: Int) {
        guard canEdit, i < m.columns.count else { return }
        m.selectedColumns = IndexSet(integer: i)
        m.sheet = .editColumn
    }

    private func deleteColumn(_ name: String) {
        guard canEdit else { return }
        m.confirm = ConfirmRequest(title: "Delete the column “\(name)”?",
                                   message: "All data in the column will be permanently deleted.",
                                   button: "Delete") { m.dropColumn(name) }
    }

    // MARK: - Indexes

    private var indexesCard: some View {
        let list = m.indexList
        return StructureCard(title: "Indexes", symbol: "bolt.fill", tint: .orange, count: list.count) {
            Button { m.sheet = .addIndex } label: { Label("Add Index", systemImage: "plus") }
                .controlSize(.small)
                .disabled(m.columns.isEmpty)
        } content: {
            if list.isEmpty {
                emptyLine("This table has no indexes. Indexes make searching and sorting faster.")
            } else {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, index in
                    if i > 0 { Divider().padding(.leading, 16 + W.position + 12) }
                    indexRow(index)
                }
            }
        }
    }

    private func indexRow(_ index: IndexInfo) -> some View {
        HoverRow { hovering in
            HStack(spacing: 12) {
                Image(systemName: index.isPrimary ? "key.fill" : "bolt.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(index.isPrimary ? Color.yellow : Color.orange)
                    .frame(width: W.position)

                Text(index.name)
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                    .frame(minWidth: 90, maxWidth: 220, alignment: .leading)

                HStack(spacing: 4) {
                    ForEach(Array(index.columns.enumerated()), id: \.offset) { _, column in NameChip(name: column) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(index.columns.joined(separator: ", "))

                HStack(spacing: 4) {
                    if index.isPrimary {
                        TagBadge(title: "PRIMARY", symbol: "key.fill", color: KeyKind.primary.color)
                    } else if index.unique {
                        TagBadge(title: "UNIQUE", color: KeyKind.unique.color)
                    }
                }
                .frame(width: 76, alignment: .leading)

                Text(index.type)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 64, alignment: .leading)

                RowIconButton(symbol: "trash", help: index.isPrimary ? "Delete Primary Key" : "Delete Index",
                              destructive: true) { deleteIndex(index.name) }
                    .frame(width: 28, alignment: .trailing)
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
            }
        }
        .contextMenu {
            Button(index.isPrimary ? "Delete Primary Key…" : "Delete Index…", role: .destructive) { deleteIndex(index.name) }
            Divider()
            Button("Copy Name") { copy(index.name) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Index \(index.name) on \(index.columns.joined(separator: ", "))")
    }

    private func deleteIndex(_ name: String) {
        guard canEdit else { return }
        m.confirm = ConfirmRequest(title: name == "PRIMARY" ? "Delete the primary key?" : "Delete the index “\(name)”?",
                                   message: "The data stays; only the index is removed.",
                                   button: "Delete") { m.dropIndex(name) }
    }

    // MARK: - Foreign keys

    /// One foreign key constraint; multi-column keys come from the server as one row per column.
    private struct ForeignKeyGroup: Identifiable {
        var id: String { name }
        let name, refSchema, refTable, updateRule, deleteRule: String
        var columns: [String]
        var refColumns: [String]
    }

    private var foreignKeyGroups: [ForeignKeyGroup] {
        var groups: [ForeignKeyGroup] = []
        for fk in m.foreignKeys {
            if let at = groups.firstIndex(where: { $0.name == fk.name }) {
                groups[at].columns.append(fk.column)
                groups[at].refColumns.append(fk.refColumn)
            } else {
                groups.append(ForeignKeyGroup(name: fk.name, refSchema: fk.refSchema, refTable: fk.refTable,
                                              updateRule: fk.updateRule, deleteRule: fk.deleteRule,
                                              columns: [fk.column], refColumns: [fk.refColumn]))
            }
        }
        return groups
    }

    private var foreignKeysCard: some View {
        let groups = foreignKeyGroups
        return StructureCard(title: "Foreign Keys", symbol: "link", tint: .purple, count: groups.count) {
            Button { m.sheet = .addForeignKey } label: { Label("Add Foreign Key", systemImage: "plus") }
                .controlSize(.small)
                .disabled(m.columns.isEmpty)
        } content: {
            if groups.isEmpty {
                emptyLine("This table has no foreign keys. A foreign key links a column to a row in another table.")
            } else {
                ForEach(Array(groups.enumerated()), id: \.element.id) { i, fk in
                    if i > 0 { Divider().padding(.leading, 16 + W.position + 12) }
                    foreignKeyRow(fk)
                }
            }
        }
    }

    private func foreignKeyRow(_ fk: ForeignKeyGroup) -> some View {
        let otherSchema = !fk.refSchema.isEmpty && fk.refSchema != m.currentDB
        let target = (otherSchema ? fk.refSchema + "." : "") + fk.refTable
        let refColumns = fk.refColumns.count == 1 ? fk.refColumns[0] : "(" + fk.refColumns.joined(separator: ", ") + ")"
        return HoverRow { hovering in
            HStack(spacing: 12) {
                Image(systemName: "link")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(KeyKind.foreign.color)
                    .frame(width: W.position)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        NameChip(name: fk.columns.joined(separator: ", "), emphasized: true)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Button { openTable(fk) } label: {
                            (Text(target).fontWeight(.semibold) + Text(".").foregroundStyle(.secondary) + Text(refColumns))
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .buttonStyle(.plain)
                        .help("Open “\(fk.refTable)”")
                    }
                    Text(fk.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                RuleChip(label: "ON UPDATE", rule: fk.updateRule)
                RuleChip(label: "ON DELETE", rule: fk.deleteRule)

                RowIconButton(symbol: "trash", help: "Delete Foreign Key", destructive: true) { deleteForeignKey(fk.name) }
                    .frame(width: 28, alignment: .trailing)
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
            }
        }
        .contextMenu {
            Button("Open “\(fk.refTable)”") { openTable(fk) }
            Divider()
            Button("Delete Foreign Key…", role: .destructive) { deleteForeignKey(fk.name) }
            Divider()
            Button("Copy Name") { copy(fk.name) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Foreign key \(fk.name): \(fk.columns.joined(separator: ", ")) references \(target)")
    }

    private func openTable(_ fk: ForeignKeyGroup) {
        guard let db = fk.refSchema.isEmpty ? m.currentDB : fk.refSchema else { return }
        m.selection = .table(db, fk.refTable)
    }

    private func deleteForeignKey(_ name: String) {
        guard canEdit else { return }
        m.confirm = ConfirmRequest(title: "Delete the foreign key “\(name)”?",
                                   message: "The data stays; only the relationship is removed.",
                                   button: "Delete") { m.dropForeignKey(name) }
    }

    // MARK: - CREATE statement

    private var createCard: some View {
        StructureCard(title: isView ? "CREATE VIEW statement" : "CREATE statement",
                      symbol: "scroll.fill", tint: .gray) {
            Button { copy(m.createSQL) } label: { Label("Copy", systemImage: "doc.on.doc") }
                .controlSize(.small)
                .disabled(m.createSQL.isEmpty)
                .help("Copy the statement to the clipboard")
            Button {
                withAnimation(DBMotion.spring(reduceMotion)) { showCreate.toggle() }
            } label: {
                Label(showCreate ? "Hide" : "Show", systemImage: showCreate ? "chevron.up" : "chevron.down")
            }
            .controlSize(.small)
        } content: {
            if showCreate {
                if m.createSQL.isEmpty {
                    emptyLine("The statement is not available.")
                } else {
                    ScrollView(.horizontal) {
                        HighlightedSQL(sql: m.createSQL)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                    .transition(.opacity)
                }
            } else {
                Button {
                    withAnimation(DBMotion.spring(reduceMotion)) { showCreate = true }
                } label: {
                    Text("The SQL that creates this \(isView ? "view" : "table"). Click to show it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
    }

    // MARK: - Helpers

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
