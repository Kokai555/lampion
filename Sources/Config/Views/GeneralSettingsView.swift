import SwiftUI
import AppKit
import ServiceManagement

struct GeneralSettingsView: View {
    @EnvironmentObject var panel: Panel
    @EnvironmentObject var updater: Updater
    @AppStorage(Prefs.startServersOnLaunch) private var startOnLaunch = false
    @AppStorage(Prefs.stopServersOnQuit) private var stopOnQuit = false
    @AppStorage(Prefs.checkForUpdates) private var checkForUpdates = true
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var confirmMove = false
    @State private var loginError: String?

    private static let lampionLog = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Lampion.log").path

    var body: some View {
        Form {
            Section {
                SettingsHeader(symbol: Pane.general.icon, tint: Pane.general.tint, title: "General",
                               detail: "How Lampion itself behaves. These settings apply straight away.", file: nil)
            }

            Section("Startup") {
                Toggle(isOn: $openAtLogin) {
                    FieldLabel("Open Lampion at login", loginError ?? "Lampion opens when you log in to your Mac.")
                }
                .onChange(of: openAtLogin) { _, on in setOpenAtLogin(on) }
                Toggle(isOn: $startOnLaunch) {
                    FieldLabel("Start servers when Lampion opens", "Starts Apache and MariaDB if they are not running yet.")
                }
                Toggle(isOn: $stopOnQuit) {
                    FieldLabel("Stop servers when Lampion quits", "Off: the servers keep running in the background after you quit.")
                }
            }

            Section("Updates") {
                Toggle(isOn: $checkForUpdates) {
                    FieldLabel("Check for updates automatically", "Looks for a new release on GitHub each time Lampion opens.")
                }
                LabeledContent {
                    Button(updater.state == .checking ? "Checking…" : "Check Now") { updater.check(userInitiated: true) }
                        .disabled(updater.state == .checking)
                } label: {
                    FieldLabel("Version \(updater.currentVersion)", status)
                }
            }

            Section {
                if panel.locations.mysqlData.hasPrefix(Paths.home + "/") {
                    location("Lampion folder", Paths.home, detail: "Sites, databases, logs and backups, all in one place.")
                } else {
                    LabeledContent {
                        if panel.movingHome {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Move…") { confirmMove = true }
                        }
                    } label: {
                        FieldLabel("Keep everything in ~/Lampion",
                                   panel.movingHome ? "Moving… progress shows in Logs › Lampion Activity."
                                   : "Puts your sites, databases and logs in one folder, like XAMPP does. Copies them; nothing is deleted.")
                    }
                }
                location("Web folder", panel.documentRoot)
                location("Database files", panel.locations.mysqlData)
                location("Logs", panel.locations.mysqlData.hasPrefix(Paths.home + "/") ? Paths.homeLogs
                         : (panel.locations.apacheErrorLog as NSString).deletingLastPathComponent)
                location("Homebrew", Paths.brew)
                location("Lampion's log", Self.lampionLog)
            } header: {
                Text("Locations")
            }
            .confirmationDialog("Move everything to ~/Lampion?", isPresented: $confirmMove) {
                Button("Move") { panel.moveToLampionHome() }
            } message: {
                Text("Lampion stops Apache and MariaDB, copies your sites to ~/Lampion/www and your databases to ~/Lampion/databases, puts the logs in ~/Lampion/logs, updates the settings and starts the servers again. It checks that every database is still there. The old files stay where they are until you delete them.")
            }

            Section {
                ForEach(backups, id: \.self) { file in
                    LabeledContent {
                        Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: ConfigFile.backupPath(file))]) }
                    } label: {
                        FieldLabel((file as NSString).lastPathComponent, ConfigFile.backupPath(file))
                    }
                }
                if backups.isEmpty {
                    Text("Lampion has not changed any configuration file yet.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Backups")
            } footer: {
                Text("Before Lampion first changes a file, it saves the original next to it. Each settings page can put it back from its file menu.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var status: String {
        switch updater.state {
        case .upToDate: return "Lampion is up to date."
        case .available(let r): return "Version \(r.version) is available."
        case .failed(let m): return m
        default: return "Updates come from github.com/\(Updater.repository)."
        }
    }

    private var backups: [String] {
        [Paths.httpdConf, PHPConfig.iniPathCached, Paths.myCnf, Paths.pmaConf].compactMap { $0 }.filter(ConfigFile.hasBackup)
    }

    private func location(_ title: String, _ path: String, detail: String? = nil) -> some View {
        LabeledContent {
            Button("Show") {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                if isDir.boolValue { Shell.open([path]) } else {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
        } label: {
            FieldLabel(title, detail.map { "\($0)\n\(path)" } ?? path)
        }
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Could not change this: \(error.localizedDescription) Move Lampion to Applications first."
            openAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

