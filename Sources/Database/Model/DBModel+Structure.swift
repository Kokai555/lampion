import SwiftUI
import AppKit

/// Table structure: columns, indexes, foreign keys, table options and the table designer.
extension DBModel {
    static let engines = ["InnoDB", "MyISAM", "Aria", "MEMORY"]
    static let collations = ["utf8mb4_general_ci", "utf8mb4_unicode_ci", "utf8mb4_hungarian_ci", "utf8mb4_bin"]
    static let typePresets = ["INT", "INT UNSIGNED", "BIGINT", "TINYINT(1)", "DECIMAL(10,2)", "FLOAT", "DOUBLE", "VARCHAR(255)",
                              "CHAR(10)", "TEXT", "LONGTEXT", "DATE", "DATETIME", "TIMESTAMP", "TIME", "JSON", "BLOB"]
    static let referenceRules = ["RESTRICT", "CASCADE", "SET NULL", "NO ACTION"]

    /// The indexes of the selected table, one entry per index.
    var indexList: [IndexInfo] {
        var list: [IndexInfo] = []
        for i in indexes.rows.indices {
            guard let name = indexes.value(i, "Key_name"), let column = indexes.value(i, "Column_name") else { continue }
            if let at = list.firstIndex(where: { $0.name == name }) {
                list[at].columns.append(column)
            } else {
                list.append(IndexInfo(name: name, columns: [column], unique: indexes.value(i, "Non_unique") == "0",
                                      type: indexes.value(i, "Index_type") ?? ""))
            }
        }
        return list
    }

    func foreignKeySQL(db: String, table: String) -> String {
        "SELECT k.CONSTRAINT_NAME, k.COLUMN_NAME, k.REFERENCED_TABLE_SCHEMA, k.REFERENCED_TABLE_NAME, k.REFERENCED_COLUMN_NAME, "
        + "r.UPDATE_RULE, r.DELETE_RULE FROM information_schema.KEY_COLUMN_USAGE k "
        + "JOIN information_schema.REFERENTIAL_CONSTRAINTS r ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA "
        + "AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME AND r.TABLE_NAME = k.TABLE_NAME "
        + "WHERE k.TABLE_SCHEMA = \(SQL.val(db)) AND k.TABLE_NAME = \(SQL.val(table)) AND k.REFERENCED_TABLE_NAME IS NOT NULL "
        + "ORDER BY k.CONSTRAINT_NAME, k.ORDINAL_POSITION;"
    }

    func parseForeignKeys(_ set: ResultSet) -> [ForeignKeyInfo] {
        set.rows.map { row in
            let v = row.map { $0 ?? "" } + Array(repeating: "", count: 7)
            return ForeignKeyInfo(name: v[0], column: v[1], refSchema: v[2], refTable: v[3], refColumn: v[4], updateRule: v[5], deleteRule: v[6])
        }
    }

    // Columns

    /// Adds a column (`replacing` is nil) or changes an existing one.
    func saveColumn(_ draft: ColumnDraft, replacing old: String?, position: ColumnPosition = .unchanged, then: (() -> Void)? = nil) {
        guard let fq else { return }
        var sql = "ALTER TABLE \(fq) " + (old.map { "CHANGE COLUMN \(SQL.id($0)) " } ?? "ADD COLUMN ")
        sql += "\(SQL.id(draft.name.trimmed)) \(draft.definition)"
        switch position {
        case .unchanged: break
        case .first: sql += " FIRST"
        case .after(let column): sql += " AFTER \(SQL.id(column))"
        }
        change(sql + ";") { ok in
            if ok { self.sheet = nil }
            self.loadTable(then: then)
        }
    }

    // Indexes

    func addIndex(name: String, kind: IndexKind, columns: [String], then: (() -> Void)? = nil) {
        guard let fq, !columns.isEmpty else { return }
        let cols = "(" + columns.map(SQL.id).joined(separator: ", ") + ")"
        let label = name.trimmed.isEmpty ? "" : SQL.id(name.trimmed) + " "
        let what: String
        switch kind {
        case .primary: what = "PRIMARY KEY "
        case .unique: what = "UNIQUE INDEX " + label
        case .fulltext: what = "FULLTEXT INDEX " + label
        case .index: what = "INDEX " + label
        }
        change("ALTER TABLE \(fq) ADD \(what)\(cols);") { ok in
            if ok { self.sheet = nil }
            self.loadTable(then: then)
        }
    }

    func dropIndex(_ name: String, then: (() -> Void)? = nil) {
        guard let fq else { return }
        let what = name == "PRIMARY" ? "PRIMARY KEY" : "INDEX \(SQL.id(name))"
        change("ALTER TABLE \(fq) DROP \(what);") { _ in self.loadTable(then: then) }
    }

