import SwiftUI
import AppKit

/// The strip above the detail content: what is selected, and its key facts.
struct DBSelectionHeader: View {
    @EnvironmentObject var m: DBModel
    /// Default collation of each database, fetched on demand.
    @State private var dbCollations: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                switch m.selection {
                case .table(let db, let name): tableHeader(db: db, name: name)
                case .database(let db): databaseHeader(db)
                case nil: EmptyView()
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            Divider()
        }
    }

    // MARK: Table or view

    @ViewBuilder
    private func tableHeader(db: String, name: String) -> some View {
        let info = m.tables[db]?.first { $0.name == name }
        let isView = info?.isView ?? false
        IconTile(symbol: DBStyle.symbol(isView: isView), tint: DBStyle.tint(isView: isView), size: 32)
        titleBlock(name, subtitle: db)
        Spacer(minLength: 12)
        if let info {
            if info.isView {
                MetaChip(symbol: "eye", text: "View").help("A saved query that behaves like a read-only table")
            } else {
                ViewThatFits(in: .horizontal) {
                    tableChips(info, collation: true)
                    tableChips(info, collation: false)
                    EmptyView()
                }
            }
        }
    }

    private func tableChips(_ info: TableInfo, collation: Bool) -> some View {
        HStack(spacing: 14) {
            if !info.engine.isEmpty { MetaChip(symbol: DBStyle.engineSymbol, text: info.engine).help("Storage engine") }
            if let rows = DBCount.full(info.rows) {
                MetaChip(symbol: DBStyle.rowsSymbol, text: "~\(rows) rows").help("Approximate number of rows")
            }
            MetaChip(symbol: DBStyle.sizeSymbol, text: ByteCountFormatter.db.string(fromByteCount: info.bytes))
                .help("Data and index size on disk")
            if collation && !info.collation.isEmpty {
                MetaChip(symbol: DBStyle.collationSymbol, text: info.collation).help("Collation")
            }
        }
        .fixedSize()
    }

    // MARK: Database

    @ViewBuilder
    private func databaseHeader(_ db: String) -> some View {
        IconTile(symbol: DBStyle.databaseSymbol, tint: DBStyle.databaseTint, size: 32)
        titleBlock(db, subtitle: databaseSummary(db))
            .task(id: db) { loadCollation(db) }
        Spacer(minLength: 12)
        if m.tab == .tables {
            HStack(spacing: 8) {
                Button { m.sheet = .newTable } label: { Label("New Table…", systemImage: "plus") }
                    .help("Create a table in \(db)")
                Button { m.export(db: db, table: nil) } label: { Label("Export Database…", systemImage: DBStyle.exportSymbol) }
                    .help("Save the whole database to an SQL file")
                Button { m.importSQL(into: db) } label: { Label("Import SQL…", systemImage: DBStyle.importSymbol) }
                    .help("Run an SQL file in \(db)")
            }
            .labelStyle(.titleAndIcon)
            .fixedSize()
        }
    }

    private func databaseSummary(_ db: String) -> String {
        guard let list = m.tables[db] else { return "Loading…" }
        let views = list.filter(\.isView).count
        let tables = list.count - views
        var parts = [tables == 1 ? "1 table" : "\(tables) tables"]
        if views > 0 { parts.append(views == 1 ? "1 view" : "\(views) views") }
        parts.append(ByteCountFormatter.db.string(fromByteCount: list.reduce(0) { $0 + $1.bytes }))
        if let c = dbCollations[db], !c.isEmpty { parts.append(c) }
        return parts.joined(separator: " · ")
    }

    private func loadCollation(_ db: String) {
        guard dbCollations[db] == nil else { return }
        m.exec("SELECT DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = \(SQL.val(db))", quiet: true) { r in
            if let c = r.sets.first?.rows.first?.first ?? nil { dbCollations[db] = c }
        }
    }

    // MARK: Shared

    private func titleBlock(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
            Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        }
        .layoutPriority(1)
    }
}
