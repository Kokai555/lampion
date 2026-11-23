import SwiftUI
import AppKit

/// The fast-changing part of the database manager state (see `DBModel.activity`).
final class DBActivity: ObservableObject {
    @Published var sqlLog: [SQLLogLine] = []
    @Published var busyCount = 0
}

final class DBModel: ObservableObject {
    static let pageSize = 500

    @Published var databases: [String] = []
    @Published var tables: [String: [TableInfo]] = [:]
    @Published var expanded: Set<String> = []
    @Published var selection: Node?
    @Published var tab: DBTab = .query
    @Published var connectionError: String?
    /// Statement log and busy counter. They change on every statement, so they publish through their own
    /// object: observing them must not re-render every view that observes the model (three times per query).
    let activity = DBActivity()
    var sqlLog: [SQLLogLine] {
        get { activity.sqlLog }
        set { activity.sqlLog = newValue }
    }
    var busyCount: Int {
        get { activity.busyCount }
        set { activity.busyCount = newValue }
    }
    @Published var sheet: DBSheet?
    @Published var alertMessage: String?
    @Published var confirm: ConfirmRequest?

    // Kiválasztott tábla
    @Published var columns: [ColumnInfo] = []
    @Published var indexes = ResultSet()
    @Published var createSQL = ""
    @Published var data = ResultSet()
    @Published var dataVersion = 0
    @Published var dataError: String?
    @Published var selectedRows = IndexSet()
    @Published var selectedColumns = IndexSet()
    @Published var foreignKeys: [ForeignKeyInfo] = []
    @Published var selectedIndexes = IndexSet()
    @Published var selectedForeignKeys = IndexSet()
    @Published var structureSection: StructureSection = .columns
    @Published var infoMessage: String?
    @Published var filter = ""
    @Published var orderBy: String?
    @Published var ascending = true
    @Published var offset = 0
    @Published var totalRows: Int?

    // Lekérdezés
    @Published var queryText = "SELECT VERSION();"
    @Published var queryResults: [ResultSet] = []
    @Published var queryVersion = 0
    @Published var queryMessage = ""
    @Published var queryError: String?
    @Published var shownResult = 0

    // Window layout (redesign)
    /// The row inspector beside the data grid.
    @Published var showInspector = UserDefaults.standard.bool(forKey: "db.showInspector") {
        didSet { UserDefaults.standard.set(showInspector, forKey: "db.showInspector") }
    }
    /// The SQL console at the bottom of the window: collapsed to one line, or open.
    @Published var consoleExpanded = false
    /// Show information_schema, mysql, performance_schema and sys in the sidebar.
    @Published var showSystemDatabases = UserDefaults.standard.bool(forKey: "db.showSystemDatabases") {
        didSet { UserDefaults.standard.set(showSystemDatabases, forKey: "db.showSystemDatabases") }
    }
    /// Recently run queries, newest first (at most 30), kept between launches.
    @Published var queryHistory: [String] = UserDefaults.standard.stringArray(forKey: "db.queryHistory") ?? [] {
        didSet { UserDefaults.standard.set(queryHistory, forKey: "db.queryHistory") }
    }
    /// "MariaDB 13.0.2", filled in by `reloadAll`.
    @Published var serverVersion = ""
    /// Database the Query tab runs in when the user picks one; nil follows the sidebar selection.
    @Published var queryDatabase: String?

    /// Kiegészítéshez: adatbázis → tábla → oszlopnevek.
    var completionColumns: [String: [String: [String]]] = [:]

    private let queue = DispatchQueue(label: "lampion.db")

    /// The app's database manager model (used by the snapshot tool).
    static weak var shared: DBModel?

    init() {
        signal(SIGPIPE, SIG_IGN)
        DBModel.shared = self
    }

    var currentDB: String? {
        switch selection {
        case .database(let d): return d
        case .table(let d, _): return d
        case nil: return nil
        }
    }

    var currentTable: String? {
        if case .table(_, let t) = selection { return t }
        return nil
    }

    var currentTableInfo: TableInfo? {
        guard let d = currentDB, let t = currentTable else { return nil }
        return tables[d]?.first { $0.name == t }
    }

    var fq: String? {
        guard case .table(let d, let t) = selection else { return nil }
        return SQL.id(d) + "." + SQL.id(t)
    }

