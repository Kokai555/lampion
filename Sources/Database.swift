// Szerverpanel – beépített adatbázis-kezelő (MariaDB/MySQL).
// A helyi `mariadb` kliensen keresztül, socketen csatlakozik a bejelentkezett macOS-felhasználóval.
import SwiftUI
import AppKit

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - SQL motor

struct ResultSet {
    var columns: [String] = []
    var rows: [[String?]] = []

    func index(_ column: String) -> Int? { columns.firstIndex(of: column) }
    func value(_ row: Int, _ column: String) -> String? {
        guard let i = index(column), row < rows.count, i < rows[row].count else { return nil }
        return rows[row][i]
    }
}

struct ExecResult {
    var sets: [ResultSet] = []
    var error: String?
    var seconds: Double = 0
}

enum SQL {
    static func id(_ s: String) -> String { "`" + s.replacingOccurrences(of: "`", with: "``") + "`" }
    static func val(_ s: String?) -> String {
        guard let s else { return "NULL" }
        return "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''") + "'"
    }
}

enum DBClient {
    static let client = "\(Paths.brew)/bin/mariadb"
    static let dump = "\(Paths.brew)/bin/mariadb-dump"

    static func exec(_ path: String, _ args: [String], stdin: Data? = nil) -> (status: Int32, out: Data, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let o = Pipe(), e = Pipe(), i = Pipe()
        p.standardOutput = o; p.standardError = e; p.standardInput = i
        do { try p.run() } catch { return (-1, Data(), error.localizedDescription) }
        let group = DispatchGroup()
        var errData = Data()
        DispatchQueue.global().async(group: group) { errData = e.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global().async(group: group) {
            if let stdin { try? i.fileHandleForWriting.write(contentsOf: stdin) }
            try? i.fileHandleForWriting.close()
        }
        let out = o.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        group.wait()
        return (p.terminationStatus, out, String(decoding: errData, as: UTF8.self))
    }

    static func run(_ sql: String, database: String? = nil) -> ExecResult {
        run(Data(sql.utf8), database: database)
    }

    static func run(_ sql: Data, database: String? = nil) -> ExecResult {
        let start = Date()
        var args = ["--xml", "--binary-as-hex", "--default-character-set=utf8mb4"]
        if let database { args += ["-D", database] }
        let r = exec(client, args, stdin: sql)
        var result = ExecResult()
        result.seconds = Date().timeIntervalSince(start)
        let parsed = XMLResults.parse(r.out)
        result.sets = parsed.sets
        if r.status != 0 {
            result.error = cleanError(r.err)
        } else if !parsed.ok {
            result.error = "The result can't be displayed (it probably contains control characters or binary data)."
        }
        return result
    }

    static func cleanError(_ err: String) -> String {
        let lines = err.split(separator: "\n").map(String.init)
        if let e = lines.last(where: { $0.hasPrefix("ERROR") }) {
            if e.contains("(HY000) ") && (e.contains("2002") || e.contains("Can't connect")) {
                return "Can't connect to the database. Is MySQL running? (\(e))"
            }
            return e
        }
        let t = err.trimmed
        return t.isEmpty ? "Unknown error" : t
    }
}

/// A `mariadb --xml` kimenetének feldolgozása (utasításonként egy <resultset>).
final class XMLResults: NSObject, XMLParserDelegate {
    private var sets: [ResultSet] = []
    private var current = ResultSet()
    private var row: [String?] = []
    private var names: [String] = []
    private var text = ""
    private var isNil = false
    private var inField = false

    static func parse(_ data: Data) -> (sets: [ResultSet], ok: Bool) {
        if data.isEmpty { return ([], true) }
        let body = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "<?xml version=\"1.0\"?>", with: "")
        let wrapped = "<root xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">" + body + "</root>"
        let parser = XMLParser(data: Data(wrapped.utf8))
        let delegate = XMLResults()
        parser.delegate = delegate
        let ok = parser.parse()
        return (delegate.sets, ok)
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        switch name {
        case "resultset": current = ResultSet()
        case "row": row = []; names = []
        case "field":
            inField = true; text = ""
            isNil = attributes["xsi:nil"] == "true"
            names.append(attributes["name"] ?? "")
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { if inField { text += string } }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "field": row.append(isNil ? nil : text); inField = false
        case "row":
            if current.columns.isEmpty { current.columns = names }
            current.rows.append(row)
        case "resultset": sets.append(current)
        default: break
        }
    }
}

// MARK: - Modell

enum Node: Hashable {
    case database(String)
    case table(String, String)
}

struct TableInfo: Identifiable, Hashable {
    var id: String { name }
    let name, type, engine, collation, rows: String
    let bytes: Int64
    var isView: Bool { type == "VIEW" }
}

struct ColumnInfo: Identifiable {
    var id: String { name }
    let name, type, collation, null, key, extra, comment: String
    let def: String?
    var isBinary: Bool {
        let t = type.lowercased()
        return t.contains("blob") || t.contains("binary") || t.hasPrefix("bit")
    }
}

struct SQLLogLine: Identifiable {
    let id = UUID()
    let text: String
    let isError: Bool
}

struct ConfirmRequest {
    let title, message, button: String
    let action: () -> Void
}

enum DBSheet: String, Identifiable {
    case newDatabase, newTable, addColumn, insertRow
    var id: String { rawValue }
}

enum DBTab: String, Hashable {
    case tables = "Tables", data = "Data", structure = "Structure", query = "Query"
}

final class DBModel: ObservableObject {
    static let pageSize = 500

    @Published var databases: [String] = []
    @Published var tables: [String: [TableInfo]] = [:]
    @Published var expanded: Set<String> = []
    @Published var selection: Node?
    @Published var tab: DBTab = .query
    @Published var connectionError: String?
    @Published var sqlLog: [SQLLogLine] = []
    @Published var busyCount = 0
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

    /// Kiegészítéshez: adatbázis → tábla → oszlopnevek.
    var completionColumns: [String: [String: [String]]] = [:]

    private let queue = DispatchQueue(label: "szerverpanel.db")

    init() { signal(SIGPIPE, SIG_IGN) }

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

