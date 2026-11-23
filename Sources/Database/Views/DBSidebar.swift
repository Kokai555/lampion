import SwiftUI
import AppKit

struct DBSidebar: View {
    @EnvironmentObject var m: DBModel
    @State private var search = ""

    private func matches(_ name: String) -> Bool {
        search.trimmed.isEmpty || name.localizedCaseInsensitiveContains(search.trimmed)
    }
    private var shownDatabases: [String] {
        m.databases.filter { db in matches(db) || (m.tables[db] ?? []).contains { matches($0.name) } }
    }
    private func shownTables(_ db: String) -> [TableInfo] {
        let all = m.tables[db] ?? []
        return matches(db) ? all : all.filter { matches($0.name) }
    }

    var body: some View {
        List(selection: $m.selection) {
            ForEach(shownDatabases, id: \.self) { db in
                DisclosureGroup(isExpanded: Binding(
                    get: { m.expanded.contains(db) },
                    set: { open in
                        if open { m.expanded.insert(db); m.loadTables(db) }
                        else { m.expanded.remove(db) }
                    })) {
                    ForEach(shownTables(db)) { t in
                        Label(t.name, systemImage: t.isView ? "eye" : "tablecells")
                            .tag(Node.table(db, t.name))
                            .contextMenu {
                                Button("Export…") { m.export(db: db, table: t.name) }
                                if !t.isView {
                                    Button("Empty Table…") {
                                        m.confirm = ConfirmRequest(title: "Empty the table “\(t.name)”?",
                                                                   message: "All rows in the table will be deleted. This can't be undone.",
                                                                   button: "Empty") { m.truncateTable(t.name, in: db) }
                                    }
                                }
                                Button("Delete…") {
                                    m.confirm = ConfirmRequest(title: "Delete the table “\(t.name)”?",
                                                               message: "The table and all its data will be permanently deleted.",
                                                               button: "Delete") { m.dropTable(t.name, in: db, isView: t.isView) }
                                }
                            }
                    }
                } label: {
                    Label(db, systemImage: "cylinder")
                        .contextMenu {
                            Button("Export…") { m.export(db: db, table: nil) }
                            Button("Delete Database…") {
                                m.confirm = ConfirmRequest(title: "Delete the database “\(db)”?",
                                                           message: "All tables and data in the database will be permanently deleted.",
                                                           button: "Delete") { m.dropDatabase(db) }
                            }
                        }
                }
                .tag(Node.database(db))
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $search, placement: .sidebar, prompt: "Filter")
    }
}
