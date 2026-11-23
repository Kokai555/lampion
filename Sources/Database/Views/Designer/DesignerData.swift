import SwiftUI
import AppKit

// The Designer's picture of a database: every table and view with its columns, and every foreign key.
// Read with one round trip (three statements) per database.

/// A column as the Designer shows it.
struct DesignerColumn: Equatable, Hashable {
    let name: String
    let type: String
    /// PRI, UNI, MUL or empty.
    let key: String
    let nullable: Bool

    var isPrimary: Bool { key == "PRI" }
    var isIndexed: Bool { !key.isEmpty }
}

/// A table or view box.
struct DesignerTable: Equatable, Identifiable {
    var id: String { name }
    let name: String
    let isView: Bool
    let engine: String
    let columns: [DesignerColumn]

    func column(_ name: String) -> DesignerColumn? { columns.first { $0.name == name } }
}

/// One foreign key constraint: `table(columns)` → `refTable(refColumns)`. Composite keys have several column pairs.
struct DesignerRelation: Equatable, Identifiable, Hashable {
    var id: String { table + "\u{1}" + name }
    let name: String
    let table: String
    let columns: [String]
    let refSchema: String
    let refTable: String
    let refColumns: [String]
    let onDelete: String
    let onUpdate: String

    var isSelf: Bool { table == refTable }

    /// `orders.customer_id → customers.id · ON DELETE CASCADE`
    var summary: String {
        let from = columns.count == 1 ? "\(table).\(columns[0])" : "\(table).(\(columns.joined(separator: ", ")))"
        let target = refColumns.count == 1 ? "\(refTable).\(refColumns[0])" : "\(refTable).(\(refColumns.joined(separator: ", ")))"
        var text = "\(from) → \(target) · ON DELETE \(onDelete)"
        if onUpdate != "RESTRICT" && onUpdate != "NO ACTION" { text += " · ON UPDATE \(onUpdate)" }
        return text
    }
}

/// Everything the Designer draws for one database.
struct DesignerSchema: Equatable {
    var database: String
    var tables: [DesignerTable] = []
    /// Relations inside this database (lines are drawn for these).
    var relations: [DesignerRelation] = []
    /// Foreign keys that point into another database: shown on the column, not as lines.
    var external: [DesignerRelation] = []

    func table(_ name: String) -> DesignerTable? { tables.first { $0.name == name } }

    /// Tables that take part in at least one relation (a self-reference counts).
    var connected: Set<String> {
        var s = Set<String>()
        for r in relations { s.insert(r.table); s.insert(r.refTable) }
        return s
    }

    /// FK constraint names already used in the database (InnoDB wants them unique per database).
    var constraintNames: Set<String> { Set((relations + external).map { $0.name.lowercased() }) }
}

extension DBModel {
    /// Reads all tables, columns and foreign keys of `db` in one round trip.
    func loadDesignerSchema(_ db: String, done: @escaping (Result<DesignerSchema, DesignerLoadError>) -> Void) {
        let schema = SQL.val(db)
        let sql = "SELECT TABLE_NAME, TABLE_TYPE, IFNULL(ENGINE,'') FROM information_schema.TABLES "
            + "WHERE TABLE_SCHEMA = \(schema) ORDER BY TABLE_NAME;\n"
            + "SELECT TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, COLUMN_KEY, IS_NULLABLE FROM information_schema.COLUMNS "
            + "WHERE TABLE_SCHEMA = \(schema) ORDER BY TABLE_NAME, ORDINAL_POSITION;\n"
            + "SELECT k.TABLE_NAME, k.CONSTRAINT_NAME, k.COLUMN_NAME, k.REFERENCED_TABLE_SCHEMA, k.REFERENCED_TABLE_NAME, "
            + "k.REFERENCED_COLUMN_NAME, r.UPDATE_RULE, r.DELETE_RULE FROM information_schema.KEY_COLUMN_USAGE k "
            + "JOIN information_schema.REFERENTIAL_CONSTRAINTS r ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA "
            + "AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME AND r.TABLE_NAME = k.TABLE_NAME "
            + "WHERE k.TABLE_SCHEMA = \(schema) AND k.REFERENCED_TABLE_NAME IS NOT NULL "
            + "ORDER BY k.TABLE_NAME, k.CONSTRAINT_NAME, k.ORDINAL_POSITION;"
        exec(sql, quiet: true) { r in
            if let e = r.error { done(.failure(DesignerLoadError(message: e))); return }
            done(.success(DesignerSchema.parse(db, r.sets)))
        }
    }
}

