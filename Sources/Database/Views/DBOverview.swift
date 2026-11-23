import SwiftUI
import AppKit

/// The Tables tab of a database: every table and view with its size, sortable; double-click opens one.
struct DBOverview: View {
    @EnvironmentObject var m: DBModel
    @State private var sortOrder = [KeyPathComparator(\TableInfo.name, comparator: .localizedStandard)]
    @State private var picked = Set<TableInfo.ID>()

    var body: some View {
        if let db = m.currentDB {
            content(db)
                .onChange(of: db) { picked = [] }
        } else {
            ContentUnavailableView("No Database Selected", systemImage: "cylinder.split.1x2",
                                   description: Text("Choose a database in the sidebar."))
        }
    }

    @ViewBuilder
    private func content(_ db: String) -> some View {
        if let all = m.tables[db] {
            if all.isEmpty {
                ContentUnavailableView {
                    Label("No Tables", systemImage: "tablecells")
                } description: {
                    Text("“\(db)” has no tables yet. Create one, or import an SQL file.")
                } actions: {
                    HStack {
                        Button("New Table…") { m.sheet = .newTable }.buttonStyle(.borderedProminent)
                        Button("Import SQL…") { m.importSQL(into: db) }
                    }
                }
            } else {
                table(db, all)
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func table(_ db: String, _ all: [TableInfo]) -> some View {
        let list = all.sorted(using: sortOrder)
        let largest = max(1, all.map(\.bytes).max() ?? 1)
        return Table(list, selection: $picked, sortOrder: $sortOrder) {
            TableColumn("Name", value: \TableInfo.name, comparator: .localizedStandard) { t in
                NameCell(table: t)
            }
            .width(min: 140, ideal: 240)

            TableColumn("Rows", value: \TableInfo.overviewRowCount) { t in
                RowsCell(table: t)
            }
            .width(min: 60, ideal: 90)

            TableColumn("Size", value: \TableInfo.bytes) { t in
                SizeCell(bytes: t.bytes, fraction: Double(t.bytes) / Double(largest))
            }
            .width(min: 110, ideal: 140)

            TableColumn("Engine", value: \TableInfo.engine) { t in
                Text(t.isView ? "View" : t.engine).foregroundStyle(t.isView ? .tertiary : .secondary)
            }
            .width(min: 60, ideal: 90)

            TableColumn("Collation", value: \TableInfo.collation) { t in
                Text(t.collation).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .width(min: 100, ideal: 180)
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: TableInfo.ID.self) { ids in
            menu(db, all, ids)
        } primaryAction: { ids in
            if let name = ids.first { m.selection = .table(db, name) }
        }
    }

    @ViewBuilder
    private func menu(_ db: String, _ all: [TableInfo], _ ids: Set<TableInfo.ID>) -> some View {
        let items = all.filter { ids.contains($0.id) }
        if items.count == 1, let t = items.first {
            TableContextMenu(m: m, db: db, table: t)
        } else if items.count > 1 {
            Button("Delete \(items.count) Items…") {
                m.confirm = ConfirmRequest(title: "Delete \(items.count) tables and views?",
                                           message: "\(items.map(\.name).joined(separator: ", ")) and all their data will be permanently deleted.",
                                           button: "Delete") {
                    for t in items { m.dropTable(t.name, in: db, isView: t.isView) }
                }
            }
        } else {
            Button("New Table…") { m.sheet = .newTable }
            Button("Export Database…") { m.export(db: db, table: nil) }
            Button("Import SQL…") { m.importSQL(into: db) }
        }
    }
}

// MARK: - Cells

private struct NameCell: View {
    let table: TableInfo

    var body: some View {
        Label {
            Text(table.name).lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: DBStyle.symbol(isView: table.isView))
                .foregroundStyle(DBStyle.tint(isView: table.isView))
        }
    }
}

private struct RowsCell: View {
    let table: TableInfo

    var body: some View {
        Group {
            if let rows = DBCount.full(table.rows) {
                Text(rows).monospacedDigit()
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct SizeCell: View {
    let bytes: Int64
    let fraction: Double

    var body: some View {
        HStack(spacing: 8) {
            // Views have no storage of their own: show a dash, like the row count does.
            Text(bytes > 0 ? ByteCountFormatter.db.string(fromByteCount: bytes) : "—")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 52, alignment: .trailing)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(DBStyle.databaseTint.opacity(0.75))
                    .frame(width: bytes > 0 ? max(3, 44 * min(1, fraction)) : 0)
            }
            .frame(width: 44, height: 4)
            .accessibilityHidden(true)
        }
    }
}

fileprivate extension TableInfo {
    /// Approximate rows as a number for sorting; views sort first.
    var overviewRowCount: Int { Int(rows.trimmed) ?? -1 }
}