    // Foreign keys

    func addForeignKey(name: String, column: String, refTable: String, refColumn: String,
                       onDelete: String, onUpdate: String, then: (() -> Void)? = nil) {
        guard let fq, let db = currentDB else { return }
        let constraint = name.trimmed.isEmpty ? "" : "CONSTRAINT \(SQL.id(name.trimmed)) "
        let sql = "ALTER TABLE \(fq) ADD \(constraint)FOREIGN KEY (\(SQL.id(column))) "
            + "REFERENCES \(SQL.id(db)).\(SQL.id(refTable)) (\(SQL.id(refColumn))) ON DELETE \(onDelete) ON UPDATE \(onUpdate);"
        change(sql) { ok in
            if ok { self.sheet = nil }
            self.loadTable(then: then)
        }
    }

    func dropForeignKey(_ name: String, then: (() -> Void)? = nil) {
        guard let fq else { return }
        change("ALTER TABLE \(fq) DROP FOREIGN KEY \(SQL.id(name));") { _ in self.loadTable(then: then) }
    }

    // Table designer

    func createTable(name: String, in db: String, columns: [ColumnDraft], engine: String, collation: String, then: (() -> Void)? = nil) {
        var defs = columns.map { "  \(SQL.id($0.name.trimmed)) \($0.definition)" }
        let keys = columns.filter(\.primaryKey).map { SQL.id($0.name.trimmed) }
        if !keys.isEmpty { defs.append("  PRIMARY KEY (\(keys.joined(separator: ", ")))") }
        let charset = String(collation.split(separator: "_").first ?? "utf8mb4")
        let sql = "CREATE TABLE \(SQL.id(db)).\(SQL.id(name.trimmed)) (\n\(defs.joined(separator: ",\n"))\n) "
            + "ENGINE=\(engine) DEFAULT CHARSET=\(charset) COLLATE=\(collation);"
        change(sql) { ok in
            self.loadTables(db) {
                if ok {
                    self.sheet = nil
                    self.tab = .structure
                    self.selection = .table(db, name.trimmed)
                }
                then?()
            }
        }
    }

    // Table operations

    /// Renames the selected table and/or moves it to another database.
    func renameTable(to newName: String, database newDB: String, then: (() -> Void)? = nil) {
        guard let fq, let oldDB = currentDB else { return }
        change("RENAME TABLE \(fq) TO \(SQL.id(newDB)).\(SQL.id(newName.trimmed));") { ok in
            self.loadTables(oldDB)
            self.loadTables(newDB) {
                if ok {
                    self.sheet = nil
                    self.expanded.insert(newDB)
                    self.selection = .table(newDB, newName.trimmed)
                }
                then?()
            }
        }
    }

    func copyTable(to newName: String, withData: Bool, then: (() -> Void)? = nil) {
        guard let fq, let db = currentDB else { return }
        let target = "\(SQL.id(db)).\(SQL.id(newName.trimmed))"
        var sql = "CREATE TABLE \(target) LIKE \(fq);"
        if withData { sql += "\nINSERT INTO \(target) SELECT * FROM \(fq);" }
        change(sql) { ok in
            if ok { self.infoMessage = "Copied to “\(newName.trimmed)”." }
            self.loadTables(db, then: then)
        }
    }

    func setTableOptions(engine: String?, collation: String?, then: (() -> Void)? = nil) {
        guard let fq, let db = currentDB else { return }
        var options: [String] = []
        if let engine { options.append("ENGINE = \(engine)") }
        if let collation {
            let charset = String(collation.split(separator: "_").first ?? "utf8mb4")
            options.append("CONVERT TO CHARACTER SET \(charset) COLLATE \(collation)")
        }
        guard !options.isEmpty else { then?(); return }
        change("ALTER TABLE \(fq) \(options.joined(separator: ", "));") { _ in
            self.loadTables(db) { self.loadTable(then: then) }
        }
    }

    /// OPTIMIZE, REPAIR, ANALYZE or CHECK; the server's answer is shown to the user.
    func maintenance(_ operation: String, then: (() -> Void)? = nil) {
        guard let fq else { return }
        exec("\(operation) TABLE \(fq);") { r in
            if let e = r.error {
                self.alertMessage = e
            } else {
                let set = r.sets.first ?? ResultSet()
                let lines = set.rows.indices.map { "\(set.value($0, "Msg_type") ?? ""): \(set.value($0, "Msg_text") ?? "")" }
                self.infoMessage = "\(operation.capitalized) finished.\n" + lines.joined(separator: "\n")
            }
            then?()
        }
    }
}