    var availableTabs: [DBTab] {
        switch selection {
        case nil: return [.query]
        case .database: return [.tables, .designer, .query]
        case .table: return [.data, .structure, .query]
        }
    }

    // Napló és futtatás
    func log(_ text: String, error: Bool = false) {
        let flat = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        var lines = sqlLog   // one publish per line, also when the oldest is dropped
        lines.append(SQLLogLine(text: flat.count > 600 ? String(flat.prefix(600)) + "…" : flat, isError: error))
        if lines.count > 300 { lines.removeFirst(lines.count - 300) }
        sqlLog = lines
    }

    func exec(_ sql: String, db: String? = nil, quiet: Bool = false, done: @escaping (ExecResult) -> Void) {
        if !quiet { log(sql) }
        busyCount += 1
        queue.async {
            let r = DBClient.run(sql, database: db)
            DispatchQueue.main.async {
                self.busyCount -= 1
                if let e = r.error, !quiet { self.log("/* ERROR */ " + e, error: true) }
                done(r)
            }
        }
    }

    /// Módosító utasítás: hiba esetén figyelmeztet, utána lefuttatja a `then` blokkot.
    func change(_ sql: String, db: String? = nil, then: @escaping (Bool) -> Void) {
        exec(sql, db: db) { r in
            if let e = r.error { self.alertMessage = e }
            then(r.error == nil)
        }
    }

    // Fa
    func reloadAll() {
        if serverVersion.isEmpty {
            exec("SELECT VERSION()", quiet: true) { r in
                if let v = r.sets.first?.rows.first?.first ?? nil {
                    self.serverVersion = "MariaDB " + (v.components(separatedBy: "-").first ?? v)
                }
            }
        }
        exec("SHOW DATABASES", quiet: true) { r in
            if let e = r.error {
                self.connectionError = e
                return
            }
            self.connectionError = nil
            self.databases = r.sets.first?.rows.compactMap { $0.first ?? nil } ?? []
            // Minden olyan adatbázis tábláit újratöltjük, amelyet a fa már mutatott vagy éppen ki van jelölve.
            var stale = self.expanded.union(self.tables.keys)
            if let current = self.currentDB { stale.insert(current) }
            for d in stale {
                if self.databases.contains(d) { self.loadTables(d) } else { self.tables[d] = nil }
            }
            switch self.selection {
            case .database(let d) where !self.databases.contains(d): self.selection = nil
            case .table(let d, _) where !self.databases.contains(d): self.selection = nil
            case .table: self.loadTable()
            default: break
            }
        }
    }

    func loadTables(_ db: String, then: (() -> Void)? = nil) {
        let sql = "SELECT TABLE_NAME, TABLE_TYPE, IFNULL(ENGINE,''), IFNULL(TABLE_ROWS,''), "
            + "IFNULL(DATA_LENGTH+INDEX_LENGTH,0), IFNULL(TABLE_COLLATION,'') FROM information_schema.TABLES "
            + "WHERE TABLE_SCHEMA = \(SQL.val(db)) ORDER BY TABLE_NAME"
        exec(sql, quiet: true) { r in
            self.tables[db] = (r.sets.first?.rows ?? []).map { row in
                let v = row.map { $0 ?? "" }
                return TableInfo(name: v[0], type: v[1], engine: v[2], collation: v[5], rows: v[3], bytes: Int64(v[4]) ?? 0)
            }
            self.loadCompletionColumns(db)
            then?()
        }
    }

    /// A kijelölés megváltozásakor hívódik.
    func selectionChanged() {
        switch selection {
        case nil:
            tab = .query
        case .database(let d):
            if tab != .query && tab != .designer { tab = .tables }
            loadTables(d)
        case .table(let d, _):
            // Stay on Structure or Query when moving between tables; otherwise show the data.
            if tab != .query && tab != .structure { tab = .data }
            expanded.insert(d)
            if tables[d] == nil { loadTables(d) }
            filter = ""; orderBy = nil; ascending = true; offset = 0; totalRows = nil
            columns = []; data = ResultSet(); dataError = nil; createSQL = ""; indexes = ResultSet(); foreignKeys = []
            selectedRows = []; selectedColumns = []; dataVersion += 1
            loadTable()
        }
    }