    private var fq: String? {
        guard case .table(let d, let t) = selection else { return nil }
        return SQL.id(d) + "." + SQL.id(t)
    }

    var availableTabs: [DBTab] {
        switch selection {
        case nil: return [.query]
        case .database: return [.tables, .query]
        case .table: return [.data, .structure, .query]
        }
    }

    // Napló és futtatás
    func log(_ text: String, error: Bool = false) {
        let flat = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        sqlLog.append(SQLLogLine(text: flat.count > 600 ? String(flat.prefix(600)) + "…" : flat, isError: error))
        if sqlLog.count > 300 { sqlLog.removeFirst(sqlLog.count - 300) }
    }

    private func exec(_ sql: String, db: String? = nil, quiet: Bool = false, done: @escaping (ExecResult) -> Void) {
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
    private func change(_ sql: String, db: String? = nil, then: @escaping (Bool) -> Void) {
        exec(sql, db: db) { r in
            if let e = r.error { self.alertMessage = e }
            then(r.error == nil)
        }
    }

    // Fa
    func reloadAll() {
        exec("SHOW DATABASES", quiet: true) { r in
            if let e = r.error {
                self.connectionError = e
                return
            }
            self.connectionError = nil
            self.databases = r.sets.first?.rows.compactMap { $0.first ?? nil } ?? []
            for d in self.expanded where self.databases.contains(d) { self.loadTables(d) }
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
            if tab != .query { tab = .tables }
            loadTables(d)
        case .table(let d, _):
            if tab != .query { tab = .data }
            expanded.insert(d)
            if tables[d] == nil { loadTables(d) }
            filter = ""; orderBy = nil; ascending = true; offset = 0; totalRows = nil
            columns = []; data = ResultSet(); dataError = nil; createSQL = ""; indexes = ResultSet()
            selectedRows = []; selectedColumns = []; dataVersion += 1
            loadTable()
        }
    }

    // Tábla
    func loadTable(then: (() -> Void)? = nil) {
        guard let fq, let node = selection else { return }
        exec("SHOW FULL COLUMNS FROM \(fq); SHOW INDEX FROM \(fq); SHOW CREATE TABLE \(fq);", quiet: true) { r in
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
            self.selectedColumns = []
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

    private func rowCondition(_ row: Int) -> String {
        let pk = columns.filter { $0.key == "PRI" }.map(\.name)
        let keys = pk.isEmpty ? data.columns : pk
        return keys.compactMap { k -> String? in
            guard let i = data.index(k), row < data.rows.count else { return nil }
            return "\(SQL.id(k)) <=> \(literal(data.rows[row][i], column: k))"
        }.joined(separator: " AND ")
    }

    func updateCell(row: Int, column: Int, value: String?, then: (() -> Void)? = nil) {
        guard let fq, row < data.rows.count, column < data.columns.count else { return }
        let name = data.columns[column]
        let sql = "UPDATE \(fq) SET \(SQL.id(name)) = \(literal(value, column: name)) WHERE \(rowCondition(row)) LIMIT 1;"
        change(sql) { _ in self.loadData(then: then) }
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
    /// Gyakori szavak elöl, utána a MariaDB kulcsszavai, függvényei és típusai ábécérendben, végül gyakori szókapcsolatok.
    static let keywords: [String] = [
        "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "NULL", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
        "CREATE", "TABLE", "DATABASE", "ALTER", "DROP", "INDEX", "VIEW", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER",
        "CROSS", "ON", "USING", "AS", "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "OFFSET", "ASC", "DESC", "DISTINCT",
        "UNION", "ALL", "IN", "IS", "LIKE", "BETWEEN", "EXISTS", "CASE", "WHEN", "THEN", "ELSE", "END", "IF",
        "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "DEFAULT", "AUTO_INCREMENT", "ADD", "COLUMN", "MODIFY",
        "CHANGE", "RENAME", "TO", "TRUNCATE", "REPLACE", "SHOW", "DESCRIBE", "EXPLAIN", "USE", "TABLES", "DATABASES",
        "COLUMNS", "COUNT", "SUM", "AVG", "MIN", "MAX", "CONCAT", "COALESCE", "IFNULL", "NOW", "INT", "VARCHAR",
        "TEXT", "DATE", "DATETIME", "DECIMAL", "BOOLEAN", "ABS", "ACTION", "ADDDATE", "ADDTIME", "AES_DECRYPT",
        "AES_ENCRYPT", "AFTER", "AGAINST", "ALGORITHM", "ALWAYS", "ANALYZE", "ANY", "Aria", "ASCII", "AUTOCOMMIT",
        "AVG_ROW_LENGTH", "BEFORE", "BEGIN", "BIGINT", "BIN", "BINARY", "BIT", "BIT_LENGTH", "BLOB", "BOOL", "BOTH",
        "BTREE", "CALL", "CASCADE", "CASCADED", "CAST", "CEIL", "CEILING", "CHAR", "CHAR_LENGTH", "CHARACTER",
        "CHARSET", "CHECK", "CHECKSUM", "COLLATE", "COLLATION", "COMMENT", "COMMIT", "COMMITTED", "COMPACT",
        "COMPRESSED", "CONCAT_WS", "CONNECTION_ID", "CONSTRAINT", "CONTAINS", "CONVERT", "CURDATE", "CURRENT",
        "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP", "CURRENT_USER", "CURSOR", "CURTIME", "CYCLE", "DATA",
        "DATE_ADD", "DATE_FORMAT", "DATE_SUB", "DATEDIFF", "DAY", "DAYNAME", "DAYOFMONTH", "DAYOFWEEK", "DAYOFYEAR",
        "DEALLOCATE", "DEC", "DECLARE", "DEFINER", "DELAYED", "DELIMITER", "DENSE_RANK", "DETERMINISTIC", "DISABLE",
        "DIV", "DO", "DOUBLE", "DUPLICATE", "DYNAMIC", "EACH", "ELSEIF", "ELT", "ENABLE", "ENCLOSED", "ENGINE",
        "ENGINES", "ENUM", "ERRORS", "ESCAPE", "ESCAPED", "EVENT", "EVENTS", "EXCEPT", "EXECUTE", "EXIT", "EXP",
        "EXTENDED", "EXTRACT", "FALSE", "FETCH", "FIELD", "FIELDS", "FIND_IN_SET", "FIRST", "FIRST_VALUE", "FIXED",
        "FLOAT", "FLOOR", "FLUSH", "FOLLOWING", "FOR", "FORCE", "FORMAT", "FOUND_ROWS", "FROM_UNIXTIME", "FULL",
        "FULLTEXT", "FUNCTION", "GENERATED", "GEOMETRY", "GLOBAL", "GRANT", "GRANTS", "GREATEST", "GROUP_CONCAT",
        "HANDLER", "HASH", "HEX", "HIGH_PRIORITY", "HOUR", "IDENTIFIED", "IGNORE", "IMPORT", "INCREMENT", "INDEXES",
        "INET_ATON", "INET_NTOA", "INFILE", "InnoDB", "INOUT", "INSERT_METHOD", "INSTR", "INTEGER", "INTERSECT",
        "INTERVAL", "INVISIBLE", "ISNULL", "ISOLATION", "ITERATE", "JSON", "JSON_ARRAY", "JSON_ARRAYAGG",
        "JSON_CONTAINS", "JSON_EXTRACT", "JSON_LENGTH", "JSON_OBJECT", "JSON_OBJECTAGG", "JSON_SET", "JSON_UNQUOTE",
        "JSON_VALUE", "KEYS", "KILL", "LAG", "LANGUAGE", "LAST", "LAST_DAY", "LAST_INSERT_ID", "LAST_VALUE", "latin1",
        "LCASE", "LEAD", "LEADING", "LEAST", "LEAVE", "LENGTH", "LEVEL", "LINES", "LN", "LOAD", "LOCAL", "LOCATE",
        "LOCK", "LOG", "LOGS", "LONGBLOB", "LONGTEXT", "LOOP", "LOW_PRIORITY", "LOWER", "LPAD", "LTRIM", "MAKEDATE",
        "MASTER", "MATCH", "MAXVALUE", "MD5", "MEDIUMBLOB", "MEDIUMINT", "MEDIUMTEXT", "MEMORY", "MERGE", "MINUTE",
        "MINVALUE", "MOD", "MODE", "MONTH", "MONTHNAME", "MyISAM", "NAMES", "NATURAL", "NEXT", "NO", "NOWAIT",
        "NTILE", "NULLIF", "NUMERIC", "NVARCHAR", "OPEN", "OPTIMIZE", "OPTION", "OPTIONALLY", "OUT", "OUTFILE",
        "OVER", "PARTITION", "PARTITIONS", "PASSWORD", "PERSISTENT", "PI", "POSITION", "POW", "POWER", "PRECEDING",
        "PRECISION", "PREPARE", "PRIVILEGES", "PROCEDURE", "PROCESSLIST", "PURGE", "QUARTER", "QUERY", "QUICK",
        "RAND", "RANGE", "RANK", "READ", "REAL", "RECURSIVE", "REDUNDANT", "REGEXP", "RELEASE", "REPAIR", "REPEAT",
        "REPEATABLE", "REQUIRE", "RESET", "RESTRICT", "RETURN", "RETURNING", "RETURNS", "REVERSE", "REVOKE", "RLIKE",
        "ROLE", "ROLLBACK", "ROLLUP", "ROUND", "ROUTINE", "ROW", "ROW_COUNT", "ROW_FORMAT", "ROW_NUMBER", "ROWS",
        "RPAD", "RTRIM", "SAVEPOINT", "SCHEMA", "SCHEMAS", "SECOND", "SECURITY", "SEPARATOR", "SEQUENCE", "SERIAL",
        "SERIALIZABLE", "SESSION", "SHA1", "SHA2", "SIGN", "SIGNAL", "SIGNED", "SLAVE", "SLEEP", "SMALLINT", "SOME",
        "SPATIAL", "SQL", "SQL_CALC_FOUND_ROWS", "SQRT", "START", "STARTING", "STATUS", "STORED", "STR_TO_DATE",
        "STRAIGHT_JOIN", "SUBDATE", "SUBPARTITION", "SUBSTR", "SUBSTRING", "SUBSTRING_INDEX", "SYSDATE", "TEMPORARY",
        "TERMINATED", "TIME", "TIME_FORMAT", "TIMEDIFF", "TIMESTAMP", "TIMESTAMPDIFF", "TINYBLOB", "TINYINT",
        "TINYTEXT", "TO_DAYS", "TRAILING", "TRANSACTION", "TRIGGER", "TRIGGERS", "TRIM", "TRUE", "UCASE", "UNBOUNDED",
        "UNCOMMITTED", "UNDO", "UNHEX", "UNIX_TIMESTAMP", "UNLOCK", "UNSIGNED", "UNTIL", "UPPER", "USAGE", "USER",
        "UTC_TIMESTAMP", "utf8mb4", "utf8mb4_bin", "utf8mb4_general_ci", "utf8mb4_hungarian_ci", "utf8mb4_unicode_ci",
        "UUID", "VALUE", "VARBINARY", "VARIABLES", "VARYING", "VERSION", "VIRTUAL", "WAIT", "WARNINGS", "WEEK",
        "WEEKDAY", "WHILE", "WINDOW", "WITH", "WORK", "WRITE", "XOR", "YEAR", "YEARWEEK", "ZEROFILL", "ORDER BY",
        "GROUP BY", "INSERT INTO", "DELETE FROM", "CREATE TABLE", "CREATE DATABASE", "ALTER TABLE", "DROP TABLE",
        "LEFT JOIN", "INNER JOIN", "PRIMARY KEY", "FOREIGN KEY", "NOT NULL", "IF NOT EXISTS", "IF EXISTS",
        "UNION ALL", "ON DELETE CASCADE", "ON UPDATE CASCADE", "ON DUPLICATE KEY UPDATE", "SHOW TABLES",
        "SHOW DATABASES", "SHOW CREATE TABLE", "IS NULL", "IS NOT NULL", "TRUNCATE TABLE", "ADD COLUMN",
        "DROP COLUMN", "DEFAULT CHARSET",
    ]

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

    /// Javaslatok a begépelt szókezdethez. `qualifier`: a pont előtti név (tábla vagy adatbázis), ha van.
    func completions(prefix: String, qualifier: String?) -> [String] {
        func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }
        let db = currentDB
        var candidates: [String] = []
        if let q = qualifier {
            if let db, let cols = completionColumns[db]?.first(where: { same($0.key, q) })?.value {
                candidates = cols
            } else if let d = databases.first(where: { same($0, q) }) {
                candidates = (tables[d] ?? []).map(\.name)
            } else {
                // álnév (pl. "t.") – az aktuális adatbázis összes oszlopa
                candidates = db.flatMap { completionColumns[$0] }?.values.flatMap { $0 } ?? []
            }
        } else {
            if let db {
                candidates += (tables[db] ?? []).map(\.name)
                if let t = currentTable { candidates += completionColumns[db]?[t] ?? [] }
                candidates += (completionColumns[db] ?? [:]).sorted { $0.key < $1.key }.flatMap(\.value)
            }
            candidates += databases
            // Kulcsszavak a begépelt betűk írásmódjában (kisbetűs gépelésnél kisbetűvel).
            let lower = !prefix.isEmpty && prefix == prefix.lowercased() && prefix != prefix.uppercased()
            candidates += lower ? DBModel.keywords.map { $0.lowercased() } : DBModel.keywords
        }
        var seen = Set<String>()
        return candidates.filter { c in
            (prefix.isEmpty || c.lowercased().hasPrefix(prefix.lowercased())) && !same(c, prefix) && seen.insert(c.lowercased()).inserted
        }.prefix(60).map { $0 }
    }

    // Lekérdezés
    func runQuery(then: (() -> Void)? = nil) {
        var text = queryText.trimmed
        while text.hasSuffix(";") { text = String(text.dropLast()).trimmed }
        guard !text.isEmpty else { return }
        log(text)
        busyCount += 1
        let db = currentDB
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

// MARK: - Rács (NSTableView)

struct GridView: NSViewRepresentable {
    var columns: [String]
    var rows: [[String?]]
    var version: Int
    var editable = false
    var sortColumn: String? = nil
    var ascending = true
    var selection: Binding<IndexSet>? = nil
    var onEdit: ((Int, Int, String?) -> Void)? = nil
    var onSort: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = NSTableView()
        tv.usesAlternatingRowBackgroundColors = true
        tv.gridStyleMask = [.solidVerticalGridLineMask]
        tv.columnAutoresizingStyle = .noColumnAutoresizing
        tv.allowsMultipleSelection = true
        tv.allowsColumnReordering = false
        tv.rowHeight = 22
        tv.style = .fullWidth
        tv.dataSource = context.coordinator
        tv.delegate = context.coordinator

        let menu = NSMenu()
        let copy = NSMenuItem(title: "Copy Cell", action: #selector(Coordinator.copyCell), keyEquivalent: "")
        copy.target = context.coordinator
        menu.addItem(copy)
        if editable {
            let null = NSMenuItem(title: "Set to NULL", action: #selector(Coordinator.setNull), keyEquivalent: "")
            null.target = context.coordinator
            menu.addItem(null)
        }
        tv.menu = menu

        let sv = NSScrollView()
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = true
        sv.borderType = .noBorder
        context.coordinator.table = tv
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let tv = c.table else { return }
        if c.builtColumns != columns {
            c.rebuildColumns()
            c.version = version
            tv.deselectAll(nil)
            tv.reloadData()
        } else if c.version != version {
            c.version = version
            tv.deselectAll(nil)
            tv.reloadData()
        }
        c.updateSortIndicator()
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        var parent: GridView
        weak var table: NSTableView?
        var builtColumns: [String] = []
        var version = -1

        init(_ parent: GridView) { self.parent = parent }

        func rebuildColumns() {
            guard let table else { return }
            for c in table.tableColumns { table.removeTableColumn(c) }
            for (i, name) in parent.columns.enumerated() {
                let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(i)"))
                col.title = name
                let sample = parent.rows.prefix(40).map { $0.count > i ? min($0[i]?.count ?? 6, 60) : 0 }.max() ?? 0
                col.width = min(380, max(64, CGFloat(max(name.count + 2, sample)) * 7.4 + 20))
                col.minWidth = 40
                table.addTableColumn(col)
            }
            builtColumns = parent.columns
        }

        func updateSortIndicator() {
            guard let table else { return }
            for (i, col) in table.tableColumns.enumerated() {
                let active = i < parent.columns.count && parent.columns[i] == parent.sortColumn
                table.setIndicatorImage(active ? NSImage(named: parent.ascending ? "NSAscendingSortIndicator"
                                                                                  : "NSDescendingSortIndicator") : nil,
                                        in: col)
            }
        }

        private func value(_ row: Int, _ col: Int) -> String?? {
            guard row >= 0, col >= 0, row < parent.rows.count, col < parent.rows[row].count else { return nil }
            return .some(parent.rows[row][col])
        }

        private func columnIndex(_ col: NSTableColumn?) -> Int? {
            col.flatMap { Int($0.identifier.rawValue.dropFirst()) }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let ci = columnIndex(tableColumn), let cell = value(row, ci) else { return nil }
            let ident = NSUserInterfaceItemIdentifier("cell")
            let view: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: ident, owner: nil) as? NSTableCellView {
                view = reused
            } else {
                view = NSTableCellView()
                view.identifier = ident
                let field = NSTextField()
                field.isBordered = false
                field.drawsBackground = false
                field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                field.lineBreakMode = .byTruncatingTail
                field.cell?.usesSingleLineMode = true
                field.delegate = self
                field.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(field)
                view.textField = field
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
                    field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
                    field.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                ])
            }
            guard let tf = view.textField else { return view }
            if let text = cell {
                let simple = text.count <= 2000 && !text.contains("\n") && !text.contains("\r")
                tf.stringValue = simple ? text
                    : String(text.prefix(300)).replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " ⏎ ")
                tf.placeholderString = nil
                tf.isEditable = parent.editable && simple
            } else {
                tf.stringValue = ""
                tf.placeholderString = "(NULL)"
                tf.isEditable = parent.editable
            }
            return view
        }

        func controlTextDidEndEditing(_ note: Notification) {
            guard let tf = note.object as? NSTextField, let table else { return }
            let row = table.row(for: tf), col = table.column(for: tf)
            guard let old = value(row, col) else { return }
            let new = tf.stringValue
            if old == nil && new.isEmpty { return }
            if old == new { return }
            parent.onEdit?(row, col, new)
        }

        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            guard let i = columnIndex(tableColumn), i < parent.columns.count else { return }
            parent.onSort?(parent.columns[i])
        }

        func tableViewSelectionDidChange(_ note: Notification) {
            guard let table, let binding = parent.selection else { return }
            let sel = table.selectedRowIndexes
            DispatchQueue.main.async { if binding.wrappedValue != sel { binding.wrappedValue = sel } }
        }

        @objc func copyCell() {
            guard let table, let cell = value(table.clickedRow, table.clickedColumn) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cell ?? "NULL", forType: .string)
        }

        @objc func setNull() {
            guard let table, parent.editable, value(table.clickedRow, table.clickedColumn) != nil else { return }
            parent.onEdit?(table.clickedRow, table.clickedColumn, nil)
        }
    }
}

