import SwiftUI
import AppKit

struct DatabaseWindow: View {
    @EnvironmentObject var m: DBModel

    var body: some View {
        NavigationSplitView {
            DBSidebar().navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 420)
        } detail: {
            VStack(spacing: 0) {
                if let e = m.connectionError {
                    VStack(spacing: 12) {
                        Image(systemName: "bolt.horizontal.circle").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("No Connection to the Database").font(.title3.weight(.semibold))
                        Text(e).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .textSelection(.enabled).frame(maxWidth: 520)
                        Button("Try Again") { m.reloadAll() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    DBDetail()
                }
                Divider()
                SQLLogView().frame(height: 92)
            }
            .alert(m.confirm?.title ?? "", isPresented: Binding(get: { m.confirm != nil }, set: { if !$0 { m.confirm = nil } }),
                   presenting: m.confirm) { c in
                Button(c.button, role: .destructive) { c.action() }
                Button("Cancel", role: .cancel) {}
            } message: { c in Text(c.message) }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItemGroup {
                if m.busyCount > 0 { ProgressView().controlSize(.small) }
                Button { m.reloadAll() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Reload databases and tables")
                Menu {
                    Button("New Database…") { m.sheet = .newDatabase }
                    Button("New Table…") { m.sheet = .newTable }.disabled(m.currentDB == nil)
                } label: { Label("New", systemImage: "plus") }
                    .help("New database or table")
                Button { if let d = m.currentDB { m.export(db: d, table: m.currentTable) } } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Save the selected database or table to an SQL file").disabled(m.currentDB == nil)
                Button { m.importSQL(into: m.currentDB) } label: { Label("Import", systemImage: "square.and.arrow.down") }
                    .help("Run an SQL file in the selected database")
            }
        }
        .frame(minWidth: 960, minHeight: 600)
        .onAppear {
            m.reloadAll()
            if CommandLine.arguments.contains("--dbtest") { m.runSelfTest() }
        }
        .onChange(of: m.selection) { m.selectionChanged() }
        .sheet(item: $m.sheet) { sheet in
            switch sheet {
            case .newDatabase: NewDatabaseSheet()
            case .newTable: NewTableSheet()
            case .addColumn: AddColumnSheet()
            case .insertRow: InsertRowSheet()
            }
        }
        .alert("Error", isPresented: Binding(get: { m.alertMessage != nil }, set: { if !$0 { m.alertMessage = nil } })) {
            Button("OK") {}
        } message: { Text(m.alertMessage ?? "") }
    }

    private var title: String {
        switch m.selection {
        case nil: return "Database Manager"
        case .database(let d): return d
        case .table(let d, let t): return "\(d) › \(t)"
        }
    }
}
