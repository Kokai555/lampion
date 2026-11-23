import SwiftUI
import AppKit

/// Development aid: screenshots of every screen, for documentation and design review.
///
/// `Lampion --tour-main <folder>`: every pane of the main window, every log, and the settings pages with invalid values.
/// `Lampion --db --tour-db <folder> [database]`: every view of the database manager on a demo database,
/// its sheets, confirmations and error states.
///
/// Nothing is saved: invalid settings stay unsaved drafts, and confirmations are dismissed, never accepted.
enum Tour {
    struct Step {
        let name: String
        var wait: Double = 1.6
        /// Capture the screen area of the window, so attached sheets and alerts are included.
        var withSheets = false
        /// Scroll through a page longer than the window and capture each further screenful.
        var pages = false
        let apply: () -> Void
    }

    // MARK: Main window

    static func runMain(into folder: String) {
        let p = { Panel.shared }
        var steps: [Step] = [Step(name: "overview") { p()?.pane = .overview }]
        for source in LogSource.allCases {
            steps.append(Step(name: "logs-\(source.rawValue)") { p()?.logSource = source; p()?.pane = .logs })
        }
        for pane in [Pane.apache, .php, .mariadb, .general] {
            steps.append(Step(name: "settings-\(pane.rawValue)", pages: true) { p()?.pane = pane })
        }
        // Invalid values, kept as unsaved drafts, so each page shows its problems and the save bar.
        steps.append(Step(name: "errors-apache") {
            guard let panel = p(), let saved = try? ApacheConfig.load() else { return }
            var bad = saved
            bad.port = 80
            bad.documentRoot = NSHomeDirectory() + "/Sites/nincs-ilyen-mappa"
            panel.keepDraft(.apache, saved: saved, draft: bad)
            panel.pane = .apache
        })
        steps.append(Step(name: "errors-php") {
            guard let panel = p(), let path = PHPConfig.iniPath(), let saved = try? PHPConfig.load(from: path) else { return }
            var bad = saved
            bad.memoryLimit = "sok"
            bad.uploadMaxFilesize = "64M"
            bad.postMaxSize = "8M"
            bad.timezone = "Europe/Atlantisz"
            panel.keepDraft(.php, saved: saved, draft: bad)
            panel.pane = .php
        })
        steps.append(Step(name: "errors-mariadb") {
            guard let panel = p() else { return }
            let saved = MariaDBConfig.load()
            var bad = saved
            bad.port = "99999"
            bad.bufferPoolSize = "nagyon sok"
            bad.longQueryTime = "-1"
            panel.keepDraft(.mariadb, saved: saved, draft: bad)
            panel.pane = .mariadb
        })
        steps.append(Step(name: "overview-unsaved-badges") { p()?.pane = .overview })

        run(steps, into: folder, window: { NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.contains("main") == true } }) {
            NSApp.terminate(nil)
        }
    }

    // MARK: Database manager

    static func runDB(into folder: String, database db: String) {
        guard let m0 = DBModel.shared else { return }
        let m = { DBModel.shared ?? m0 }
        let queryOpenKey = "db.queryResultsOpen"
        let queryWasOpen = UserDefaults.standard.object(forKey: queryOpenKey) as? Bool ?? true
        let steps: [Step] = [
            Step(name: "start") { m().selection = nil },
            Step(name: "database-tables") {
                m().expanded.insert(db); m().loadTables(db); m().selection = .database(db); m().tab = .tables
            },
            Step(name: "database-designer", wait: 3) { m().tab = .designer },
            Step(name: "table-data") { m().selection = .table(db, "customers") },
            Step(name: "table-data-row-inspector") { m().tab = .data; m().selectedRows = IndexSet(integer: 2); m().showInspector = true },
            Step(name: "table-data-filter") {
                m().showInspector = false; m().selectedRows = []
                m().filter = "city = 'Budapest'"; m().offset = 0; m().loadData()
            },
            Step(name: "error-table-data-bad-filter") { m().filter = "city = = 'Budapest'"; m().offset = 0; m().loadData() },
            Step(name: "table-data-console-open") {
                m().filter = ""; m().loadData(); m().consoleExpanded = true
            },
            Step(name: "table-products-data") { m().consoleExpanded = false; m().selection = .table(db, "products") },
            Step(name: "table-orders-structure-columns") {
                m().selection = .table(db, "orders"); m().tab = .structure; m().structureSection = .columns
            },
            Step(name: "table-orders-structure-indexes") { m().structureSection = .indexes },
            Step(name: "table-orders-structure-foreign-keys") { m().structureSection = .foreignKeys },
            Step(name: "table-orders-structure-sql") { m().structureSection = .sql },
            Step(name: "table-without-primary-key") { m().selection = .table(db, "settings"); m().tab = .data },
            Step(name: "view-data") { m().selection = .table(db, "order_totals"); m().tab = .data },
            Step(name: "view-structure") { m().tab = .structure; m().structureSection = .sql },
            Step(name: "query-result") {
                m().selection = .database(db); m().tab = .query
                m().queryText = "SELECT c.name, c.city, COUNT(o.id) AS orders, SUM(o.total) AS spent\nFROM customers c\nJOIN orders o ON o.customer_id = c.id\nGROUP BY c.id\nORDER BY spent DESC;"
                m().runQuery()
            },
            Step(name: "query-several-statements") {
                m().queryText = "SELECT * FROM categories;\nSELECT name, price FROM products WHERE price > 100000;\nUPDATE products SET stock = stock WHERE id = 1;"
                m().runQuery()
            },
            Step(name: "error-query") {
                m().queryText = "SELECT name, pricee\nFROM products\nWHER active = 1;"
                m().runQuery()
            },
            Step(name: "query-results-collapsed") {
                UserDefaults.standard.set(false, forKey: queryOpenKey)
                m().queryText = "SELECT * FROM order_totals;"
                m().runQuery()
            },
            // Sheets, on the products table.
            Step(name: "sheet-new-database", withSheets: true) {
                UserDefaults.standard.set(queryWasOpen, forKey: queryOpenKey)
                m().selection = .table(db, "products"); m().tab = .structure; m().structureSection = .columns
                m().sheet = .newDatabase
            },
            Step(name: "sheet-new-table", withSheets: true) { m().sheet = nil; after(0.5) { m().sheet = .newTable } },
            Step(name: "sheet-add-column", withSheets: true) { m().sheet = nil; after(0.5) { m().sheet = .addColumn } },
            Step(name: "sheet-edit-column", withSheets: true) {
                m().sheet = nil; m().selectedColumns = IndexSet(integer: 5); after(0.5) { m().sheet = .editColumn }
            },
            Step(name: "sheet-add-index", withSheets: true) { m().sheet = nil; after(0.5) { m().sheet = .addIndex } },
            Step(name: "sheet-add-foreign-key", withSheets: true) { m().sheet = nil; after(0.5) { m().sheet = .addForeignKey } },
            Step(name: "sheet-table-options", withSheets: true) { m().sheet = nil; after(0.5) { m().sheet = .tableOptions } },
            Step(name: "sheet-insert-row", withSheets: true) {
                m().sheet = nil; m().tab = .data; after(0.5) { m().sheet = .insertRow }
            },
            Step(name: "confirm-delete-table", withSheets: true) {
                m().sheet = nil; after(0.5) { m().askToDropTable("orders", in: db, isView: false) }
            },
            Step(name: "confirm-empty-table", withSheets: true) {
                m().confirm = nil; after(0.5) { m().askToEmptyTable("reviews", in: db) }
            },
            Step(name: "confirm-delete-database", withSheets: true) {
                m().confirm = nil; after(0.5) { m().askToDropDatabase(db) }
            },
            // A real error from the server: dropping a table that isn't there.
            Step(name: "error-alert", withSheets: true) {
                m().confirm = nil
                after(0.5) { m().change("DROP TABLE `\(db)`.`nincs_ilyen_tabla`", db: db) { _ in } }
            },
            Step(name: "system-databases") {
                m().alertMessage = nil
                m().showSystemDatabases = true
                m().expanded.insert("mysql"); m().loadTables("mysql")
                m().selection = .table("mysql", "user"); m().tab = .data
            },
            Step(name: "system-database-designer", wait: 3) { m().selection = .database("mysql"); m().tab = .designer },
        ]
        run(steps, into: folder, window: { NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.contains("db") == true } }) {
            NSApp.terminate(nil)
        }
    }

    // MARK: Running

    private static func after(_ seconds: Double, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private static func run(_ steps: [Step], into folder: String, window: @escaping () -> NSWindow?, done: @escaping () -> Void) {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        func step(_ i: Int) {
            guard i < steps.count else { after(0.3, done); return }
            let s = steps[i]
            s.apply()
            after(s.wait + (s.withSheets ? 0.6 : 0)) {
                let name = String(format: "%02d-%@", i + 1, s.name)
                guard let w = window() else { step(i + 1); return }
                if s.withSheets { captureArea(of: w, to: "\(folder)/\(name).png") } else { capture(w, to: "\(folder)/\(name).png") }
                if s.pages { shootPages(of: w, folder: folder, name: name) { step(i + 1) } } else { step(i + 1) }
            }
        }
        after(3) {
            NSApp.activate(ignoringOtherApps: true)
            if let w = window(), let screen = w.screen ?? NSScreen.main {
                // As tall as the screen allows, so the long settings pages show as much as possible.
                let area = screen.visibleFrame
                w.setFrame(NSRect(x: area.minX + 20, y: area.minY, width: min(max(w.frame.width, 1280), area.width - 40), height: area.height), display: true)
                w.makeKeyAndOrderFront(nil)
            }
            step(0)
        }
    }

    private static func capture(_ w: NSWindow, to path: String) {
        Shell.run("/usr/sbin/screencapture", ["-x", "-o", "-l", String(w.windowNumber), path])
    }

    /// The window's rectangle on screen, with whatever sheet or alert hangs on it.
    private static func captureArea(of w: NSWindow, to path: String) {
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let f = w.frame
        let rect = "\(Int(f.minX)),\(Int(screenHeight - f.maxY)),\(Int(f.width)),\(Int(f.height))"
        Shell.run("/usr/sbin/screencapture", ["-x", "-R", rect, path])
    }
}

