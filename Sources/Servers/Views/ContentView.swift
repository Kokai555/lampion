import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var panel: Panel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            ModuleTable()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.vertical, 16)
            Divider()
            LogPane()
        }
        .frame(minWidth: 840, minHeight: 420)
        .toolbar {
            ToolbarItem {
                Button { openWindow(id: "db") } label: { Label("Database Manager", systemImage: "cylinder.split.1x2") }
                    .labelStyle(.titleAndIcon)
                    .help("Open the built-in database manager (⌘D)")
            }
            ToolbarItemGroup {
                Button { panel.openHtdocs() } label: { Label("Web Folder", systemImage: "folder") }
                    .help("Open the web folder in Finder (\(Paths.htdocs))")
                Button { panel.openTerminal() } label: { Label("Terminal", systemImage: "terminal") }
                    .help("Open Terminal in the web folder")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { panel.startAll() } label: { Label("Start All", systemImage: "play.fill") }
                    .help("Start every stopped server")
                Button { panel.stopAll() } label: { Label("Stop All", systemImage: "stop.fill") }
                    .help("Stop every running server")
            }
        }
        .onAppear {
            let args = CommandLine.arguments
            if args.contains("--db") || args.contains("--dbtest") { openWindow(id: "db") }
        }
    }
}
