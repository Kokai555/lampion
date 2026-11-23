import SwiftUI
import AppKit

struct DatabaseWindow: View {
    @EnvironmentObject var m: DBModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView {
            DBSidebar().navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 420)
        } detail: {
            VStack(spacing: 0) {
                if let e = m.connectionError {
                    connectionErrorView(e).transition(.opacity)
                } else {
                    DBDetail().transition(.opacity)
                }
                // Sizes itself: a one-line console that can be opened.
                SQLLogView()
            }
            .animation(DBMotion.fade(reduceMotion), value: m.connectionError == nil)
            .alert(m.confirm?.title ?? "", isPresented: Binding(get: { m.confirm != nil }, set: { if !$0 { m.confirm = nil } }),
                   presenting: m.confirm) { c in
                Button(c.button, role: .destructive) { c.action() }
                Button("Cancel", role: .cancel) {}
            } message: { c in Text(c.message) }
        }
        .navigationTitle(title)
        .toolbar { toolbar }
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
            case .addColumn: ColumnSheet(editing: nil)
            case .editColumn: ColumnSheet(editing: m.selectedColumns.first.flatMap { $0 < m.columns.count ? m.columns[$0] : nil })
            case .addIndex: IndexSheet()
            case .addForeignKey: ForeignKeySheet()
            case .tableOptions: TableOptionsSheet()
            case .insertRow: InsertRowSheet()
            }
        }
        .alert("Error", isPresented: Binding(get: { m.alertMessage != nil }, set: { if !$0 { m.alertMessage = nil } })) {
            Button("OK") {}
        } message: { Text(m.alertMessage ?? "") }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $m.tab) {
                ForEach(m.availableTabs, id: \.self) { t in
                    Label(t.rawValue, systemImage: t.toolbarSymbol).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.titleAndIcon)
            .labelsHidden()
            .fixedSize()
            .disabled(m.connectionError != nil)
            .help(tabHelp)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            // No separate spinner here: one that comes and goes would shift the toolbar on every query.
            // The refresh icon pulses instead while slow work runs.
            DelayedBusy(activity: m.activity) { busy in
                Button { m.reloadAll() } label: {
                    Label {
                        Text("Refresh")
                    } icon: {
                        Image(systemName: "arrow.clockwise").symbolEffect(.pulse, isActive: busy)
                    }
                }
                .help(busy ? "Working…" : "Reload the list of databases and tables (⇧⌘R)")
            }
            Menu {
                Button("New Database…") { m.sheet = .newDatabase }
                Button("New Table…") { m.sheet = .newTable }.disabled(m.currentDB == nil)
            } label: { Label("New", systemImage: "plus") }
                .help("Create a database, or a table in the selected database")
                .disabled(m.connectionError != nil)
            Button { if let d = m.currentDB { m.export(db: d, table: m.currentTable) } } label: {
                Label("Export", systemImage: DBStyle.exportSymbol)
            }
            .help(exportHelp)
            .disabled(m.currentDB == nil)
            Button { m.importSQL(into: m.currentDB) } label: { Label("Import", systemImage: DBStyle.importSymbol) }
                .help(m.currentDB.map { "Run an SQL file in “\($0)”" } ?? "Run an SQL file on the server")
                .disabled(m.connectionError != nil)
        }
    }

    private var tabHelp: String {
        switch m.selection {
        case nil: return "Run SQL queries"
        case .database: return "Tables: the tables in this database · Query: run SQL"
        case .table: return "Data: browse and edit rows · Structure: columns, indexes and keys · Query: run SQL"
        }
    }

    private var exportHelp: String {
        switch m.selection {
        case .table(_, let t): return "Save the table “\(t)” to an SQL file"
        case .database(let d): return "Save the database “\(d)” to an SQL file"
        case nil: return "Select a database or table to export"
        }
    }

    // MARK: Connection error

    private func connectionErrorView(_ message: String) -> some View {
        VStack(spacing: 14) {
            IconTile(symbol: "powerplug.fill", tint: .red, size: 56)
            VStack(spacing: 6) {
                Text("Can't Connect to the Database").font(.title2.weight(.semibold))
                Text("MariaDB must be running. Start it from the Lampion main window, then try again.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Text(message)
                .font(DBStyle.monoSmall)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: 520, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            HStack(spacing: 10) {
                Button("Open Lampion") { openWindow(id: "main") }
                    .help("Show the main window, where MariaDB can be started")
                Button("Try Again") { m.reloadAll() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        switch m.selection {
        case nil: return "Database Manager"
        case .database(let d): return d
        case .table(let d, let t): return "\(d) › \(t)"
        }
    }
}

fileprivate extension DBTab {
    var toolbarSymbol: String {
        switch self {
        case .tables: return "list.bullet.rectangle"
        case .designer: return "point.3.connected.trianglepath.dotted"
        case .data: return "tablecells"
        case .structure: return DBStyle.columnsSymbol
        case .query: return "chevron.left.forwardslash.chevron.right"
        }
    }
}