extension Tour {
    /// Every scroll view in the window, for finding the page's own.
    static func scrollViews(in w: NSWindow) -> [NSScrollView] {
        var found: [NSScrollView] = []
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView { found.append(s) }
            v.subviews.forEach(walk)
        }
        if let root = w.contentView?.superview ?? w.contentView { walk(root) }
        return found
    }

    /// The page's scroll view: the widest one with more content than fits (the sidebar's list is narrow).
    static func pageScrollView(in w: NSWindow) -> NSScrollView? {
        scrollViews(in: w)
            .filter { $0.frame.width > 600 && ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height + 20 }
            .max { $0.frame.width < $1.frame.width }
    }

    static func shootPages(of w: NSWindow, folder: String, name: String, done: @escaping () -> Void) {
        guard let scroll = pageScrollView(in: w), let doc = scroll.documentView else { done(); return }
        let clip = scroll.contentView
        let top = clip.bounds.minY                        // negative: the toolbar's inset
        let end = doc.frame.height - clip.bounds.height   // last scroll position
        let stride = clip.bounds.height - 140
        var positions: [CGFloat] = []
        var y = top + stride
        while y < end { positions.append(y); y += stride }
        positions.append(end)
        func page(_ n: Int) {
            guard n < positions.count else {
                clip.scroll(to: NSPoint(x: 0, y: top)); scroll.reflectScrolledClipView(clip)
                after(0.4, done); return
            }
            clip.scroll(to: NSPoint(x: 0, y: positions[n])); scroll.reflectScrolledClipView(clip)
            after(0.8) {
                capture(w, to: "\(folder)/\(name)-\(n + 2).png")
                page(n + 1)
            }
        }
        page(0)
    }
}
