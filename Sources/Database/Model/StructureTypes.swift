import SwiftUI
import AppKit

/// One index of a table, with its columns in order.
struct IndexInfo: Identifiable, Equatable {
    var id: String { name }
    let name: String
    var columns: [String]
    let unique: Bool
    let type: String
    var isPrimary: Bool { name == "PRIMARY" }
}

struct ForeignKeyInfo: Identifiable, Equatable {
    var id: String { name + "." + column }
    let name, column, refSchema, refTable, refColumn, updateRule, deleteRule: String
}

enum IndexKind: String, CaseIterable, Identifiable {
    case index = "Index", unique = "Unique", primary = "Primary Key", fulltext = "Fulltext"
    var id: String { rawValue }
}

enum ColumnPosition: Hashable {
    case unchanged, first, after(String)
}

enum StructureSection: String, CaseIterable, Identifiable {
    case columns = "Columns", indexes = "Indexes", foreignKeys = "Foreign Keys", sql = "SQL"
    var id: String { rawValue }
}

/// An editable column definition, used when adding or changing a column and in the table designer.
struct ColumnDraft: Identifiable, Equatable {
    let id = UUID()
    var name = ""
    var type = "VARCHAR(255)"
    var nullable = true
    /// Empty means no default. `NULL`, numbers, quoted text and known functions are used as written; anything else is quoted.
    var defaultText = ""
    var autoIncrement = false
    var primaryKey = false
    var onUpdateTimestamp = false
    var comment = ""

    init() {}

    init(name: String, type: String, nullable: Bool = true, defaultText: String = "", autoIncrement: Bool = false, primaryKey: Bool = false) {
        self.name = name; self.type = type; self.nullable = nullable
        self.defaultText = defaultText; self.autoIncrement = autoIncrement; self.primaryKey = primaryKey
    }

    /// Fills the draft from an existing column so that saving it unchanged keeps the column as it is.
    init(_ info: ColumnInfo) {
        name = info.name
        type = info.type
        nullable = info.null == "YES"
        if let def = info.def { defaultText = def.isEmpty ? "''" : def }
        autoIncrement = info.extra.lowercased().contains("auto_increment")
        onUpdateTimestamp = info.extra.lowercased().contains("on update")
        primaryKey = info.key == "PRI"
        comment = info.comment
    }

    /// Everything after the column name in a column definition.
    var definition: String {
        var parts = [type.trimmed, nullable ? "NULL" : "NOT NULL"]
        if !autoIncrement, let d = SQL.defaultClause(defaultText) { parts.append("DEFAULT " + d) }
        if autoIncrement { parts.append("AUTO_INCREMENT") }
        if onUpdateTimestamp { parts.append("ON UPDATE CURRENT_TIMESTAMP") }
        if !comment.isEmpty { parts.append("COMMENT " + SQL.val(comment)) }
        return parts.joined(separator: " ")
    }
}

extension SQL {
    /// Turns the text typed into a "Default" field into SQL, or nil for no default.
    static func defaultClause(_ text: String) -> String? {
        let t = text.trimmed
        if t.isEmpty { return nil }
        let upper = t.uppercased()
        if ["NULL", "TRUE", "FALSE"].contains(upper) || Double(t) != nil { return t }
        if t.count >= 2, t.hasPrefix("'"), t.hasSuffix("'") { return t }
        let functions = "^(current_timestamp|now|localtimestamp|current_date|curdate|current_time|curtime|uuid)(\\(\\d*\\))?$"
        if t.range(of: functions, options: [.regularExpression, .caseInsensitive]) != nil { return t }
        return val(t)
    }
}
