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
    static let apacheErrorLog = "\(brew)/var/log/httpd/error_log"
    static let apacheAccessLog = "\(brew)/var/log/httpd/access_log"
    static let myCnf = "\(brew)/etc/my.cnf"
    static let mysqlData = "\(brew)/var/mysql"
    static let pmaConf = "\(brew)/etc/phpmyadmin.config.inc.php"
    static let htdocs = "\(brew)/var/www"

    /// A MariaDB hibanaplója: <hostname>.err a data mappában.
    static var mysqlErrorLog: String? {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: mysqlData)) ?? []
        return files.first { $0.hasSuffix(".err") }.map { "\(mysqlData)/\($0)" }
    }
}
