import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var panel: Panel
    @EnvironmentObject var updater: Updater
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Notices slide in from the top; with Reduce Motion on they simply appear.
    private var noticeTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
    }
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            if updater.state != .idle {
                UpdateCard().transition(noticeTransition)
            }
            if panel.setupState != .ready {
                SetupBanner().transition(noticeTransition)
            }
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
        .animation(reduceMotion ? nil : .spring(duration: 0.35), value: updater.state != .idle)
        .animation(reduceMotion ? nil : .spring(duration: 0.35), value: panel.setupState != .ready)
        .onAppear {
            let args = CommandLine.arguments
            // Look for a newer release once per launch (not while a self-test is running).
            if let i = args.firstIndex(of: "--preview-update"), i + 1 < args.count {
                updater.preview(args[i + 1])
            } else if args.contains("--auto-update") {
                updater.check(userInitiated: false) { if case .available(let r) = updater.state { updater.install(r) } }
            } else if !args.contains("--selftest") && !args.contains("--dbtest") {
                updater.check(userInitiated: false)
            }
            if args.contains("--db") || args.contains("--dbtest") { openWindow(id: "db") }
        }
    }
}
