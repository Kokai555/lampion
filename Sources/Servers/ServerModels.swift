import SwiftUI
import AppKit

enum Module: String, CaseIterable, Identifiable {
    case apache, mysql
    var id: String { rawValue }
    var title: String { self == .apache ? "Apache" : "MySQL" }
    var formula: String { self == .apache ? "httpd" : "mariadb" }
    var label: String { "sh.brew.\(formula)" }
    var binary: String { self == .apache ? Paths.httpd : Paths.mariadbd }
}

struct ModuleStatus: Equatable {
    var installed = true
    var loaded = false      // regisztrálva van a launchd-ben
    var running = false
    var pids: [Int] = []
    var ports: [Int] = []
}

struct LogEntry: Identifiable {
    enum Level { case info, ok, warn, error }
    let id = UUID()
    let time = Date()
    let module: String
    let text: String
    let level: Level
}
