import Foundation

/// Reading and writing the server configuration files.
enum ConfigFile {
    struct Problem: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func read(_ path: String) throws -> String {
        do { return try String(contentsOfFile: path, encoding: .utf8) } catch {
            throw Problem("Could not read \(path): \(error.localizedDescription)")
        }
    }

    static func backupPath(_ path: String) -> String { path + ".lampion-backup" }

    /// Writes the file. The first time Lampion changes a file, the original is kept next to it as `<name>.lampion-backup`.
    static func write(_ text: String, to path: String) throws {
        let fm = FileManager.default
        let backup = backupPath(path)
        if fm.fileExists(atPath: path), !fm.fileExists(atPath: backup) {
            try? fm.copyItem(atPath: path, toPath: backup)
        }
        do { try text.write(toFile: path, atomically: true, encoding: .utf8) } catch {
            throw Problem("Could not write \(path): \(error.localizedDescription)")
        }
    }

    static func hasBackup(_ path: String) -> Bool { FileManager.default.fileExists(atPath: backupPath(path)) }

    /// Puts the original file (saved before Lampion's first change) back.
    static func restoreBackup(_ path: String) throws {
        let original = try read(backupPath(path))
        try original.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// `128M`, `2G`, `512K`, `1024` or `-1`.
    static func isSize(_ value: String) -> Bool {
        value.trimmed.range(of: "^(-1|[0-9]+[KMGkmg]?)$", options: .regularExpression) != nil
    }

    /// Bytes for a size such as `128M` (for comparisons only). Nil for -1, invalid or absurdly large values.
    static func bytes(_ value: String) -> Int64? {
        let t = value.trimmed.uppercased()
        guard isSize(t), t != "-1" else { return nil }
        let units: [Character: Int64] = ["K": 1 << 10, "M": 1 << 20, "G": 1 << 30]
        guard let last = t.last, let unit = units[last] else { return Int64(t) }
        guard let n = Int64(t.dropLast()) else { return nil }
        let r = n.multipliedReportingOverflow(by: unit)
        return r.overflow ? nil : r.partialValue
    }

    /// A size that is a positive amount (not -1 or 0) and not absurdly large.
    static func isPositiveSize(_ value: String) -> Bool {
        guard let b = bytes(value) else { return false }
        return b > 0
    }
}

// MARK: - Line editing helpers

/// Apache-style configuration: one directive per line, nested `<Section>` blocks.
struct ApacheConfText {
    var lines: [String]

    init(_ text: String) { lines = text.components(separatedBy: "\n") }
    var text: String { lines.joined(separator: "\n") }

    private func trimmed(_ i: Int) -> String { lines[i].trimmingCharacters(in: .whitespaces) }
    private func indent(_ i: Int) -> String { String(lines[i].prefix { $0 == " " || $0 == "\t" }) }

    /// Nesting depth before each line (0 = top level).
    private var depths: [Int] {
        var depth = 0
        return lines.indices.map { i in
            let t = trimmed(i)
            if t.hasPrefix("</") { depth = max(0, depth - 1); return depth }
            let d = depth
            if t.hasPrefix("<") && !t.hasPrefix("<!") { depth += 1 }
            return d
        }
    }

    private static func matches(_ line: String, _ directive: String) -> Bool {
        let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
        return parts.first.map { $0.caseInsensitiveCompare(directive) == .orderedSame } ?? false
    }

