import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count { Snapshot.run(into: args[i + 1]) }
        // Same as General › Locations › Move… (for testing from Terminal).
        if args.contains("--move-to-lampion-folder") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Panel.shared?.moveToLampionHome() }
        }
        if let i = args.firstIndex(of: "--switch-demo"), i + 3 < args.count {
            Snapshot.runSwitchDemo(tab: args[i + 1], first: args[i + 2], second: args[i + 3])
        }
        if let i = args.firstIndex(of: "--tour-main"), i + 1 < args.count { Tour.runMain(into: args[i + 1]) }
        if let i = args.firstIndex(of: "--tour-db"), i + 1 < args.count {
            let folder = args[i + 1], db = i + 2 < args.count ? args[i + 2] : "lampion_demo"
            // The database window opens a moment after launch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Tour.runDB(into: folder, database: db) }
        }
        if let i = args.firstIndex(of: "--sidebar-demo"), i + 3 < args.count {
            Snapshot.runSidebarDemo(into: args[i + 1], database: args[i + 2], table: args[i + 3])
        }
        if let i = args.firstIndex(of: "--snapshot-db"), i + 1 < args.count {
            let db = i + 2 < args.count ? args[i + 2] : "lampion_demo"
            let table = i + 3 < args.count ? args[i + 3] : "customers"
            Snapshot.runDB(into: args[i + 1], database: db, table: table)
        }
    }

    private var stopped = false

    /// General → Stop servers when Lampion quits. Not while an update relaunches the app.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Never quit half-way through moving the databases.
        if Panel.shared?.movingHome == true {
            Panel.shared?.add("Panel", "Lampion quits after the move to ~/Lampion has finished.", .warn)
            return .terminateCancel
        }
        guard !stopped, UserDefaults.standard.bool(forKey: Prefs.stopServersOnQuit), !Updater.isRelaunching,
              let panel = Panel.shared else { return .terminateNow }
        panel.stopAllBeforeQuit {
            self.stopped = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct LampionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var panel = Panel()
    @StateObject private var database = DBModel()
    @StateObject private var updater = Updater()

    var body: some Scene {
        Window("Lampion", id: "main") {
            ContentView().environmentObject(panel).environmentObject(updater)
        }
        .defaultSize(width: 1080, height: 720)
        .windowResizability(.contentMinSize)
        .commands { AppCommands(panel: panel, db: database, updater: updater) }

        Window("Database Manager", id: "db") {
            DatabaseWindow().environmentObject(database)
        }
        .defaultSize(width: 1120, height: 720)
    }
}
