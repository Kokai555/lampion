import SwiftUI
import AppKit

/// The first pane: a card for each server.
struct OverviewView: View {
    @EnvironmentObject var panel: Panel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var runningCount: Int { Module.allCases.filter { panel.status[$0]?.running == true }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                VStack(spacing: 14) {
                    HStack(alignment: .top, spacing: 14) {
                        ServerCard(module: .apache)
                        ServerCard(module: .mysql)
                    }
                    PHPCard()
                }
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Local Server").font(.largeTitle.weight(.bold))
                Text(summary).font(.title3).foregroundStyle(.secondary)
            }
            Spacer()
            if runningCount < Module.allCases.count {
                Button { panel.startAll() } label: { Label("Start All", systemImage: "play.fill").padding(.horizontal, 4) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!panel.busy.isEmpty || panel.setupState != .ready)
            }
            if runningCount > 0 {
                Button { panel.stopAll() } label: { Label("Stop All", systemImage: "stop.fill").padding(.horizontal, 4) }
                    .controlSize(.large)
                    .disabled(!panel.busy.isEmpty)
            }
        }
        // Start All / Stop All come and go and the summary changes with the servers; only this header animates.
        .animation(Motion.standard(reduceMotion), value: runningCount)
        .animation(Motion.fade, value: panel.busy.isEmpty)
    }

    private var summary: String {
        if !panel.busy.isEmpty { return "Working…" }
        switch runningCount {
        case Module.allCases.count: return "Everything is running at localhost:\(panel.apachePort)"
        case 0: return "All servers are stopped"
        default: return "\(runningCount) of \(Module.allCases.count) servers running"
        }
    }
}

/// Apache or MariaDB: state, port and PID, start/stop and the related actions.
struct ServerCard: View {
    @EnvironmentObject var panel: Panel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let module: Module

    var body: some View {
        let s = panel.status[module] ?? ModuleStatus()
        let state = panel.state(module)
        Card {
            HStack(alignment: .top, spacing: 12) {
                IconTile(symbol: module.symbol, tint: module.tint, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(module == .apache ? "Apache" : "MariaDB").font(.headline)
                    Text(module == .apache ? "Web server" : "Database server")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(state: state)
            }

            HStack(spacing: 22) {
                Fact(label: "Port", value: s.running ? panel.portText(s) : String(panel.configuredPort(module)))
                Fact(label: "PID", value: s.pids.first.map(String.init) ?? "–")
                Fact(label: "Version", value: panel.versions[module] ?? "–")
            }
            .padding(.top, 16)

            HStack(spacing: 8) {
                if state == .running || (state == .busy && s.running) {
                    Button { panel.toggle(module) } label: { Label("Stop", systemImage: "stop.fill").frame(minWidth: 56) }
                        .disabled(state == .busy)
                    Button { panel.restart(module) } label: { Image(systemName: "arrow.clockwise") }
                        .help("Restart \(module == .apache ? "Apache" : "MariaDB")")
                        .disabled(state == .busy)
                } else {
                    Button { panel.toggle(module) } label: { Label("Start", systemImage: "play.fill").frame(minWidth: 56) }
                        .buttonStyle(.borderedProminent).tint(module.tint)
                        .disabled(state != .stopped)
                }
                Spacer()
                Button(module == .apache ? "Open Site" : "phpMyAdmin") { panel.admin(module) }
                    .disabled(panel.status[.apache]?.running != true)
                Menu {
                    Button("Settings…") { panel.pane = module == .apache ? .apache : .mariadb }
                    Button(module == .apache ? "Error Log" : "Server Log") { panel.show(module == .apache ? .apacheError : .mariadb) }
                    if module == .apache { Button("Request Log") { panel.show(.apacheAccess) } }
                    Divider()
                    if module == .apache {
                        Button("Edit httpd.conf") { panel.openFile(Paths.httpdConf, module: "Apache") }
                        Button("Edit httpd-vhosts.conf") { panel.openFile(Paths.vhostsConf, module: "Apache") }
                    } else {
                        Button("Edit my.cnf") { panel.openFile(Paths.myCnf, module: "MySQL") }
                        Button("Edit phpMyAdmin config") { panel.openFile(Paths.pmaConf, module: "MySQL") }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("More")
            }
            .padding(.top, 16)
        }
        // Start ⇄ Stop and the facts change together with the status pill, in one short animation.
        .animation(Motion.standard(reduceMotion), value: state)
    }
}

/// PHP has no process of its own: it shows the version, whether Apache loads it and the key limits.
struct PHPCard: View {
    @EnvironmentObject var panel: Panel
    @State private var settings: PHPSettings?

    var body: some View {
        Card {
            HStack(alignment: .center, spacing: 12) {
                IconTile(symbol: Pane.php.symbol, tint: Tint.php, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("PHP").font(.headline)
                        HStack(spacing: 4) {
                            Image(systemName: panel.phpLinked ? "link" : "link.badge.plus")
                            Text(panel.phpLinked ? "Linked" : "Not linked")
                        }
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill((panel.phpLinked ? Tint.php : Color.orange).opacity(0.14)))
                        .foregroundStyle(panel.phpLinked ? Tint.php : .orange)
                    }
                    Text("Runs inside Apache").font(.caption).foregroundStyle(.secondary)
                }
                .fixedSize()
                Spacer(minLength: 12)
                HStack(spacing: 20) {
                    Fact(label: "Version", value: panel.phpVersion)
                    Fact(label: "Memory", value: settings?.memoryLimit ?? "–")
                    Fact(label: "Upload", value: settings?.uploadMaxFilesize ?? "–")
                }
                .fixedSize()
                Spacer(minLength: 12)
                Button { panel.show(settings?.separateErrorLog == true ? .php : .apacheError) } label: {
                    Image(systemName: "text.alignleft")
                }
                .help("PHP error log")
                Button { panel.pane = .php } label: { Label("Settings", systemImage: "slider.horizontal.3") }
                    .fixedSize()
            }
        }
        .onAppear(perform: load)
        .onChange(of: panel.phpVersion) { load() }
    }

    private func load() {
        DispatchQueue.global(qos: .utility).async {
            let s = PHPConfig.iniPathCached.flatMap { try? PHPConfig.load(from: $0) }
            DispatchQueue.main.async { settings = s }
        }
    }
}
