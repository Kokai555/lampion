import Foundation

/// MariaDB settings. Lampion keeps them in its own file, my.cnf.d/lampion.cnf, which my.cnf includes.
/// An empty value means "not set": the server's built-in default applies.
struct MariaDBSettings: Equatable {
    var port = ""
    var localOnly = false               // bind-address = 127.0.0.1
    var maxConnections = ""
    var maxAllowedPacket = ""
    var bufferPoolSize = ""
    var characterSet = ""
    var collation = ""
    var sqlMode = SQLMode.serverDefault
    var customSQLMode = ""              // a value set by hand that matches none of the presets
    var slowQueryLog = false
    var longQueryTime = ""
    var generalLog = false

    enum SQLMode: String, CaseIterable, Identifiable {
        case serverDefault, strict, relaxed, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .serverDefault: return "Server default"
            case .strict: return "Strict"
            case .relaxed: return "Relaxed (like old MySQL)"
            case .custom: return "Custom"
            }
        }
        var value: String? {
            switch self {
            case .serverDefault: return nil
            case .strict: return "STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION"
            case .relaxed: return "NO_ENGINE_SUBSTITUTION"
            case .custom: return nil
            }
        }
    }

    static let characterSets: [(charset: String, collations: [String])] = [
        ("utf8mb4", ["utf8mb4_uca1400_ai_ci", "utf8mb4_unicode_ci", "utf8mb4_general_ci", "utf8mb4_hungarian_ci", "utf8mb4_bin"]),
        ("utf8mb3", ["utf8mb3_unicode_ci", "utf8mb3_general_ci", "utf8mb3_hungarian_ci"]),
        ("latin1", ["latin1_swedish_ci", "latin1_general_ci", "latin1_bin"]),
        ("latin2", ["latin2_hungarian_ci", "latin2_general_ci"]),
    ]
}

enum MariaDBConfig {
    static var directory: String { "\(Paths.brew)/etc/my.cnf.d" }
    static var path: String { "\(directory)/lampion.cnf" }
    static var logDir: String { Paths.usesHome ? Paths.homeLogs + "/mariadb" : Paths.mysqlData }
    static var slowLog: String { "\(logDir)/lampion-slow.log" }
    static var generalLog: String { "\(logDir)/lampion-general.log" }