    // Tábla
    func loadTable(then: (() -> Void)? = nil) {
        guard let fq, let node = selection else { return }
        guard case .table(let tableDB, let tableName) = node else { return }
        let sql = "SHOW FULL COLUMNS FROM \(fq); SHOW INDEX FROM \(fq); SHOW CREATE TABLE \(fq); "
            + foreignKeySQL(db: tableDB, table: tableName)
        exec(sql, quiet: true) { r in
            guard node == self.selection else { return }
            if let e = r.error { self.dataError = e; then?(); return }
            let c = r.sets.first ?? ResultSet()
            self.columns = c.rows.indices.map { i in
                ColumnInfo(name: c.value(i, "Field") ?? "", type: c.value(i, "Type") ?? "",
                           collation: c.value(i, "Collation") ?? "", null: c.value(i, "Null") ?? "",
                           key: c.value(i, "Key") ?? "", extra: c.value(i, "Extra") ?? "",
                           comment: c.value(i, "Comment") ?? "", def: c.value(i, "Default"))
            }
            self.indexes = r.sets.count > 1 ? r.sets[1] : ResultSet()
            let create = r.sets.count > 2 ? r.sets[2].rows.first : nil
            self.createSQL = (create?.count ?? 0) > 1 ? (create?[1] ?? "") : ""
            self.foreignKeys = r.sets.count > 3 ? self.parseForeignKeys(r.sets[3]) : []
            self.selectedColumns = []
            self.selectedIndexes = []
            self.selectedForeignKeys = []
            self.loadData(then: then)
        }
    }

    func loadData(then: (() -> Void)? = nil) {
        guard let fq, let node = selection else { return }
        let cond = filter.trimmed.isEmpty ? "" : " WHERE " + filter.trimmed
        var sql = "SELECT * FROM \(fq)\(cond)"
        if let orderBy { sql += " ORDER BY \(SQL.id(orderBy)) \(ascending ? "ASC" : "DESC")" }
        sql += " LIMIT \(DBModel.pageSize) OFFSET \(offset); SELECT COUNT(*) FROM \(fq)\(cond);"
        exec(sql) { r in
            guard node == self.selection else { return }
            self.dataError = r.error
            var set = r.error == nil ? (r.sets.first ?? ResultSet()) : ResultSet()
            if set.columns.isEmpty { set.columns = self.columns.map(\.name) }
            self.data = set
            self.totalRows = r.sets.count > 1 ? Int(r.sets[1].rows.first?.first.flatMap { $0 } ?? "") : nil
            self.selectedRows = []
            self.dataVersion += 1
            then?()
        }
    }

    func sort(by column: String) {
        if orderBy == column { ascending.toggle() } else { orderBy = column; ascending = true }
        offset = 0
        loadData()
    }

    func page(_ delta: Int) {
        offset = max(0, offset + delta * DBModel.pageSize)
        loadData()
    }

    private func literal(_ value: String?, column: String) -> String {
        guard let value else { return "NULL" }
        if value.hasPrefix("0x"), columns.first(where: { $0.name == column })?.isBinary == true { return value }
        return SQL.val(value)
    }

    /// Columns that identify a row: the primary key, else a unique NOT NULL column, else every column.
    var rowKeyColumns: [String] {
        let pk = columns.filter { $0.key == "PRI" }.map(\.name)
        if !pk.isEmpty { return pk }
        if let unique = columns.first(where: { $0.key == "UNI" && $0.null.uppercased() != "YES" }) { return [unique.name] }
        return data.columns
    }

    /// Updates one row, but first checks that the row can be found again. Without a key, values such as FLOAT
    /// numbers may not match exactly, and the UPDATE would silently change nothing.
    func updateOneRow(set: String, where match: String, then: @escaping (Bool) -> Void) {
        guard let fq, !match.isEmpty else { return }
        exec("SELECT COUNT(*) FROM \(fq) WHERE \(match); UPDATE \(fq) SET \(set) WHERE \(match) LIMIT 1;") { r in
            if let e = r.error { self.alertMessage = e; then(false); return }
            let found = Int((r.sets.first?.rows.first?.first ?? nil) ?? "0") ?? 0
            if found == 0 {
                self.alertMessage = "The change was not saved: Lampion could not find this row again. The table has no primary key, "
                    + "and some of its values (for example FLOAT numbers) can't be matched exactly. Add a primary key in Structure to edit rows safely."
                then(false)
                return
            }
            then(true)
        }
    }

