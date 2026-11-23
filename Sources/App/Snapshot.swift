import SwiftUI
import AppKit

/// Development aid: `Lampion.app/Contents/MacOS/Lampion --snapshot <folder>` saves a PNG of every pane of the main window, then quits.
/// It draws the window into an image itself, so it needs no screen recording permission.
enum Snapshot {
    static func run(into folder: String) {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        // Every pane, and the Logs pane once per log source.
        let shots: [(pane: Pane, log: LogSource?)] = Pane.allCases.flatMap { pane in
            pane == .logs ? LogSource.allCases.map { (pane, Optional($0)) } : [(pane, nil)]
        }
        func shoot(_ i: Int) {
            guard i < shots.count else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
                return
            }
            if let log = shots[i].log { Panel.shared?.logSource = log }
            Panel.shared?.pane = shots[i].pane
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let name = String(format: "%02d-%@%@.png", i + 1, shots[i].pane.rawValue, shots[i].log.map { "-" + $0.rawValue } ?? "")
                let file = URL(fileURLWithPath: folder).appendingPathComponent(name)
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.title != "Database Manager" && $0.contentView != nil }) {
                    // A real screenshot shows the translucent sidebar; it needs screen recording permission
                    // (granted to the terminal when the binary is started from it). Otherwise draw the view.
                    let shot = Shell.run("/usr/sbin/screencapture", ["-x", "-o", "-l", String(window.windowNumber), file.path])
                    if shot.status != 0 || !FileManager.default.fileExists(atPath: file.path),
                       let view = window.contentView?.superview ?? window.contentView,
                       let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: file)
                    }
                }
                shoot(i + 1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { shoot(0) }
    }

    /// `--db --snapshot-db <folder> [database table]`: the database manager on the given table, one PNG per view.
    static func runDB(into folder: String, database: String, table: String) {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        typealias Step = (name: String, apply: (DBModel) -> Void)
        let steps: [Step] = [
            ("1-database", { $0.expanded.insert(database); $0.loadTables(database); $0.selection = .database(database) }),
            ("2-database-tables", { $0.tab = .tables }),
            ("2b-designer", { $0.tab = .designer }),
            ("3-table-data", { $0.selection = .table(database, table) }),
            ("4-table-data", { $0.tab = .data }),
            ("5-structure-columns", { $0.tab = .structure; $0.structureSection = .columns }),
            ("6-structure-indexes", { $0.structureSection = .indexes }),
            ("7-structure-fk", { $0.structureSection = .foreignKeys }),
            ("8-structure-sql", { $0.structureSection = .sql }),
            ("4b-data-inspector", { m in m.tab = .data; m.selectedRows = IndexSet(integer: 1); m.showInspector = true }),
            ("4c-console-open", { m in m.showInspector = false; m.consoleExpanded = true }),
            ("4d-done", { m in m.consoleExpanded = false }),
            ("9-query", { m in
                m.tab = .query
                m.queryText = "SELECT c.name, c.city, COUNT(o.id) AS orders, SUM(o.total) AS spent\nFROM customers c\nJOIN orders o ON o.customer_id = c.id\nGROUP BY c.id\nORDER BY spent DESC;"
                m.runQuery()
            }),
        ]
        func shoot(_ i: Int) {
            guard i < steps.count else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
                return
            }
            if let m = DBModel.shared { steps[i].apply(m) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                let file = URL(fileURLWithPath: folder).appendingPathComponent(steps[i].name + ".png")
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue.contains("db") == true })
                    ?? NSApp.windows.first(where: { $0.isVisible && $0.frame.width >= 960 && $0.title != "Lampion" }) {
                    Shell.run("/usr/sbin/screencapture", ["-x", "-o", "-l", String(window.windowNumber), file.path])
                }
                shoot(i + 1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { shoot(0) }
    }

    /// `--db --sidebar-demo <folder> <database> <table>`: opens a table of a collapsed database from the
    /// detail pane (as a click in the table list does) and saves the window before and after.
    static func runSidebarDemo(into folder: String, database: String, table: String) {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        func shot(_ name: String) {
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue.contains("db") == true }) {
                Shell.run("/usr/sbin/screencapture", ["-x", "-o", "-l", String(window.windowNumber), folder + "/" + name + ".png"])
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            NSApp.activate(ignoringOtherApps: true)
            guard let m = DBModel.shared else { return }
            m.showSystemDatabases = true
            m.expanded.remove(database)
            m.selection = .database(database)
            m.tab = .tables
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                shot("1-before")
                m.selection = .table(database, table)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { shot("2-during") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    shot("3-after")
                    // A real click on the disclosure arrow comes from outside (see the test script) in the next 3 s.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        shot("5-collapsed")
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }

    /// `--db --switch-demo <tab> <db1> <db2>`: selects the two databases in turn every 1.5 s on the given tab
    /// (designer or query), for recording how the switch looks. Quits after 8 switches.
    static func runSwitchDemo(tab: String, first: String, second: String) {
        func step(_ i: Int) {
            guard i < 8, let m = DBModel.shared else { NSApp.terminate(nil); return }
            m.selection = .database(i % 2 == 0 ? first : second)
            DispatchQueue.main.async { m.tab = tab == "query" ? .query : .designer }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { step(i + 1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            NSApp.activate(ignoringOtherApps: true)   // be in front so a screen recording sees the window
            DBModel.shared?.tab = tab == "query" ? .query : .designer
            step(0)
        }
    }
}
