import SwiftUI
import AppKit

enum SQLSyntax {
    enum Kind { case keyword, function, type, string, number, comment, identifier, error }
    struct Token { let range: NSRange; let kind: Kind }

    static let types: Set<String> = ["INT", "INTEGER", "BIGINT", "SMALLINT", "MEDIUMINT", "TINYINT", "DECIMAL", "DEC", "NUMERIC", "FLOAT",
        "DOUBLE", "REAL", "BIT", "BOOL", "BOOLEAN", "SERIAL", "CHAR", "VARCHAR", "NVARCHAR", "BINARY", "VARBINARY", "TEXT", "TINYTEXT",
        "MEDIUMTEXT", "LONGTEXT", "BLOB", "TINYBLOB", "MEDIUMBLOB", "LONGBLOB", "DATE", "DATETIME", "TIMESTAMP", "TIME", "YEAR", "ENUM",
        "JSON", "GEOMETRY", "UNSIGNED", "SIGNED", "ZEROFILL"]

    static let functions: Set<String> = ["COUNT", "SUM", "AVG", "MIN", "MAX", "CONCAT", "COALESCE", "IFNULL", "NOW", "IF", "ABS", "ADDDATE",
        "ADDTIME", "AES_DECRYPT", "AES_ENCRYPT", "BIN", "BIT_LENGTH", "CAST", "CEIL", "CEILING", "CHAR_LENGTH", "CONCAT_WS", "CONNECTION_ID",
        "CONVERT", "CURDATE", "CURTIME", "DATABASE", "DATEDIFF", "DATE_ADD", "DATE_FORMAT", "DATE_SUB", "DAY", "DAYNAME", "DAYOFMONTH",
        "DAYOFWEEK", "DAYOFYEAR", "DENSE_RANK", "ELT", "EXP", "EXTRACT", "FIELD", "FIND_IN_SET", "FIRST_VALUE", "FLOOR", "FORMAT", "FOUND_ROWS",
        "FROM_UNIXTIME", "GREATEST", "GROUP_CONCAT", "HEX", "HOUR", "INET_ATON", "INET_NTOA", "INSTR", "ISNULL", "JSON_ARRAY", "JSON_ARRAYAGG",
        "JSON_CONTAINS", "JSON_EXTRACT", "JSON_LENGTH", "JSON_OBJECT", "JSON_OBJECTAGG", "JSON_SET", "JSON_UNQUOTE", "JSON_VALUE", "LAG",
        "LAST_DAY", "LAST_INSERT_ID", "LAST_VALUE", "LCASE", "LEAD", "LEAST", "LEFT", "LENGTH", "LN", "LOCATE", "LOG", "LOWER", "LPAD", "LTRIM",
        "MAKEDATE", "MD5", "MINUTE", "MOD", "MONTH", "MONTHNAME", "NULLIF", "NTILE", "PI", "POSITION", "POW", "POWER", "QUARTER", "RAND", "RANK",
        "REPEAT", "REPLACE", "REVERSE", "RIGHT", "ROUND", "ROW_COUNT", "ROW_NUMBER", "RPAD", "RTRIM", "SECOND", "SHA1", "SHA2", "SIGN", "SLEEP",
        "SQRT", "STR_TO_DATE", "SUBDATE", "SUBSTR", "SUBSTRING", "SUBSTRING_INDEX", "SYSDATE", "TIMEDIFF", "TIMESTAMPDIFF", "TIME_FORMAT",
        "TO_DAYS", "TRIM", "TRUNCATE", "UCASE", "UNHEX", "UNIX_TIMESTAMP", "UPPER", "USER", "UTC_TIMESTAMP", "UUID", "VERSION", "WEEK",
        "WEEKDAY", "YEARWEEK"]

    static let keywords: Set<String> = Set(DBModel.keywords.filter { !$0.contains(" ") && $0 == $0.uppercased() })

    static func color(_ kind: Kind) -> NSColor {
        switch kind {
        case .keyword: return .systemPurple
        case .function: return .systemBlue
        case .type: return .systemTeal
        case .string: return .systemRed
        case .number: return .systemGreen
        case .comment: return .secondaryLabelColor
        case .identifier: return .systemOrange
        case .error: return .systemRed
        }
    }