// MARK: - SQL-szerkesztő Tab-kiegészítéssel

final class SQLTextView: NSTextView {
    static func isIdentifier(_ c: unichar) -> Bool {
        guard let u = UnicodeScalar(c) else { return false }
        return CharacterSet.alphanumerics.contains(u) || c == 95 || c == 36   // _ és $
    }

    /// A kurzor előtti azonosító (ezt cseréli le a kiegészítés).
    override var rangeForUserCompletion: NSRange {
        let ns = string as NSString
        let caret = selectedRange().location
        var start = caret
        while start > 0, SQLTextView.isIdentifier(ns.character(at: start - 1)) { start -= 1 }
        return NSRange(location: start, length: caret - start)
    }

    /// A pont előtti név, pl. "users.na" esetén "users".
    func qualifier(before range: NSRange) -> String? {
        let ns = string as NSString
        guard range.location > 0, ns.character(at: range.location - 1) == 46 else { return nil }
        var end = range.location - 1
        if end > 0, ns.character(at: end - 1) == 96 { end -= 1 }             // záró `
        var start = end
        while start > 0, SQLTextView.isIdentifier(ns.character(at: start - 1)) { start -= 1 }
        return start < end ? ns.substring(with: NSRange(location: start, length: end - start)) : nil
    }
}

