import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var panel: Panel
    @EnvironmentObject var updater: Updater
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Prefs.checkForUpdates) private var checkForUpdates = true

    /// Notices fade in and settle from just above; the content below moves down with them.
    /// (A full slide from the top edge would pass over the toolbar.) With Reduce Motion they only fade.
    private var noticeTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
    }

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            VStack(spacing: 0) {
                if updater.state != .idle {
                    UpdateCard().transition(noticeTransition)
                }
                if panel.setupState != .ready {
                    SetupBanner().transition(noticeTransition)
                }
                // A quick crossfade between panes. Only this subtree is animated, and only when the pane changes.
                ZStack {
                    detail
                        .id(panel.pane)
                        .transition(.opacity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(Motion.fade, value: panel.pane)
            }
            .animation(Motion.standard(reduceMotion), value: updater.state != .idle)
            .animation(Motion.standard(reduceMotion), value: panel.setupState != .ready)
            .navigationTitle(panel.pane.title)
        }
        .frame(minWidth: 900, minHeight: 580)
        .toolbar {
            ToolbarItem {
                Button { openWindow(id: "db") } label: { Label("Database Manager", systemImage: "cylinder.split.1x2") }
                    .help("Open the built-in database manager (⌘D)")
            }
            ToolbarItem {
                Button { panel.openHtdocs() } label: { Label("Web Folder", systemImage: "folder") }
                    .help("Open the web folder in Finder (\(panel.documentRoot))")
            }
            ToolbarItem {
                Button { panel.openTerminal() } label: { Label("Terminal", systemImage: "terminal") }
                    .help("Open Terminal in the web folder")
            }
            ToolbarItem {
                Button { panel.admin(.apache) } label: { Label("Open Website", systemImage: "globe") }
                    .help("Open http://localhost:\(panel.apachePort)/ in the browser")
                    .disabled(panel.status[.apache]?.running != true)
            }
        }
        .onAppear {
            let args = CommandLine.arguments
            // Look for a newer release once per launch (not while a self-test is running).
            if let i = args.firstIndex(of: "--preview-update"), i + 1 < args.count {
                updater.preview(args[i + 1])
            } else if args.contains("--auto-update") {
                updater.check(userInitiated: false) { if case .available(let r) = updater.state { updater.install(r) } }
            } else if checkForUpdates && !args.contains("--selftest") && !args.contains("--dbtest") && !args.contains("--snapshot") {
                updater.check(userInitiated: false)
            }
            if args.contains("--db") || args.contains("--dbtest") { openWindow(id: "db") }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch panel.pane {
        case .overview: OverviewView()
        case .logs: LogsView()
        case .apache: ApacheSettingsView()
        case .php: PHPSettingsView()
        case .mariadb: MariaDBSettingsView()
        case .general: GeneralSettingsView()
        }
    }
}

private struct Sidebar: View {
    @EnvironmentObject var panel: Panel

    var body: some View {
        List(selection: Binding(get: { panel.pane }, set: { if let p = $0 { panel.pane = p } })) {
            Section {
                row(.overview)
                row(.logs, badge: errorCount)
            }
            Section("Configuration") {
                row(.apache, server: .apache)
                row(.php)
                row(.mariadb, server: .mysql)
                row(.general)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { footer }
    }

    /// Errors in Lampion's activity log since it opened.
    private var errorCount: Int { panel.log.filter { $0.level == .error }.count }

    private func row(_ pane: Pane, server: Module? = nil, badge: Int = 0) -> some View {
        HStack {
            Label {
                Text(pane.title)
            } icon: {
                IconTile(symbol: pane.icon, tint: pane.tint, size: 20, glyphScale: 0.56)
            }
            Spacer()
            if panel.unsaved.contains(pane) {
                Image(systemName: "pencil.circle.fill").foregroundStyle(.orange)
                    .help("Unsaved changes")
                    .accessibilityLabel("Unsaved changes")
            }
            if let server {
                let state = panel.state(server)
                StatusDot(state: state)
                    .help("\(server == .apache ? "Apache" : "MariaDB"): \(state.title)")
                    .accessibilityLabel(state.title)
            }
        }
        .badge(badge)
        .tag(pane)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            ForEach(Module.allCases) { m in
                let state = panel.state(m)
                HStack(spacing: 8) {
                    StatusDot(state: state)
                    Text(m == .apache ? "Apache" : "MariaDB").font(.caption)
                    Spacer()
                    Text(state == .running ? ":\(panel.portText(panel.status[m] ?? ModuleStatus()))" : state.title)
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 12)
    }
}
