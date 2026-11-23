import Foundation

/// The php.ini settings Lampion edits.
struct PHPSettings: Equatable {
    var memoryLimit = "128M"
    var uploadMaxFilesize = "2M"
    var postMaxSize = "8M"
    var maxExecutionTime = 30
    var maxInputTime = 60
    var maxInputVars = 1000
    var displayErrors = true
    var displayStartupErrors = true
    var errorReporting = "E_ALL"
    var logErrors = true
    var separateErrorLog = false      // error_log = a file (Paths.phpErrorLog when Lampion sets it); otherwise Apache's error_log
    var timezone = ""                 // empty: not set (PHP uses UTC and warns)
    var shortOpenTag = false
    var opcache = true
    var sessionLifetime = 1440

    static let errorReportingPresets: [(title: String, value: String)] = [
        ("Everything (development)", "E_ALL"),
        ("Everything except deprecations", "E_ALL & ~E_DEPRECATED"),
        ("Production", "E_ALL & ~E_DEPRECATED & ~E_STRICT"),
        ("Errors only", "E_ERROR | E_PARSE | E_CORE_ERROR | E_COMPILE_ERROR"),
    ]

    /// Show every error on the page: the usual choice on a development machine.
    mutating func applyDevelopmentPreset() {
        displayErrors = true; displayStartupErrors = true; errorReporting = "E_ALL"; logErrors = true
    }

    /// Hide errors from the page and only log them, like a live server.
    mutating func applyProductionPreset() {
        displayErrors = false; displayStartupErrors = false; errorReporting = "E_ALL & ~E_DEPRECATED & ~E_STRICT"; logErrors = true
    }
}

enum PHPConfig {
    /// php.ini path, looked up once (asking PHP takes a moment).
    static let iniPathCached: String? = iniPath()

    /// The loaded php.ini, as PHP reports it.
    static func iniPath() -> String? {
        let r = Shell.run(Paths.php, ["-r", "echo php_ini_loaded_file();"])
        let p = r.out.trimmed
        return r.status == 0 && !p.isEmpty ? p : nil
    }

    private static func bool(_ v: String?, _ fallback: Bool) -> Bool {
        guard let v = v?.lowercased() else { return fallback }
        return ["1", "on", "true", "yes", "stdout", "stderr"].contains(v)
    }

    static func load(from path: String) throws -> PHPSettings { parse(try ConfigFile.read(path)) }

    static func parse(_ text: String) -> PHPSettings {
        let ini = IniText(text)
        var s = PHPSettings()
        s.memoryLimit = ini.value("memory_limit") ?? s.memoryLimit
        s.uploadMaxFilesize = ini.value("upload_max_filesize") ?? s.uploadMaxFilesize
        s.postMaxSize = ini.value("post_max_size") ?? s.postMaxSize
        s.maxExecutionTime = ini.value("max_execution_time").flatMap(Int.init) ?? s.maxExecutionTime
        s.maxInputTime = ini.value("max_input_time").flatMap(Int.init) ?? s.maxInputTime
        s.maxInputVars = ini.value("max_input_vars").flatMap(Int.init) ?? s.maxInputVars
        s.displayErrors = bool(ini.value("display_errors"), s.displayErrors)
        s.displayStartupErrors = bool(ini.value("display_startup_errors"), s.displayStartupErrors)
        s.errorReporting = ini.value("error_reporting") ?? s.errorReporting
        s.logErrors = bool(ini.value("log_errors"), s.logErrors)
        // A file path (not syslog / stderr) means PHP keeps its own error log.
        s.separateErrorLog = ini.value("error_log").map { $0.hasPrefix("/") } ?? false
        s.timezone = ini.value("date.timezone") ?? ""
        s.shortOpenTag = bool(ini.value("short_open_tag"), s.shortOpenTag)
        s.opcache = bool(ini.value("opcache.enable"), s.opcache)
        s.sessionLifetime = ini.value("session.gc_maxlifetime").flatMap(Int.init) ?? s.sessionLifetime
        return s
    }

    static func validate(_ s: PHPSettings) -> [String] {
        var problems: [String] = []
        if !(s.memoryLimit.trimmed == "-1" || ConfigFile.isPositiveSize(s.memoryLimit)) {
            problems.append("Memory limit must be a size such as 128M, 1G or -1 (no limit).")
        }
        if !ConfigFile.isPositiveSize(s.uploadMaxFilesize) {
            problems.append("Maximum upload size must be a size such as 2M or 64M.")
        }
        if !(["0", "-1"].contains(s.postMaxSize.trimmed) || ConfigFile.isPositiveSize(s.postMaxSize)) {
            problems.append("Maximum POST size must be a size such as 8M, or 0 for no limit.")
        }
        if let upload = ConfigFile.bytes(s.uploadMaxFilesize), let post = ConfigFile.bytes(s.postMaxSize), post != 0, post < upload {
            problems.append("Maximum POST size must be at least the maximum upload size, or uploads of that size fail.")
        }
        if s.maxExecutionTime < 0 || s.maxInputTime < -1 || s.maxInputVars < 1 || s.sessionLifetime < 1 {
            problems.append("Times and counts must be positive numbers.")
        }
        if !s.timezone.isEmpty && !isKnownTimezone(s.timezone) {
            problems.append("Unknown time zone: \(s.timezone). Use a name such as Europe/Budapest.")
        }
        return problems
    }