struct SQLEditor: NSViewRepresentable {
    @Binding var text: String
    var completions: (_ prefix: String, _ qualifier: String?) -> [String]

    static let completeTest = Notification.Name("szerverpanel.completeTest")

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = SQLTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        tv.delegate = context.coordinator
        tv.string = text
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.textColor = .labelColor
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true

        let sv = NSScrollView()
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.drawsBackground = false
        sv.borderType = .noBorder
        context.coordinator.textView = tv
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.runCompleteTest),
                                               name: SQLEditor.completeTest, object: nil)
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if let tv = context.coordinator.textView, tv.string != text { tv.string = text }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLEditor
        weak var textView: SQLTextView?

        init(_ parent: SQLEditor) { self.parent = parent }

        func textDidChange(_ note: Notification) {
            guard let tv = textView, parent.text != tv.string else { return }
            parent.text = tv.string
        }

        private func candidates(_ tv: SQLTextView, _ range: NSRange) -> [String] {
            let prefix = (tv.string as NSString).substring(with: range)
            return parent.completions(prefix, tv.qualifier(before: range))
        }

        /// Tab: egy találatnál azonnal beírja, többnél listát nyit; szó nélkül sima tabulátor.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertTab(_:)), let tv = textView as? SQLTextView,
                  tv.selectedRange().length == 0 else { return false }
            let range = tv.rangeForUserCompletion
            if range.length == 0 && tv.qualifier(before: range) == nil { return false }
            let list = candidates(tv, range)
            if list.count == 1 {
                tv.insertText(list[0], replacementRange: range)
            } else if list.count > 1 {
                showMenu(list, for: range, in: tv)
            } else {
                NSSound.beep()
            }
            return true
        }

        func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange,
                      indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            guard let tv = textView as? SQLTextView else { return [] }
            index?.pointee = -1
            return candidates(tv, charRange)
        }

        private var pendingRange = NSRange(location: 0, length: 0)
        private weak var openMenu: NSMenu?

        /// Javaslatlista a kurzor alatt (nyilak + Enter választ, Esc bezár, betűre ugrik).
        private func showMenu(_ list: [String], for range: NSRange, in tv: SQLTextView) {
            pendingRange = range
            let menu = NSMenu()
            menu.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            for word in list.prefix(25) {
                let item = NSMenuItem(title: word, action: #selector(pick(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = word
                menu.addItem(item)
            }
            var point = NSPoint(x: 8, y: 20)
            if let window = tv.window {
                let screenRect = tv.firstRect(forCharacterRange: NSRange(location: range.location, length: 0), actualRange: nil)
                let inWindow = window.convertPoint(fromScreen: NSPoint(x: screenRect.minX, y: screenRect.minY))
                point = tv.convert(inWindow, from: nil)
                point.y += 4
            }
            openMenu = menu
            menu.popUp(positioning: nil, at: point, in: tv)
        }

        @objc private func pick(_ item: NSMenuItem) {
            guard let tv = textView, let word = item.representedObject as? String else { return }
            tv.insertText(word, replacementRange: pendingRange)
        }

        /// Csak önteszthez: a kurzort a szöveg végére teszi, és Tabot „nyom”; a listát 3 mp után bezárja.
        @objc func runCompleteTest() {
            guard let tv = textView else { return }
            NSApp.activate(ignoringOtherApps: true)
            tv.window?.makeKeyAndOrderFront(nil)
            let timer = Timer(timeInterval: 3, repeats: false) { [weak self] _ in self?.openMenu?.cancelTracking() }
            RunLoop.main.add(timer, forMode: .common)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                tv.window?.makeFirstResponder(tv)
                tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
                tv.doCommand(by: #selector(NSResponder.insertTab(_:)))
            }
        }
    }
}