    /// Value of a top-level directive, without quotes.
    func value(_ directive: String) -> String? {
        let d = depths
        for i in lines.indices where d[i] == 0 {
            let t = trimmed(i)
            guard !t.hasPrefix("#"), Self.matches(t, directive) else { continue }
            return Self.unquote(String(t.dropFirst(directive.count)).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// Sets a top-level directive. Replaces the active line, else the first commented-out one, else appends.
    mutating func set(_ directive: String, _ value: String) {
        let d = depths
        let line = "\(directive) \(value)"
        if let i = lines.indices.first(where: { d[$0] == 0 && !trimmed($0).hasPrefix("#") && Self.matches(trimmed($0), directive) }) {
            lines[i] = indent(i) + line
        } else if let i = lines.indices.first(where: {
            d[$0] == 0 && trimmed($0).hasPrefix("#") && Self.matches(String(trimmed($0).dropFirst()).trimmingCharacters(in: .whitespaces), directive)
        }) {
            lines[i] = indent(i) + line
        } else {
            lines.append(line)
        }
    }

    /// Comments out a top-level directive, so Apache's built-in default applies.
    mutating func unset(_ directive: String) {
        let d = depths
        for i in lines.indices where d[i] == 0 && !trimmed(i).hasPrefix("#") && Self.matches(trimmed(i), directive) {
            lines[i] = indent(i) + "#" + trimmed(i)
        }
    }

    // Modules

    /// The module's LoadModule line, preferring an active one over a commented-out one.
    private func moduleLine(_ name: String) -> Int? {
        let candidates = lines.indices.filter { i in
            var t = trimmed(i)
            if t.hasPrefix("#") { t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces) }
            return t.hasPrefix("LoadModule \(name)_module ")
        }
        return candidates.first { !trimmed($0).hasPrefix("#") } ?? candidates.first
    }

    func moduleEnabled(_ name: String) -> Bool {
        guard let i = moduleLine(name) else { return false }
        return !trimmed(i).hasPrefix("#")
    }

    mutating func setModule(_ name: String, enabled: Bool) {
        if let i = moduleLine(name) {
            var t = trimmed(i)
            if t.hasPrefix("#") { t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces) }
            lines[i] = indent(i) + (enabled ? t : "#" + t)
        } else if enabled {
            // Add it after the last LoadModule line.
            let line = "LoadModule \(name)_module lib/httpd/modules/mod_\(name).so"
            let last = lines.indices.last { trimmed($0).hasPrefix("LoadModule ") }
            if let last { lines.insert(line, at: last + 1) } else { lines.append(line) }
        }
    }

    // <Directory "…"> blocks

    private func directoryBlock(_ path: String) -> Range<Int>? {
        let open = lines.indices.first { i in
            let t = trimmed(i)
            guard t.lowercased().hasPrefix("<directory ") else { return false }
            let arg = t.dropFirst("<directory ".count).trimmingCharacters(in: CharacterSet(charactersIn: " >"))
            return Self.unquote(arg).trimmingCharacters(in: CharacterSet(charactersIn: "/")) == path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        guard let open else { return nil }
        guard let close = lines.indices.first(where: { $0 > open && trimmed($0).lowercased().hasPrefix("</directory") }) else { return nil }
        return open..<(close + 1)
    }

    func directoryValue(_ path: String, _ directive: String) -> String? {
        guard let block = directoryBlock(path) else { return nil }
        for i in block where !trimmed(i).hasPrefix("#") && Self.matches(trimmed(i), directive) {
            return String(trimmed(i).dropFirst(directive.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    mutating func setDirectoryValue(_ path: String, _ directive: String, _ value: String) {
        guard let block = directoryBlock(path) else { return }
        if let i = block.first(where: { !trimmed($0).hasPrefix("#") && Self.matches(trimmed($0), directive) }) {
            lines[i] = indent(i) + "\(directive) \(value)"
        } else {
            lines.insert("    \(directive) \(value)", at: block.upperBound - 1)
        }
    }

    /// Points `<Directory "old">` at a new path.
    mutating func renameDirectory(_ old: String, to new: String) {
        guard let block = directoryBlock(old) else { return }
        lines[block.lowerBound] = indent(block.lowerBound) + "<Directory \"\(new)\">"
    }

    static func unquote(_ s: String) -> String {
        var t = s
        if t.hasPrefix("\""), t.hasSuffix("\""), t.count >= 2 { t = String(t.dropFirst().dropLast()) }
        return t
    }
}

/// php.ini style: `key = value`, `;` starts a comment.
struct IniText {
    var lines: [String]

    init(_ text: String) { lines = text.components(separatedBy: "\n") }
    var text: String { lines.joined(separator: "\n") }

    private static func key(of line: String) -> (key: String, value: String, commented: Bool)? {
        var t = line.trimmingCharacters(in: .whitespaces)
        var commented = false
        if t.hasPrefix(";") { commented = true; t = String(t.drop { $0 == ";" }).trimmingCharacters(in: .whitespaces) }
        guard let eq = t.firstIndex(of: "="), !t.hasPrefix("[") else { return nil }
        let k = t[..<eq].trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty, !k.contains(" ") else { return nil }
        var v = t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("\"") {
            // "quoted value" ; comment
            if let close = v.dropFirst().firstIndex(of: "\"") { v = String(v[v.index(after: v.startIndex)..<close]) }
        } else if let semi = v.firstIndex(of: ";") {
            v = v[..<semi].trimmingCharacters(in: .whitespaces)
        }
        return (k, v, commented)
    }

    /// The active value, or nil when the key is missing or commented out.
    func value(_ key: String) -> String? {
        var result: String?
        for line in lines {
            if let p = Self.key(of: line), !p.commented, p.key == key { result = p.value }
        }
        return result
    }

    mutating func set(_ key: String, _ value: String) {
        let line = "\(key) = \(value)"
        if let i = lines.indices.last(where: { Self.key(of: lines[$0]).map { !$0.commented && $0.key == key } ?? false }) {
            lines[i] = line
        } else if let i = lines.indices.first(where: { Self.key(of: lines[$0]).map { $0.commented && $0.key == key } ?? false }) {
            lines[i] = line
        } else {
            lines.append(line)
        }
    }

    /// Comments the key out so the built-in default applies.
    mutating func unset(_ key: String) {
        for i in lines.indices {
            if let p = Self.key(of: lines[i]), !p.commented, p.key == key { lines[i] = ";" + lines[i] }
        }
    }
}
