import SwiftUI
import AppKit

/// Minden parancs elérhető a menüsorból is.
struct AppCommands: Commands {
    @ObservedObject var panel: Panel
    @ObservedObject var db: DBModel
    @ObservedObject var updater: Updater
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.check(userInitiated: true) }
                .disabled(updater.state == .checking)
                .keyboardShortcut("u", modifiers: .command)
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { showMain(.general) }.keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(before: .sidebar) {
            ForEach(Array(Pane.allCases.enumerated()), id: \.element) { i, pane in
                Button(pane.title) { showMain(pane) }
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
            }
            Divider()
        }

        CommandMenu("Server") {
            Button("Start All") { panel.startAll() }.keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Stop All") { panel.stopAll() }.keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
            ForEach(Module.allCases) { m in
                Button("\(panel.status[m]?.running == true ? "Stop" : "Start") \(m.title)") { panel.toggle(m) }
                    .disabled(panel.busy.contains(m))
            }
            Menu("Restart") {
                ForEach(Module.allCases) { m in
                    Button(m.title) { panel.restart(m) }.disabled(panel.status[m]?.running != true || panel.busy.contains(m))
                }
            }
            Divider()
            Button("Open Website") { panel.admin(.apache) }
            Button("Open phpMyAdmin") { panel.admin(.mysql) }
            Button("Open Web Folder") { panel.openHtdocs() }.keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Open Terminal") { panel.openTerminal() }
            Divider()
            Menu("Config Files") {
                Button("httpd.conf") { panel.openFile(Paths.httpdConf, module: "Apache") }
                Button("httpd-vhosts.conf") { panel.openFile(Paths.vhostsConf, module: "Apache") }
                Button("php.ini") { panel.openFile(panel.phpIni, module: "PHP") }
                Button("my.cnf") { panel.openFile(Paths.myCnf, module: "MySQL") }
                Button("phpMyAdmin (config.inc.php)") { panel.openFile(Paths.pmaConf, module: "MySQL") }
            }
            Menu("Logs") {
                ForEach(LogSource.allCases) { source in
                    Button(source.title) { showMain(.logs); panel.logSource = source }
                }
            }
        }

        CommandMenu("Database") {
            Button("Open Database Manager") { openWindow(id: "db") }.keyboardShortcut("d", modifiers: .command)
            Divider()
            Button("Refresh") { db.reloadAll() }.keyboardShortcut("r", modifiers: [.command, .shift])
            Button("New Database…") { openWindow(id: "db"); db.sheet = .newDatabase }
            Button("New Table…") { openWindow(id: "db"); db.sheet = .newTable }.disabled(db.currentDB == nil)
            Divider()
            Button("Export…") { if let d = db.currentDB { db.export(db: d, table: db.currentTable) } }
                .keyboardShortcut("e", modifiers: .command).disabled(db.currentDB == nil)
            Button("Import…") { db.importSQL(into: db.currentDB) }
            Divider()
            Button("Run Query") { db.tab = .query; db.runQuery() }
                .keyboardShortcut("r", modifiers: .command).disabled(db.queryText.trimmed.isEmpty)
        }
    }

    /// Brings the main window forward on the given pane.
    private func showMain(_ pane: Pane) {
        panel.pane = pane
        openWindow(id: "main")
    }
}