    /// Whether PHP knows the time zone name (PHP ignores capitalisation).
    /// The file PHP writes errors to, from php.ini (nil when PHP logs to Apache's error log).
    static var currentErrorLog: String? {
        guard let ini = iniPathCached, let text = try? String(contentsOfFile: ini, encoding: .utf8),
              let v = IniText(text).value("error_log"), v.hasPrefix("/") else { return nil }
        return v
    }

    static func isKnownTimezone(_ tz: String) -> Bool {
        if TimeZone.knownTimeZoneIdentifiers.contains(where: { $0.caseInsensitiveCompare(tz) == .orderedSame }) { return true }
        // Aliases such as CET, US/Pacific or Etc/GMT-2 are fine; offsets such as GMT+2 are not names PHP knows.
        return TimeZone(identifier: tz) != nil && tz.range(of: "^(GMT|UTC)[+-]", options: [.regularExpression, .caseInsensitive]) == nil
    }

    /// Writes only the settings that changed, so the rest of php.ini stays exactly as it was.
    static func apply(_ s: PHPSettings, to text: String) -> String {
        let old = parse(text)
        guard s != old else { return text }
        var ini = IniText(text)
        func on(_ b: Bool) -> String { b ? "On" : "Off" }
        func set<T: Equatable>(_ key: String, _ new: T, _ was: T, _ value: String) { if new != was { ini.set(key, value) } }
        set("memory_limit", s.memoryLimit, old.memoryLimit, s.memoryLimit.trimmed.uppercased())
        set("upload_max_filesize", s.uploadMaxFilesize, old.uploadMaxFilesize, s.uploadMaxFilesize.trimmed.uppercased())
        set("post_max_size", s.postMaxSize, old.postMaxSize, s.postMaxSize.trimmed.uppercased())
        set("max_execution_time", s.maxExecutionTime, old.maxExecutionTime, String(s.maxExecutionTime))
        set("max_input_time", s.maxInputTime, old.maxInputTime, String(s.maxInputTime))
        set("max_input_vars", s.maxInputVars, old.maxInputVars, String(s.maxInputVars))
        set("display_errors", s.displayErrors, old.displayErrors, on(s.displayErrors))
        set("display_startup_errors", s.displayStartupErrors, old.displayStartupErrors, on(s.displayStartupErrors))
        set("error_reporting", s.errorReporting, old.errorReporting, s.errorReporting.trimmed)
        set("log_errors", s.logErrors, old.logErrors, on(s.logErrors))
        if s.separateErrorLog != old.separateErrorLog {
            if s.separateErrorLog { ini.set("error_log", Paths.phpErrorLog) } else { ini.unset("error_log") }
        }
        if s.timezone != old.timezone {
            if s.timezone.isEmpty { ini.unset("date.timezone") } else { ini.set("date.timezone", s.timezone) }
        }
        set("short_open_tag", s.shortOpenTag, old.shortOpenTag, on(s.shortOpenTag))
        set("opcache.enable", s.opcache, old.opcache, s.opcache ? "1" : "0")
        set("session.gc_maxlifetime", s.sessionLifetime, old.sessionLifetime, String(s.sessionLifetime))
        return ini.text
    }

    /// Writes php.ini after PHP has accepted a test copy.
    static func save(_ s: PHPSettings, to path: String) throws {
        let current = try ConfigFile.read(path)
        let updated = apply(s, to: current)
        guard updated != current else { return }
        let tmp = NSTemporaryDirectory() + "lampion-php-test.ini"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try updated.write(toFile: tmp, atomically: true, encoding: .utf8)
        let r = Shell.run(Paths.php, ["-c", tmp, "-r", "echo 'ok';"])
        let warnings = r.out.split(separator: "\n").filter { $0.contains("Warning") || $0.contains("Error") }
        guard r.status == 0, r.out.hasSuffix("ok"), warnings.isEmpty else {
            throw ConfigFile.Problem("PHP rejected the new settings, so nothing was changed.\n\n" + r.out.trimmed)
        }
        if s.separateErrorLog, !FileManager.default.fileExists(atPath: Paths.phpErrorLog) {
            try? FileManager.default.createDirectory(atPath: (Paths.phpErrorLog as NSString).deletingLastPathComponent,
                                                     withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: Paths.phpErrorLog, contents: nil)
        }
        try ConfigFile.write(updated, to: path)
    }
}
