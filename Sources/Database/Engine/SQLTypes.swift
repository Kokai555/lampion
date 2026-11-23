import SwiftUI
import AppKit

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