// MARK: - Ablak

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
                        if open { m.expanded.insert(db); if m.tables[db] == nil { m.loadTables(db) } }
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

struct DBDetail: View {
    @EnvironmentObject var m: DBModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $m.tab) {
                ForEach(m.availableTabs, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .padding(.vertical, 8)
            Divider()
            switch m.tab {
            case .tables: TablesView()
            case .data: DataView()
            case .structure: StructureView()
            case .query: QueryView()
            }
        }
    }
}

struct TablesView: View {
    @EnvironmentObject var m: DBModel
    private static let sizeFmt: ByteCountFormatter = {
        let f = ByteCountFormatter(); f.countStyle = .binary; return f
    }()

    var body: some View {
        let list = m.currentDB.flatMap { m.tables[$0] } ?? []
        if list.isEmpty {
            VStack(spacing: 10) {
                Text("This database has no tables yet.").foregroundStyle(.secondary)
                Button("New Table…") { m.sheet = .newTable }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GridView(columns: ["Table", "Type", "Engine", "Rows (approx.)", "Size", "Collation"],
                     rows: list.map { [$0.name, $0.isView ? "view" : "table", $0.engine, $0.rows,
                                       TablesView.sizeFmt.string(fromByteCount: $0.bytes), $0.collation] },
                     version: list.hashValue)
        }
    }
}

struct DataView: View {
    @EnvironmentObject var m: DBModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.secondary)
                TextField("Filter – WHERE condition, e.g. id > 10 AND name LIKE 'a%'", text: $m.filter)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit { m.offset = 0; m.loadData() }
                Button { m.loadData() } label: { Image(systemName: "arrow.clockwise") }.help("Reload data")
                Divider().frame(height: 16)
                Button { m.sheet = .insertRow } label: { Label("New Row", systemImage: "plus") }
                    .disabled(m.currentTableInfo?.isView == true)
                Button {
                    let n = m.selectedRows.count
                    m.confirm = ConfirmRequest(title: "Delete the \(n) selected rows?", message: "This can't be undone.",
                                               button: "Delete") { m.deleteSelectedRows() }
                } label: { Label("Delete", systemImage: "minus") }
                .disabled(m.selectedRows.isEmpty || m.currentTableInfo?.isView == true)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()

