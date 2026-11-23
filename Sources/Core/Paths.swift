import SwiftUI
import AppKit

enum Paths {
    /// Homebrew prefix. `LAMPION_PREFIX` overrides it (used by the setup test).
    static let brew = ProcessInfo.processInfo.environment["LAMPION_PREFIX"] ?? "/opt/homebrew"
    static let brewBin = "\(brew)/bin/brew"
    static let httpd = "\(brew)/bin/httpd"
    static let mariadbd = "\(brew)/bin/mariadbd"
    static let php = "\(brew)/bin/php"
    static let httpdConf = "\(brew)/etc/httpd/httpd.conf"
    static let vhostsConf = "\(brew)/etc/httpd/extra/httpd-vhosts.conf"
    static let apacheErrorLog_default = "\(brew)/var/log/httpd/error_log"
    static let apacheAccessLog_default = "\(brew)/var/log/httpd/access_log"
    static let myCnf = "\(brew)/etc/my.cnf"
    static let mysqlData_default = "\(brew)/var/mysql"
    static let pmaConf = "\(brew)/etc/phpmyadmin.config.inc.php"
    static let htdocs = "\(brew)/var/www"

    // MARK: The Lampion folder: ~/Lampion holds the sites, the databases, the logs and backups in one place.

    static var home: String { FileManager.default.homeDirectoryForCurrentUser.path + "/Lampion" }
    static var homeWWW: String { home + "/www" }
    static var homeDatabases: String { home + "/databases" }
    static var homeLogs: String { home + "/logs" }
    static var homeBackups: String { home + "/backups" }

    /// True once the databases live in ~/Lampion.
    static var usesHome: Bool { mysqlData.hasPrefix(home + "/") }

    // MARK: Where things are now — read from the configuration, so it is right wherever they live.

    static var apacheErrorLog: String { Locations.current.apacheErrorLog }
    static var apacheAccessLog: String { Locations.current.apacheAccessLog }
    static var mysqlData: String { Locations.current.mysqlData }
    /// Where PHP writes errors when "Separate PHP error log" is on.
    static var phpErrorLog: String {
        usesHome ? homeLogs + "/php/php_errors.log" : "\(brew)/var/log/php_errors.log"
    }
    /// MariaDB's own log: the configured log-error, else the newest <hostname>.err in the data folder
    /// (named after the Mac's network name, which can change).
    static var mysqlErrorLog: String? {
        if let configured = Locations.current.mysqlErrorLog { return configured }
        let fm = FileManager.default
        let dir = mysqlData
        let files = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".err") }
        func modified(_ f: String) -> Date {
            ((try? fm.attributesOfItem(atPath: "\(dir)/\(f)"))?[.modificationDate] as? Date) ?? .distantPast
        }
        return files.max { modified($0) < modified($1) }.map { "\(dir)/\($0)" }
    }
}

/// The current file locations, read from httpd.conf and MariaDB's option files. Cached; `refresh()` re-reads them.
struct Locations: Equatable {
    var apacheErrorLog = Paths.apacheErrorLog_default
    var apacheAccessLog = Paths.apacheAccessLog_default
    var mysqlData = Paths.mysqlData_default
    var mysqlErrorLog: String?

    private static let lock = NSLock()
    private static var cached: Locations?

    static var current: Locations {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let l = read()
        cached = l
        return l
    }

    @discardableResult
    static func refresh() -> Locations {
        let l = read()
        lock.lock(); cached = l; lock.unlock()
        return l
    }

    private static let apacheRoot = "\(Paths.brew)/opt/httpd"

    private static func absolute(_ path: String, root: String) -> String {
        path.hasPrefix("/") ? path : root + "/" + path
    }

    static func read() -> Locations {
        var l = Locations()
        if let conf = try? String(contentsOfFile: Paths.httpdConf, encoding: .utf8) {
            for raw in conf.components(separatedBy: "\n") {
                let t = raw.trimmingCharacters(in: .whitespaces)
                guard !t.hasPrefix("#") else { continue }
                if t.hasPrefix("ErrorLog ") {
                    let v = ApacheConfText.unquote(String(t.dropFirst(9)).trimmingCharacters(in: .whitespaces))
                    if !v.hasPrefix("|") && !v.hasPrefix("syslog") { l.apacheErrorLog = absolute(v, root: apacheRoot) }
                } else if t.hasPrefix("CustomLog ") {
                    let rest = String(t.dropFirst(10)).trimmingCharacters(in: .whitespaces)
                    let target = rest.hasPrefix("\"") ? String(rest.dropFirst().prefix { $0 != "\"" })
                                                      : String(rest.prefix { $0 != " " })
                    if !target.hasPrefix("|") { l.apacheAccessLog = absolute(target, root: apacheRoot) }
                }
            }
        }
        let r = Shell.run("\(Paths.brew)/bin/my_print_defaults", ["mysqld", "server", "mariadb"])
        for line in r.out.split(separator: "\n").map(String.init) {
            if line.hasPrefix("--datadir=") { l.mysqlData = String(line.dropFirst(10)) }
            if line.hasPrefix("--log-error=") || line.hasPrefix("--log_error=") { l.mysqlErrorLog = String(line.dropFirst(12)) }
        }
        while l.mysqlData.count > 1 && l.mysqlData.hasSuffix("/") { l.mysqlData.removeLast() }
        // Homebrew starts MariaDB with --datadir=/opt/homebrew/var/mysql; after the move that is a link to ~/Lampion/databases.
        l.mysqlData = URL(fileURLWithPath: l.mysqlData).resolvingSymlinksInPath().path
        if let e = l.mysqlErrorLog, !e.hasPrefix("/") { l.mysqlErrorLog = l.mysqlData + "/" + e }
        return l
    }

}
