import SwiftUI
import AppKit

enum Module: String, CaseIterable, Identifiable {
    case apache, mysql
    var id: String { rawValue }
    var title: String { self == .apache ? "Apache" : "MySQL" }
    var formula: String { self == .apache ? "httpd" : "mariadb" }
    var label: String { "sh.brew.\(formula)" }
    var binary: String { self == .apache ? Paths.httpd : Paths.mariadbd }
    var symbol: String { self == .apache ? "globe" : "cylinder.split.1x2" }
}

/// The sections of the main window.
enum Pane: String, Hashable, CaseIterable, Identifiable {
    case overview, logs, apache, php, mariadb, general
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "Overview"
        case .logs: return "Logs"
        case .apache: return "Apache"
        case .php: return "PHP"
        case .mariadb: return "MariaDB"
        case .general: return "General"
        }
    }
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .logs: return "text.alignleft"
        case .apache: return "globe"
        case .php: return "chevron.left.forwardslash.chevron.right"
        case .mariadb: return "cylinder.split.1x2"
        case .general: return "gearshape"
        }
    }
}

/// App preferences (General settings).
enum Prefs {
    static let startServersOnLaunch = "startServersOnLaunch"
    static let stopServersOnQuit = "stopServersOnQuit"
    static let checkForUpdates = "checkForUpdates"
    /// Set once phpMyAdmin's automatic sign-in was turned on by default, or the user chose either way.
    static let phpMyAdminSignInChosen = "phpMyAdminSignInChosen"
    /// Set once root got an empty password by default, or the user chose either way.
    static let rootWithoutPasswordChosen = "rootWithoutPasswordChosen"
}

struct ModuleStatus: Equatable {
    var installed = true
    var loaded = false      // regisztrálva van a launchd-ben
    var running = false
    var pids: [Int] = []
    var ports: [Int] = []
}

struct LogEntry: Identifiable {
    enum Level: Int, Comparable { case info, ok, warn, error
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }
    let id = UUID()
    let time = Date()
    let module: String
    let text: String
    let level: Level
}