    /// Szavakra bontja az SQL-t. `.error`: lezáratlan idézőjel vagy pár nélküli zárójel.
    static func tokenize(_ text: String) -> [Token] {
        let s = text as NSString
        let n = s.length
        var out: [Token] = []
        var parens: [Int] = []
        var i = 0
        func ch(_ k: Int) -> unichar { k < n ? s.character(at: k) : 0 }
        func isDigit(_ c: unichar) -> Bool { c >= 48 && c <= 57 }
        func lineEnd(_ from: Int) -> Int { var j = from; while j < n && ch(j) != 10 { j += 1 }; return j }
        func add(_ start: Int, _ end: Int, _ kind: Kind) { out.append(Token(range: NSRange(location: start, length: end - start), kind: kind)) }

        while i < n {
            let c = ch(i)
            let dashComment = c == 45 && ch(i + 1) == 45 && (i + 2 >= n || ch(i + 2) == 32 || ch(i + 2) == 9 || ch(i + 2) == 10)
            if dashComment || c == 35 {                                   // -- megjegyzés, # megjegyzés
                let j = lineEnd(i); add(i, j, .comment); i = j; continue
            }
            if c == 47 && ch(i + 1) == 42 {                               // /* megjegyzés */
                var j = i + 2
                while j < n && !(ch(j) == 42 && ch(j + 1) == 47) { j += 1 }
                j = min(n, j + 2); add(i, j, .comment); i = j; continue
            }
            if c == 39 || c == 34 || c == 96 {                            // 'szöveg', "szöveg", `név`
                var j = i + 1
                var closed = false
                while j < n {
                    let d = ch(j)
                    if d == 92 && c != 96 { j += 2; continue }
                    if d == c {
                        if ch(j + 1) == c { j += 2; continue }
                        closed = true; j += 1; break
                    }
                    j += 1
                }
                if closed {
                    add(i, min(j, n), c == 96 ? .identifier : .string); i = min(j, n)
                } else {
                    let j = lineEnd(i); add(i, j, .error); i = max(j, i + 1)
                }
                continue
            }
            if isDigit(c) && (i == 0 || !SQLTextView.isIdentifier(ch(i - 1))) {
                var j = i
                while j < n && (SQLTextView.isIdentifier(ch(j)) || ch(j) == 46) { j += 1 }
                add(i, j, .number); i = j; continue
            }
            if SQLTextView.isIdentifier(c) {
                var j = i
                while j < n && SQLTextView.isIdentifier(ch(j)) { j += 1 }
                let word = s.substring(with: NSRange(location: i, length: j - i)).uppercased()
                var k = j
                while k < n && (ch(k) == 32 || ch(k) == 9) { k += 1 }
                if functions.contains(word) && ch(k) == 40 { add(i, j, .function) }
                else if types.contains(word) { add(i, j, .type) }
                else if keywords.contains(word) { add(i, j, .keyword) }
                i = j; continue
            }
            if c == 40 { parens.append(i) }
            if c == 41 { if parens.isEmpty { add(i, i + 1, .error) } else { parens.removeLast() } }
            i += 1
        }
        for p in parens { add(p, p + 1, .error) }
        return out
    }

    private static func firstMatch(_ pattern: String, _ text: String, group: Int = 1) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let m = re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              m.numberOfRanges > group, m.range(at: group).location != NSNotFound else { return nil }
        return (text as NSString).substring(with: m.range(at: group))
    }

    /// A MariaDB hibaüzenete alapján megkeresi a hibás részt a szerkesztő szövegében.
    static func errorRanges(message: String, in text: String) -> [NSRange] {
        let s = text as NSString
        guard s.length > 0 else { return [] }
        func wordRange(at location: Int) -> NSRange {
            var end = location
            while end < s.length, let u = UnicodeScalar(s.character(at: end)), !CharacterSet.whitespacesAndNewlines.contains(u) { end += 1 }
            return NSRange(location: location, length: max(1, end - location))
        }

        // 1) Szintaktikai hiba: "... near 'RÉSZLET' at line N"
        if message.contains("near '") {
            let fragment = firstMatch("near '(.*)' at line \\d+", message) ?? ""
            let head = String((fragment.split(separator: "\n").first ?? "").prefix(40))
            if !head.trimmed.isEmpty {
                let r = s.range(of: head)
                if r.location != NSNotFound { return [wordRange(at: r.location)] }
            }
            // A hiba az utasítás végén van: az utolsó szót jelöljük.
            var end = s.length
            while end > 0, let u = UnicodeScalar(s.character(at: end - 1)), CharacterSet.whitespacesAndNewlines.contains(u) || u == ";" { end -= 1 }
            var start = end
            while start > 0, let u = UnicodeScalar(s.character(at: start - 1)), !CharacterSet.whitespacesAndNewlines.contains(u) { start -= 1 }
            return end > start ? [NSRange(location: start, length: end - start)] : []
        }

        // 2) Ismeretlen oszlop, tábla, adatbázis: az idézőjelben lévő nevet keressük.
        if let quoted = firstMatch("'([^']+)'", message) {
            for name in [quoted, String(quoted.split(separator: ".").last ?? "")] where !name.isEmpty {
                let pattern = "(?<![A-Za-z0-9_$])" + NSRegularExpression.escapedPattern(for: name) + "(?![A-Za-z0-9_$])"
                if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                   let m = re.firstMatch(in: text, range: NSRange(location: 0, length: s.length)) { return [m.range] }
            }
        }

        // 3) Végső esetben a jelzett sor.
        if let lineText = firstMatch("at line (\\d+)", message), let line = Int(lineText), line >= 1 {
            var start = 0
            for _ in 1..<line {
                let r = s.range(of: "\n", range: NSRange(location: start, length: s.length - start))
                if r.location == NSNotFound { break }
                start = r.location + 1
            }
            let r = s.lineRange(for: NSRange(location: min(start, s.length - 1), length: 0))
            return [r]
        }
        return []
    }
}