    /// key → value from the [mysqld] section of lampion.cnf.
    private static func values() -> [String: String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var section = "", result: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") { section = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]")); continue }
            guard section == "mysqld" else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = parts.first, !first.isEmpty else { continue }
            let key = first.replacingOccurrences(of: "-", with: "_")
            var value = parts.count > 1 ? parts[1] : "1"
            if value.hasPrefix("\"") {
                value = ApacheConfText.unquote(String(value.prefix { $0 != "#" }).trimmingCharacters(in: .whitespaces))
            } else if let hash = value.firstIndex(of: "#") {
                value = value[..<hash].trimmingCharacters(in: .whitespaces)
            }
            result[key] = value
        }
        return result
    }

    static func load() -> MariaDBSettings {
        let v = values()
        var s = MariaDBSettings()
        s.port = v["port"] ?? ""
        s.localOnly = ["127.0.0.1", "localhost", "::1"].contains(v["bind_address"] ?? "")
        s.maxConnections = v["max_connections"] ?? ""
        s.maxAllowedPacket = v["max_allowed_packet"] ?? ""
        s.bufferPoolSize = v["innodb_buffer_pool_size"] ?? ""
        s.characterSet = v["character_set_server"] ?? ""
        s.collation = v["collation_server"] ?? ""
        if let mode = v["sql_mode"] {
            if let preset = MariaDBSettings.SQLMode.allCases.first(where: { $0.value == mode }) {
                s.sqlMode = preset
            } else {
                s.sqlMode = .custom; s.customSQLMode = mode
            }
        }
        s.slowQueryLog = ["1", "on", "true"].contains(v["slow_query_log"]?.lowercased() ?? "")
        s.longQueryTime = v["long_query_time"] ?? ""
        s.generalLog = ["1", "on", "true"].contains(v["general_log"]?.lowercased() ?? "")
        return s
    }

    /// The port the server uses, taking every option file into account.
    static func effectivePort() -> Int {
        let r = Shell.run("\(Paths.brew)/bin/my_print_defaults", ["mysqld", "server", "mariadb"])
        var port = 3306
        for line in r.out.split(separator: "\n") where line.hasPrefix("--port=") {
            port = Int(line.dropFirst(7)) ?? port
        }
        return port
    }

    static func validate(_ s: MariaDBSettings) -> [String] {
        var problems: [String] = []
        if !s.port.trimmed.isEmpty, !(Int(s.port.trimmed).map { (1024...65535).contains($0) } ?? false) {
            problems.append("The port must be a number between 1024 and 65535.")
        }
        if !s.maxConnections.trimmed.isEmpty, (Int(s.maxConnections.trimmed) ?? 0) < 1 {
            problems.append("Maximum connections must be a positive number.")
        }
        for (name, v) in [("Maximum packet size", s.maxAllowedPacket), ("InnoDB buffer pool", s.bufferPoolSize)]
        where !v.trimmed.isEmpty && !ConfigFile.isPositiveSize(v) {
            problems.append("\(name) must be a size such as 64M or 1G.")
        }
        if !s.longQueryTime.trimmed.isEmpty, !(Double(s.longQueryTime.trimmed).map { $0.isFinite && $0 >= 0 } ?? false) {
            problems.append("The slow query threshold must be a number of seconds, such as 2 or 0.5.")
        }
        return problems
    }

    static func render(_ s: MariaDBSettings) -> String {
        var lines = [
            "# Written by Lampion. Change these settings in Lampion → MariaDB,",
            "# or put your own options in another file in this folder.",
            "[mysqld]",
        ]
        func add(_ key: String, _ value: String) { if !value.trimmed.isEmpty { lines.append("\(key) = \(value.trimmed)") } }
        // Where the data and the server log live (set when everything moved to ~/Lampion).
        let v = values()
        if let dir = v["datadir"] { add("datadir", dir) }
        if let err = v["log_error"] { add("log-error", err) }
        add("port", s.port)
        if s.localOnly { add("bind-address", "127.0.0.1") }
        add("max_connections", s.maxConnections)
        add("max_allowed_packet", s.maxAllowedPacket.uppercased())
        add("innodb_buffer_pool_size", s.bufferPoolSize.uppercased())
        add("character-set-server", s.characterSet)
        add("collation-server", s.collation)
        if let mode = s.sqlMode.value { add("sql_mode", "\"\(mode)\"") }
        if s.sqlMode == .custom { add("sql_mode", "\"\(s.customSQLMode)\"") }
        if s.slowQueryLog {
            add("slow_query_log", "1")
            add("slow_query_log_file", slowLog)
            add("long_query_time", s.longQueryTime.isEmpty ? "2" : s.longQueryTime)
        }
        if s.generalLog {
            add("general_log", "1")
            add("general_log_file", generalLog)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes lampion.cnf after MariaDB has accepted it, and makes sure my.cnf includes the folder.
    static func save(_ s: MariaDBSettings) throws {
        let fm = FileManager.default
        let text = render(s)
        let previous = try? String(contentsOfFile: path, encoding: .utf8)
        guard text != previous else { return }

        // MariaDB reads every option and stops at an unknown or invalid one, without starting a server.
        let tmp = NSTemporaryDirectory() + "lampion-mariadb-test.cnf"
        defer { try? fm.removeItem(atPath: tmp) }
        try text.write(toFile: tmp, atomically: true, encoding: .utf8)
        let r = Shell.run(Paths.mariadbd, ["--defaults-extra-file=\(tmp)", "--help", "--verbose"])
        if r.status != 0 {
            let errors = r.out.split(separator: "\n").filter { $0.contains("[ERROR]") }
                .map { $0.components(separatedBy: "[ERROR] ").last ?? String($0) }
            throw ConfigFile.Problem("MariaDB rejected the new settings, so nothing was changed.\n\n" + errors.prefix(3).joined(separator: "\n"))
        }

        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        if let cnf = try? String(contentsOfFile: Paths.myCnf, encoding: .utf8), !cnf.contains("!includedir \(directory)") {
            try ConfigFile.write(cnf + (cnf.hasSuffix("\n") ? "" : "\n") + "\n!includedir \(directory)\n", to: Paths.myCnf)
        }
        do { try text.write(toFile: path, atomically: true, encoding: .utf8) } catch {
            throw ConfigFile.Problem("Could not write \(path): \(error.localizedDescription)")
        }
    }

    /// Resets the settings to MariaDB's defaults. The data folder and log location stay, or the databases would vanish.
    static func reset() throws {
        let v = values()
        guard v["datadir"] != nil || v["log_error"] != nil else {
            if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
            return
        }
        try save(MariaDBSettings())
    }

    /// Sets MariaDB's log file (used when moving everything to ~/Lampion). Keeps the other settings.
    /// The data folder itself moves through a link, because Homebrew passes --datadir on the command line.
    static func setLocation(errorLog: String) throws {
        let settings = load()
        var lines = render(settings).components(separatedBy: "\n").filter {
            !$0.hasPrefix("datadir") && !$0.hasPrefix("log-error")
        }
        if let i = lines.firstIndex(of: "[mysqld]") {
            lines.insert("log-error = \(errorLog)", at: i + 1)
        }
        let text = lines.joined(separator: "\n")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        if let cnf = try? String(contentsOfFile: Paths.myCnf, encoding: .utf8), !cnf.contains("!includedir \(directory)") {
            try ConfigFile.write(cnf + (cnf.hasSuffix("\n") ? "" : "\n") + "\n!includedir \(directory)\n", to: Paths.myCnf)
        }
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
