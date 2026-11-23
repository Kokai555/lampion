import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
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
        .defaultSize(width: 860, height: 560)
        .windowResizability(.contentMinSize)
        .commands { AppCommands(panel: panel, db: database, updater: updater) }

        Window("Database Manager", id: "db") {
            DatabaseWindow().environmentObject(database)
        }
        .defaultSize(width: 1120, height: 720)
    }
}
