import SwiftUI
import AppKit

struct DBSidebar: View {
    @EnvironmentObject var m: DBModel
    @State private var search = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func matches(_ name: String) -> Bool {
        search.trimmed.isEmpty || name.localizedCaseInsensitiveContains(search.trimmed)
    }
    private var shownDatabases: [String] {
        m.databases.filter { db in matches(db) || (m.tables[db] ?? []).contains { matches($0.name) } }
    }
    private var userDatabases: [String] { shownDatabases.filter { !DBStyle.systemDatabases.contains($0) } }
    private var systemDatabases: [String] { shownDatabases.filter { DBStyle.systemDatabases.contains($0) } }
    private func shownTables(_ db: String) -> [TableInfo] {
        let all = m.tables[db] ?? []
        return matches(db) ? all : all.filter { matches($0.name) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            list
                // A table opened from the detail pane or the designer may be far down: bring it into view.
                .onChange(of: m.selection) { _, node in
                    guard let node else { return }
                    DispatchQueue.main.async { proxy.scrollTo(node) }
                }
        }
    }

    private var list: some View {
        List(selection: $m.selection) {
            Section("Databases") {
                ForEach(userDatabases, id: \.self) { databaseRow($0) }
            }
            // MariaDB's own databases (mysql, sys, information_schema, performance_schema): always listed,
            // in a section that is collapsed until opened. A search opens it when it finds something there.
            if !systemDatabases.isEmpty {
                Section("System", isExpanded: Binding(
                    get: { m.showSystemDatabases || !search.trimmed.isEmpty },
                    set: { m.showSystemDatabases = $0 })) {
                    ForEach(systemDatabases, id: \.self) { databaseRow($0) }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $search, placement: .sidebar, prompt: "Filter")
        .overlay {
            if !search.trimmed.isEmpty && userDatabases.isEmpty && systemDatabases.isEmpty {
                ContentUnavailableView.search(text: search.trimmed)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    // MARK: Rows

    private func databaseRow(_ db: String) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { m.expanded.contains(db) },
            set: { open in setExpanded(db, open) })) {
            ForEach(shownTables(db)) { tableRow($0, in: db) }
        } label: {
            HStack(spacing: 6) {
                Label {
                    Text(db).lineLimit(1).truncationMode(.middle)
                } icon: {
                    Image(systemName: DBStyle.databaseSymbol).foregroundStyle(DBStyle.databaseTint)
                }
                Spacer(minLength: 4)
                if let list = m.tables[db] {
                    Text("\(list.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("\(list.count) tables and views")
                }
            }
            .contextMenu {
                Button("New Table…") {
                    m.selection = .database(db)
                    m.sheet = .newTable
                }
                Button("Export…") { m.export(db: db, table: nil) }
                Button("Import SQL…") { m.importSQL(into: db) }
                Divider()
                Button("Delete Database…") { m.askToDropDatabase(db) }
            }
        }
        .tag(Node.database(db))
        .id(Node.database(db))
    }

    /// Opens a database once its tables are known, so the rows expand with the disclosure instead of
    /// popping in a moment after an empty expansion. Already loaded: opens at once (and refreshes quietly).
    /// The list animates a click on the arrow itself, so the state follows without a second animation:
    /// two animations at once left the selected row drawn over its neighbour.
    private func setExpanded(_ db: String, _ open: Bool) {
        guard open else {
            // A selected table hidden by the fold would leave a stray highlight; select its database instead,
            // as Finder and Xcode do.
            if case .table(db, _) = m.selection { m.selection = .database(db) }
            m.expanded.remove(db)
            return
        }
        if m.tables[db] != nil {
            m.expanded.insert(db)
            m.loadTables(db)
        } else {
            // Rows arrive after the arrow has turned, so this insertion is animated here.
            m.loadTables(db) { withAnimation(DBMotion.spring(reduceMotion)) { _ = m.expanded.insert(db) } }
        }
    }

    private func tableRow(_ t: TableInfo, in db: String) -> some View {
        HStack(spacing: 6) {
            Label {
                Text(t.name).lineLimit(1).truncationMode(.middle)
            } icon: {
                Image(systemName: DBStyle.symbol(isView: t.isView))
                    .foregroundStyle(DBStyle.tint(isView: t.isView))
            }
            Spacer(minLength: 4)
            if let rows = DBCount.compact(t.rows) {
                Text(rows)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("About \(DBCount.full(t.rows) ?? t.rows) rows")
            }
        }
        .tag(Node.table(db, t.name))
        .id(Node.table(db, t.name))
        .contextMenu { TableContextMenu(m: m, db: db, table: t, showOpen: false) }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                let connected = m.connectionError == nil && !m.serverVersion.isEmpty
                Circle()
                    .fill(m.connectionError != nil ? Color.red : connected ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
                    .shadow(color: connected ? Color.green.opacity(0.6) : .clear, radius: 3)
                Text(m.connectionError == nil && !m.serverVersion.isEmpty ? m.serverVersion : "Not connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(m.connectionError ?? "Connected to the local database server")
                Spacer(minLength: 4)
                Menu {
                    Toggle("Show System Databases", isOn: $m.showSystemDatabases)
                    Divider()
                    Button("Refresh") { m.reloadAll() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Sidebar options")
                Button { m.sheet = .newDatabase } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New Database…")
                .accessibilityLabel("New Database")
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
        }
        // Rows scroll under the footer, so it needs its own backdrop.
        .background(.bar)
    }
}

/// The actions for one table or view, shared by the sidebar and the database overview.
struct TableContextMenu: View {
    let m: DBModel
    let db: String
    let table: TableInfo
    var showOpen = true

    var body: some View {
        if showOpen {
            Button("Open") { m.selection = .table(db, table.name) }
            Divider()
        }
        Button("Export…") { m.export(db: db, table: table.name) }
        if !table.isView {
            Button("Empty Table…") { m.askToEmptyTable(table.name, in: db) }
            Button("Table Options…") { m.showTableOptions(table.name, in: db) }
        }
        Divider()
        Button("Delete…") { m.askToDropTable(table.name, in: db, isView: table.isView) }
    }
}

// Confirmations used from several places (sidebar, overview).
extension DBModel {
    func askToEmptyTable(_ table: String, in db: String) {
        confirm = ConfirmRequest(title: "Empty the table “\(table)”?",
                                 message: "All rows in the table will be deleted. This can't be undone.",
                                 button: "Empty") { self.truncateTable(table, in: db) }
    }

    func askToDropTable(_ table: String, in db: String, isView: Bool) {
        confirm = ConfirmRequest(title: "Delete the \(isView ? "view" : "table") “\(table)”?",
                                 message: isView ? "The view will be permanently deleted. The data it shows is not affected."
                                                 : "The table and all its data will be permanently deleted.",
                                 button: "Delete") { self.dropTable(table, in: db, isView: isView) }
    }

    func askToDropDatabase(_ db: String) {
        confirm = ConfirmRequest(title: "Delete the database “\(db)”?",
                                 message: "All tables and data in the database will be permanently deleted.",
                                 button: "Delete") { self.dropDatabase(db) }
    }

    func showTableOptions(_ table: String, in db: String) {
        selection = .table(db, table)
        sheet = .tableOptions
    }
}

/// Row counts as the sidebar and overview show them.
enum DBCount {
    /// "1.2k", "3.4M"; nil when the count is unknown (views).
    static func compact(_ raw: String) -> String? {
        guard let n = Int(raw.trimmed) else { return nil }
        switch n {
        case ..<1_000: return "\(n)"
        case ..<10_000: return trim(Double(n) / 1_000) + "k"
        case ..<1_000_000: return "\(n / 1_000)k"
        case ..<10_000_000: return trim(Double(n) / 1_000_000) + "M"
        case ..<1_000_000_000: return "\(n / 1_000_000)M"
        default: return trim(Double(n) / 1_000_000_000) + "B"
        }
    }

    /// "12,345"; nil when unknown.
    static func full(_ raw: String) -> String? {
        guard let n = Int(raw.trimmed) else { return nil }
        return n.formatted(.number)
    }

    private static func trim(_ v: Double) -> String {
        let s = String(format: "%.1f", (v * 10).rounded(.down) / 10)
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }
}
