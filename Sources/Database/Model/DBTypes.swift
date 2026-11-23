import SwiftUI
import AppKit

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