    private func rowCondition(_ row: Int) -> String {
        return rowKeyColumns.compactMap { k -> String? in
            guard let i = data.index(k), row < data.rows.count else { return nil }
            return "\(SQL.id(k)) <=> \(literal(data.rows[row][i], column: k))"
        }.joined(separator: " AND ")
    }

    func updateCell(row: Int, column: Int, value: String?, then: (() -> Void)? = nil) {
        guard let fq, row < data.rows.count, column < data.columns.count else { return }
        let name = data.columns[column]
        _ = fq
        updateOneRow(set: "\(SQL.id(name)) = \(literal(value, column: name))", where: rowCondition(row)) { _ in
            self.loadData(then: then)
        }
    }

    func insertRow(_ values: [String: String], then: (() -> Void)? = nil) {
        guard let fq else { return }
        let names = columns.map(\.name).filter { values[$0] != nil }
        let sql = "INSERT INTO \(fq) (\(names.map(SQL.id).joined(separator: ", "))) "
            + "VALUES (\(names.map { literal(values[$0], column: $0) }.joined(separator: ", ")));"
        change(sql) { ok in
            if ok { self.sheet = nil }
            self.loadData(then: then)
        }
    }

    func deleteSelectedRows(then: (() -> Void)? = nil) {
        guard let fq, !selectedRows.isEmpty else { return }
        let sql = selectedRows.map { "DELETE FROM \(fq) WHERE \(rowCondition($0)) LIMIT 1;" }.joined(separator: "\n")
        change(sql) { _ in self.loadData(then: then) }
    }

    // Szerkezet
    func createDatabase(_ name: String, collation: String, then: (() -> Void)? = nil) {
        change("CREATE DATABASE \(SQL.id(name)) CHARACTER SET utf8mb4 COLLATE \(collation);") { ok in
            if ok {
                self.sheet = nil
                self.expanded.insert(name)
                self.selection = .database(name)
            }
            self.reloadAll(); then?()
        }
    }

    func dropDatabase(_ db: String, then: (() -> Void)? = nil) {
        change("DROP DATABASE \(SQL.id(db));") { _ in
            if self.currentDB == db { self.selection = nil }
            self.tables[db] = nil
            self.expanded.remove(db)
            self.reloadAll(); then?()
        }
    }

    func createTable(_ name: String, in db: String, then: (() -> Void)? = nil) {
        let sql = "CREATE TABLE \(SQL.id(db)).\(SQL.id(name)) (`id` INT UNSIGNED NOT NULL AUTO_INCREMENT, PRIMARY KEY (`id`));"
        change(sql) { ok in
            self.loadTables(db) {
                if ok {
                    self.sheet = nil
                    self.tab = .structure
                    self.selection = .table(db, name)
                }
                then?()
            }
        }
    }

    func dropTable(_ table: String, in db: String, isView: Bool = false, then: (() -> Void)? = nil) {
        change("DROP \(isView ? "VIEW" : "TABLE") \(SQL.id(db)).\(SQL.id(table));") { _ in
            if self.selection == .table(db, table) { self.selection = .database(db) }
            self.loadTables(db, then: then)
        }
    }

    func truncateTable(_ table: String, in db: String, then: (() -> Void)? = nil) {
        change("TRUNCATE TABLE \(SQL.id(db)).\(SQL.id(table));") { _ in
            self.loadTables(db)
            if self.selection == .table(db, table) { self.loadData(then: then) } else { then?() }
        }
    }

    func addColumn(name: String, type: String, nullable: Bool, defaultValue: String, then: (() -> Void)? = nil) {
        guard let fq else { return }
        var sql = "ALTER TABLE \(fq) ADD COLUMN \(SQL.id(name)) \(type) \(nullable ? "NULL" : "NOT NULL")"
        if !defaultValue.isEmpty { sql += " DEFAULT \(SQL.val(defaultValue))" }
        change(sql + ";") { ok in
            if ok { self.sheet = nil }
            self.loadTable(then: then)
        }
    }

    func dropColumn(_ name: String, then: (() -> Void)? = nil) {
        guard let fq else { return }
        change("ALTER TABLE \(fq) DROP COLUMN \(SQL.id(name));") { _ in self.loadTable(then: then) }
    }

