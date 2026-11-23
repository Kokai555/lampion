import SwiftUI
import AppKit

struct ModuleTable: View {
    @EnvironmentObject var panel: Panel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                Text("Module"); Text("PID"); Text("Port")
                Text("Actions").gridCellColumns(4)
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)

            Divider().gridCellUnsizedAxes(.horizontal)

            ForEach(Module.allCases) { m in row(m) }

            GridRow {
                StatusBadge(title: "PHP", on: panel.phpLinked, onText: "Linked", offText: "Not linked")
                Text("–").foregroundStyle(.secondary)
                Text("–").foregroundStyle(.secondary)
                Text("\(panel.phpVersion) · runs through Apache")
                    .font(.callout).foregroundStyle(.secondary).gridCellColumns(2)
                Button("Config") { panel.openFile(panel.phpIni, module: "PHP") }
                    .help("Open php.ini")
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            }
        }
    }

    @ViewBuilder
    private func row(_ m: Module) -> some View {
        let s = panel.status[m] ?? ModuleStatus()
        GridRow {
            StatusBadge(title: m.title, on: s.running)
            Text(s.pids.first.map(String.init) ?? "–")
                .monospacedDigit().frame(width: 60, alignment: .leading)
                .help(s.pids.map(String.init).joined(separator: ", "))
            Text(panel.portText(s)).monospacedDigit().frame(width: 70, alignment: .leading)

            Group {
                if panel.busy.contains(m) {
                    ProgressView().controlSize(.small).frame(width: 88)
                } else if s.running {
                    Button { panel.toggle(m) } label: { Text("Stop").frame(width: 68) }
                } else {
                    Button { panel.toggle(m) } label: { Text("Start").frame(width: 68) }
                        .buttonStyle(.borderedProminent).disabled(!s.installed)
                }
            }

            Button { panel.admin(m) } label: { Text(m == .apache ? "Website" : "phpMyAdmin").frame(width: 82) }
                .help(m == .apache ? "Open the local website in the browser" : "Open phpMyAdmin in the browser")

            Menu("Config") {
                if m == .apache {
                    Button("httpd.conf") { panel.openFile(Paths.httpdConf, module: m.title) }
                    Button("httpd-vhosts.conf") { panel.openFile(Paths.vhostsConf, module: m.title) }
                    Button("php.ini") { panel.openFile(panel.phpIni, module: m.title) }
                } else {
                    Button("my.cnf") { panel.openFile(Paths.myCnf, module: m.title) }
                    Button("phpMyAdmin (config.inc.php)") { panel.openFile(Paths.pmaConf, module: m.title) }
                }
            }
            .fixedSize()

            Menu("Logs") {
                if m == .apache {
                    Button("error_log") { panel.openFile(Paths.apacheErrorLog, module: m.title) }
                    Button("access_log") { panel.openFile(Paths.apacheAccessLog, module: m.title) }
                } else {
                    Button("MariaDB error log (.err)") { panel.openFile(Paths.mysqlErrorLog, module: m.title) }
                }
            }
            .fixedSize()
        }
    }
}