            if let e = m.dataError {
                Text(e).foregroundStyle(.red).textSelection(.enabled).padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GridView(columns: m.data.columns, rows: m.data.rows, version: m.dataVersion,
                         editable: m.currentTableInfo?.isView != true,
                         sortColumn: m.orderBy, ascending: m.ascending, selection: $m.selectedRows,
                         onEdit: { r, c, v in m.updateCell(row: r, column: c, value: v) },
                         onSort: { m.sort(by: $0) })
            }

            Divider()
            HStack(spacing: 10) {
                Text(rangeText).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Text("Double-click to edit · right-click for NULL / copy").font(.caption).foregroundStyle(.secondary)
                Button { m.page(-1) } label: { Image(systemName: "chevron.left") }.disabled(m.offset == 0)
                Button { m.page(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(m.offset + m.data.rows.count >= (m.totalRows ?? 0))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    private var rangeText: String {
        let count = m.data.rows.count
        guard count > 0 else { return "0 rows" }
        let total = m.totalRows.map { " / \($0)" } ?? ""
        return "\(m.offset + 1)–\(m.offset + count)\(total) rows"
    }
}

struct StructureView: View {
    @EnvironmentObject var m: DBModel

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("Columns").font(.headline)
                    Spacer()
                    Button { m.sheet = .addColumn } label: { Label("Add Column", systemImage: "plus") }
                        .disabled(m.currentTableInfo?.isView == true)
                    Button {
                        guard let i = m.selectedColumns.first, i < m.columns.count else { return }
                        let name = m.columns[i].name
                        m.confirm = ConfirmRequest(title: "Delete the column “\(name)”?",
                                                   message: "All data in the column will be permanently deleted.",
                                                   button: "Delete") { m.dropColumn(name) }
                    } label: { Label("Delete Column", systemImage: "minus") }
                    .disabled(m.selectedColumns.count != 1 || m.currentTableInfo?.isView == true)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                Divider()
                GridView(columns: ["Name", "Type", "NULL", "Key", "Default", "Extra", "Collation", "Comment"],
                         rows: m.columns.map { [$0.name, $0.type, $0.null, $0.key, $0.def, $0.extra, $0.collation, $0.comment] },
                         version: m.dataVersion &+ m.columns.count, selection: $m.selectedColumns)
            }
            .frame(minHeight: 150)

            VStack(spacing: 0) {
                HStack { Text("Indexes").font(.headline); Spacer() }.padding(.horizontal, 12).padding(.vertical, 6)
                Divider()
                GridView(columns: ["Index", "Column", "Unique", "Type"],
                         rows: m.indexes.rows.indices.map { i in
                             [m.indexes.value(i, "Key_name"), m.indexes.value(i, "Column_name"),
                              m.indexes.value(i, "Non_unique") == "0" ? "yes" : "no", m.indexes.value(i, "Index_type")]
                         },
                         version: m.dataVersion &+ m.indexes.rows.count)
            }
            .frame(minHeight: 90)

            ScrollView {
                Text(m.createSQL)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .frame(minHeight: 90)
        }
    }
}

struct QueryView: View {
    @EnvironmentObject var m: DBModel

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                SQLEditor(text: $m.queryText, completions: { m.completions(prefix: $0, qualifier: $1) })
                    .background(Color(nsColor: .textBackgroundColor))
                Divider()
                HStack(spacing: 10) {
                    Button { m.runQuery() } label: { Label("Run", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                        .help("Run (⌘R)")
                    Text("Database: \(m.currentDB ?? "none selected")  ·  Tab: autocomplete").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if m.queryResults.count > 1 {
                        Picker("", selection: $m.shownResult) {
                            ForEach(m.queryResults.indices, id: \.self) { Text("Result \($0 + 1)").tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    Text(m.queryMessage).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .frame(minHeight: 120)

            Group {
                if let e = m.queryError {
                    ScrollView {
                        Text(e).foregroundStyle(.red).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                } else if m.shownResult < m.queryResults.count {
                    let set = m.queryResults[m.shownResult]
                    GridView(columns: set.columns, rows: set.rows, version: m.queryVersion &* 100 &+ m.shownResult)
                } else {
                    Text("Type an SQL statement and press ⌘R.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 140)
        }
    }
}

struct SQLLogView: View {
    @EnvironmentObject var m: DBModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(m.sqlLog) { line in
                        Text(line.text)
                            .foregroundStyle(line.isError ? Color.red : Color.secondary)
                            .lineLimit(2)
                            .id(line.id)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: m.sqlLog.count) {
                if let last = m.sqlLog.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}

// MARK: - Párbeszédablakok

struct SheetFrame<Content: View>: View {
    let title: String
    let confirm: String
    let canConfirm: Bool
    let action: () -> Void
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.weight(.semibold))
            content
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(confirm, action: action).keyboardShortcut(.defaultAction).disabled(!canConfirm)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

struct NewDatabaseSheet: View {
    @EnvironmentObject var m: DBModel
    @State private var name = ""
    @State private var collation = "utf8mb4_general_ci"

    var body: some View {
        SheetFrame(title: "New Database", confirm: "Create", canConfirm: !name.trimmed.isEmpty,
                   action: { m.createDatabase(name.trimmed, collation: collation) }) {
            Form {
                TextField("Name", text: $name)
                Picker("Collation", selection: $collation) {
                    ForEach(["utf8mb4_general_ci", "utf8mb4_unicode_ci", "utf8mb4_hungarian_ci", "utf8mb4_bin"], id: \.self) {
                        Text($0)
                    }
                }
            }
        }
    }
}

struct NewTableSheet: View {
    @EnvironmentObject var m: DBModel
    @State private var name = ""

    var body: some View {
        SheetFrame(title: "New Table – \(m.currentDB ?? "")", confirm: "Create", canConfirm: !name.trimmed.isEmpty,
                   action: { if let d = m.currentDB { m.createTable(name.trimmed, in: d) } }) {
            Form { TextField("Name", text: $name) }
            Text("The table is created with an auto-increment “id” primary key. Add the other columns on the Structure tab.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct AddColumnSheet: View {
    @EnvironmentObject var m: DBModel
    @State private var name = ""
    @State private var type = "VARCHAR(255)"
    @State private var nullable = true
    @State private var defaultValue = ""
    private let presets = ["INT", "BIGINT", "TINYINT(1)", "DECIMAL(10,2)", "FLOAT", "VARCHAR(255)", "TEXT", "LONGTEXT",
                           "DATE", "DATETIME", "TIMESTAMP", "JSON"]

    var body: some View {
        SheetFrame(title: "Add Column – \(m.currentTable ?? "")", confirm: "Add",
                   canConfirm: !name.trimmed.isEmpty && !type.trimmed.isEmpty,
                   action: { m.addColumn(name: name.trimmed, type: type.trimmed, nullable: nullable, defaultValue: defaultValue) }) {
            Form {
                TextField("Name", text: $name)
                HStack {
                    TextField("Type", text: $type)
                    Menu("Common") { ForEach(presets, id: \.self) { p in Button(p) { type = p } } }.fixedSize()
                }
                Toggle("Allow NULL", isOn: $nullable)
                TextField("Default", text: $defaultValue, prompt: Text("none"))
            }
        }
    }
}

struct InsertRowSheet: View {
    @EnvironmentObject var m: DBModel
    @State private var values: [String: String] = [:]

    var body: some View {
        SheetFrame(title: "New Row – \(m.currentTable ?? "")", confirm: "Insert", canConfirm: true,
                   action: { m.insertRow(values.filter { !$0.value.isEmpty }) }) {
            ScrollView {
                Form {
                    ForEach(m.columns) { c in
                        TextField(c.name, text: Binding(get: { values[c.name] ?? "" }, set: { values[c.name] = $0 }),
                                  prompt: Text(c.extra.contains("auto_increment") ? "automatic" : c.type))
                    }
                }
                .padding(.trailing, 6)
            }
            .frame(maxHeight: 360)
            Text("Fields left empty get their default value.").font(.callout).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Önteszt (indítás: open -a Szerverpanel --args --dbtest)

extension DBModel {
    private static var selfTestStarted = false

    func runSelfTest() {
        if DBModel.selfTestStarted { return }
        DBModel.selfTestStarted = true
        let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Szerverpanel-dbtest.log")
        try? FileManager.default.removeItem(at: logURL)
        var report = ""
        var failures = 0
        func out(_ s: String) { report += s + "\n"; try? Data(report.utf8).write(to: logURL) }
        func onMain<T>(_ f: () -> T) -> T { DispatchQueue.main.sync(execute: f) }
        func wait() {
            Thread.sleep(forTimeInterval: 0.5)
            var idle = 0
            for _ in 0..<200 {
                idle = onMain({ self.busyCount == 0 }) ? idle + 1 : 0
                if idle >= 3 { return }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        func check(_ ok: Bool, _ what: String) { out((ok ? "OK   " : "FAIL ") + what); if !ok { failures += 1 } }
        func cell(_ row: Int, _ col: String) -> String? { onMain { self.data.value(row, col) } }

        let db = "_szerverpanel_teszt", tricky = "Árvíztűrő 'tükörfúrógép' \\ <b>&\"x\""
        DispatchQueue.global(qos: .userInitiated).async {
            wait()
            onMain { self.alertMessage = nil }
            check(onMain { self.connectionError == nil && self.databases.contains("mysql") }, "Connect and list databases")

            if onMain({ self.databases.contains(db) }) { onMain { self.dropDatabase(db) }; wait() }
            onMain { self.createDatabase(db, collation: "utf8mb4_hungarian_ci") }; wait()
            check(onMain { self.databases.contains(db) }, "Create database")

            onMain { self.createTable("termekek", in: db) }; wait()
            check(onMain { self.selection == .table(db, "termekek") && self.columns.map(\.name) == ["id"] }, "Create table")

            onMain { self.addColumn(name: "nev", type: "VARCHAR(100)", nullable: true, defaultValue: "") }; wait()
            onMain { self.addColumn(name: "ar", type: "DECIMAL(10,2)", nullable: false, defaultValue: "0") }; wait()
            check(onMain { self.columns.map(\.name) == ["id", "nev", "ar"] }, "Add columns")

            onMain { self.insertRow(["nev": tricky, "ar": "1999.50"]) }; wait()
            onMain { self.insertRow(["nev": "Második", "ar": "500"]) }; wait()
            check(onMain { self.data.rows.count == 2 && self.totalRows == 2 }, "Insert rows")
            check(cell(0, "nev") == tricky, "Accented and special characters survive intact")

            onMain { self.updateCell(row: 1, column: 1, value: "Módosítva") }; wait()
            check(cell(1, "nev") == "Módosítva", "Edit cell")
            onMain { self.updateCell(row: 1, column: 1, value: nil) }; wait()
            check(onMain { self.data.rows.count == 2 && self.data.rows[1][1] == nil }, "Set cell to NULL")

            onMain { self.filter = "ar > 1000"; self.loadData() }; wait()
            check(onMain { self.data.rows.count == 1 && self.totalRows == 1 }, "Filter (WHERE)")
            onMain { self.filter = "nincs_ilyen = 1"; self.loadData() }; wait()
            check(onMain { self.dataError != nil }, "Invalid filter reports an error")
            onMain { self.filter = ""; self.sort(by: "ar") }; wait()
            check(cell(0, "ar") == "500.00", "Sort ascending")
            onMain { self.sort(by: "ar") }; wait()
            check(cell(0, "ar") == "1999.50", "Sort descending")

            onMain { self.queryText = "SELECT COUNT(*) AS db FROM termekek;\nSELECT nev, ar FROM termekek ORDER BY id;"; self.runQuery() }; wait()
            check(onMain { self.queryError == nil && self.queryResults.count == 2 && self.queryResults[0].rows.first?.first == "2"
                           && self.queryResults[1].rows.count == 2 }, "Query with multiple results")
            onMain { self.queryText = "UPDATE termekek SET ar = ar + 1"; self.runQuery() }; wait()
            check(onMain { self.queryMessage.contains("rows affected: 2") }, "Modifying query reports rows affected")
            onMain { self.queryText = "SELEC hiba"; self.runQuery() }; wait()
            check(onMain { self.queryError?.contains("1064") == true }, "Invalid SQL reports an error")

            let dumpPath = NSTemporaryDirectory() + "szerverpanel-teszt.sql"
            onMain { self.dump(db: db, table: nil, to: dumpPath) }; wait()
            let dumped = (try? String(contentsOfFile: dumpPath, encoding: .utf8)) ?? ""
            check(dumped.contains("CREATE TABLE `termekek`") && dumped.contains("tükörfúrógép"), "Export to SQL file")
            try? FileManager.default.removeItem(atPath: dumpPath)

            check(onMain { self.completions(prefix: "terme", qualifier: nil) } == ["termekek"], "Completion: table name")
            check(onMain { self.completions(prefix: "", qualifier: "termekek") } == ["id", "nev", "ar"], "Completion: columns after table.")
            check(onMain { self.completions(prefix: "SEL", qualifier: nil) } == ["SELECT"], "Completion: keyword")
            check(onMain { self.completions(prefix: "CRE", qualifier: nil).first } == "CREATE", "Completion: CREATE comes first")
            check(onMain { self.completions(prefix: "TAB", qualifier: nil).prefix(2) } == ["TABLE", "TABLES"], "Completion: TABLE")
            check(onMain { self.completions(prefix: "tab", qualifier: nil).first } == "table", "Completion: lowercase stays lowercase")
            check(onMain { ["VARCHAR", "AUTO_INCREMENT", "GROUP_CONCAT", "ENGINE", "CONSTRAINT"].allSatisfy { w in
                self.completions(prefix: String(w.prefix(5)), qualifier: nil).contains(w) } }, "Completion: types, functions, options")
            check(onMain { self.completions(prefix: "n", qualifier: "t").contains("nev") }, "Completion: columns after an alias")

            onMain { self.tab = .query; self.queryText = "SELECT * FROM terme" }
            Thread.sleep(forTimeInterval: 0.8)
            onMain { NotificationCenter.default.post(name: SQLEditor.completeTest, object: nil) }
            Thread.sleep(forTimeInterval: 1.2)
            check(onMain { self.queryText } == "SELECT * FROM termekek", "Tab in the editor inserts the single match")
            onMain { self.queryText = "SELECT * FROM termekek WHERE termekek." }
            Thread.sleep(forTimeInterval: 0.5)
            DispatchQueue.main.async { NotificationCenter.default.post(name: SQLEditor.completeTest, object: nil) }
            out("PAUSE")
            Thread.sleep(forTimeInterval: 5)
            onMain { self.queryText = "SELECT * FROM termekek;"; self.runQuery(); self.tab = .data; self.loadData() }; wait()

            onMain { self.selectedRows = [0]; self.deleteSelectedRows() }; wait()
            check(onMain { self.data.rows.count == 1 }, "Delete row")
            onMain { self.dropColumn("ar") }; wait()
            check(onMain { self.columns.map(\.name) == ["id", "nev"] }, "Delete Column")
            onMain { self.truncateTable("termekek", in: db) }; wait()
            check(onMain { self.data.rows.isEmpty }, "Empty table")
            onMain { self.dropTable("termekek", in: db) }; wait()
            check(onMain { self.tables[db]?.isEmpty == true }, "Delete table")
            onMain { self.dropDatabase(db) }; wait()
            check(onMain { !self.databases.contains(db) }, "Delete database")
            check(onMain { self.alertMessage == nil }, "No unexpected error message left")

            out(failures == 0 ? "DATABASE SELF-TEST PASSED" : "DATABASE SELF-TEST FAILED: \(failures) failures")
        }
    }
}