    // Kiegészítés (Tab)
    private func loadCompletionColumns(_ db: String) {
        let sql = "SELECT TABLE_NAME, COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = \(SQL.val(db)) "
            + "ORDER BY TABLE_NAME, ORDINAL_POSITION"
        exec(sql, quiet: true) { r in
            var map: [String: [String]] = [:]
            for row in r.sets.first?.rows ?? [] where row.count > 1 {
                if let t = row[0], let c = row[1] { map[t, default: []].append(c) }
            }
            self.completionColumns[db] = map
        }
    }

    // Lekérdezés
    func runQuery(then: (() -> Void)? = nil) {
        var text = queryText.trimmed
        while text.hasSuffix(";") { text = String(text.dropLast()).trimmed }
        guard !text.isEmpty else { return }
        log(text)
        queryHistory.removeAll { $0 == text }
        queryHistory.insert(text, at: 0)
        if queryHistory.count > 30 { queryHistory.removeLast(queryHistory.count - 30) }
        busyCount += 1
        let db = queryDatabase ?? currentDB
        queue.async {
            let r = DBClient.run(text + ";\nSELECT ROW_COUNT() AS `__sp_rc`;", database: db)
            DispatchQueue.main.async {
                self.busyCount -= 1
                var sets = r.sets
                var affected: Int?
                if let last = sets.last, last.columns == ["__sp_rc"] {
                    affected = Int(last.rows.first?.first.flatMap { $0 } ?? "")
                    sets.removeLast()
                }
                let shown = sets.filter { !$0.columns.isEmpty }
                self.queryResults = shown
                self.shownResult = 0
                self.queryVersion += 1
                self.queryError = r.error
                let time = String(format: "%.3f s", r.seconds)
                if let e = r.error {
                    self.log("/* ERROR */ " + e, error: true)
                    self.queryMessage = time
                } else if shown.isEmpty {
                    if let affected, affected >= 0 {
                        self.queryMessage = "Done – rows affected: \(affected) · \(time)"
                    } else {
                        self.queryMessage = "Done – 0 rows · \(time)"
                    }
                } else {
                    let rows = shown.reduce(0) { $0 + $1.rows.count }
                    self.queryMessage = "\(shown.count) results, \(rows) rows · \(time)"
                }
                self.reloadAll()
                then?()
            }
        }
    }

    // Export / import
    func export(db: String, table: String?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (table.map { "\(db)-\($0)" } ?? db) + ".sql"
        // Exports go to ~/Lampion/backups by default once everything lives there.
        if Paths.usesHome, FileManager.default.fileExists(atPath: Paths.homeBackups) {
            panel.directoryURL = URL(fileURLWithPath: Paths.homeBackups)
        }
        panel.title = "Export to SQL File"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        dump(db: db, table: table, to: url.path)
    }

    func dump(db: String, table: String?, to path: String, then: ((Bool) -> Void)? = nil) {
        var args = ["--result-file=\(path)", "--routines", "--default-character-set=utf8mb4"]
        args += table.map { [db, $0] } ?? ["--databases", db]
        log("/* Export: \(db)\(table.map { "." + $0 } ?? "") → \(path) */")
        busyCount += 1
        queue.async {
            let r = DBClient.exec(DBClient.dump, args)
            DispatchQueue.main.async {
                self.busyCount -= 1
                if r.status != 0 {
                    let e = DBClient.cleanError(r.err)
                    self.log("/* ERROR */ " + e, error: true)
                    self.alertMessage = e
                } else {
                    self.log("/* Export done */")
                }
                then?(r.status == 0)
            }
        }
    }

    func importSQL(into db: String?) {
        let panel = NSOpenPanel()
        panel.title = "Import SQL File"
        panel.allowedContentTypes = [.init(filenameExtension: "sql") ?? .plainText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        log("/* Import: \(url.lastPathComponent)\(db.map { " → " + $0 } ?? "") */")
        busyCount += 1
        queue.async {
            let r = DBClient.run(data, database: db)
            DispatchQueue.main.async {
                self.busyCount -= 1
                if let e = r.error {
                    self.log("/* ERROR */ " + e, error: true)
                    self.alertMessage = e
                } else {
                    self.log("/* Import done */")
                }
                self.reloadAll()
            }
        }
    }
}