struct DesignerLoadError: Error, Equatable {
    let message: String
}

extension DesignerSchema {
    static func parse(_ db: String, _ sets: [ResultSet]) -> DesignerSchema {
        func rows(_ i: Int) -> [[String]] {
            guard i < sets.count else { return [] }
            return sets[i].rows.map { $0.map { $0 ?? "" } + Array(repeating: "", count: 8) }
        }
        var columns: [String: [DesignerColumn]] = [:]
        for v in rows(1) {
            columns[v[0], default: []].append(DesignerColumn(name: v[1], type: v[2], key: v[3], nullable: v[4].uppercased() == "YES"))
        }
        let tables = rows(0).map { v in
            DesignerTable(name: v[0], isView: v[1] == "VIEW", engine: v[2], columns: columns[v[0]] ?? [])
        }
        // Group the key columns by constraint, keeping their order.
        var relations: [DesignerRelation] = []
        var external: [DesignerRelation] = []
        var current: (key: String, rows: [[String]])?
        func flush() {
            guard let c = current, let first = c.rows.first else { return }
            let rel = DesignerRelation(name: first[1], table: first[0], columns: c.rows.map { $0[2] },
                                       refSchema: first[3], refTable: first[4], refColumns: c.rows.map { $0[5] },
                                       onDelete: first[7], onUpdate: first[6])
            if rel.refSchema == db { relations.append(rel) } else { external.append(rel) }
        }
        for v in rows(2) {
            let key = v[0] + "\u{1}" + v[1]
            if current?.key == key {
                current?.rows.append(v)
            } else {
                flush()
                current = (key, [v])
            }
        }
        flush()
        let names = Set(tables.map(\.name))
        // A relation to a table that is not in the list (dropped meanwhile) cannot be drawn.
        return DesignerSchema(database: db, tables: tables,
                              relations: relations.filter { names.contains($0.table) && names.contains($0.refTable) },
                              external: external)
    }
}

enum DesignerType {
    /// `int(10) unsigned` → `int unsigned`, `varchar(255)` stays: integer display widths are noise in a diagram.
    static func compact(_ raw: String) -> String {
        var t = raw.lowercased()
        if let open = t.firstIndex(of: "("), let close = t[open...].firstIndex(of: ")") {
            let head = t[..<open]
            if ["int", "tinyint", "smallint", "mediumint", "bigint", "integer"].contains(String(head)), !t.hasPrefix("tinyint(1)") {
                t.removeSubrange(open...close)
            }
        }
        if t.hasPrefix("enum(") || t.hasPrefix("set(") { t = String(t.prefix { $0 != "(" }) }
        t = t.replacingOccurrences(of: " zerofill", with: "")
        return t.count > 22 ? String(t.prefix(21)) + "…" : t
    }

    /// The part of the type that must match for a foreign key: integer kind and signedness, or the type itself.
    static func fkComparable(_ raw: String) -> String {
        let t = raw.lowercased()
        if let open = t.firstIndex(of: "(") {
            let head = String(t[..<open])
            if ["int", "tinyint", "smallint", "mediumint", "bigint", "integer"].contains(head) {
                return head.replacingOccurrences(of: "integer", with: "int") + (t.contains("unsigned") ? " unsigned" : "")
            }
            // String lengths may differ.
            if ["char", "varchar", "binary", "varbinary"].contains(head) { return head }
        }
        return t
    }
}
