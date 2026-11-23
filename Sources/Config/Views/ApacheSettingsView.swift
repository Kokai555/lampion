import SwiftUI
import AppKit

struct ApacheSettingsView: View {
    @EnvironmentObject var panel: Panel
    @State private var saved = ApacheSettings()
    @State private var draft = ApacheSettings()
    @State private var loaded = false
    @State private var editor = SettingsEditor()

    private var problems: [String] { ApacheConfig.validate(draft) }
    private var running: Bool { panel.status[.apache]?.running == true }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    SettingsHeader(symbol: Pane.apache.icon, tint: Pane.apache.tint, title: "Apache",
                                   detail: "The web server. Changes are checked with Apache before they are saved.",
                                   file: ApacheConfig.path, onRestore: { editor.confirmRestore = true })
                }

                Section("Server") {
                    LabeledContent {
                        HStack(spacing: 10) {
                            ValueField(placeholder: "8080", text: $draft.port.text, valid: (1024...65535).contains(draft.port), width: 90)
                            Link("localhost:\(String(draft.port))", destination: URL(string: "http://localhost:\(draft.port)/")!)
                                .font(.callout)
                        }
                    } label: {
                        FieldLabel("Port", "The address of your sites is http://localhost:port. Use 1024 or higher.")
                    }

                    LabeledContent {
                        HStack(spacing: 8) {
                            Text(draft.documentRoot).font(.system(.callout, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                                .help(draft.documentRoot)
                            Button("Choose…", action: chooseFolder)
                        }
                    } label: {
                        FieldLabel("Web folder", "DocumentRoot: the files Apache serves at http://localhost:\(String(draft.port))/.")
                    }
                    if Self.isProtectedFolder(draft.documentRoot) {
                        Label("macOS may stop Apache from reading Desktop, Documents and Downloads. If pages show “Forbidden”, pick a folder elsewhere, for example in your home folder.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }

                    LabeledContent {
                        TextField("", text: $draft.serverAdmin, prompt: Text("you@example.com"))
                            .textFieldStyle(.roundedBorder).frame(width: 220).labelsHidden()
                    } label: {
                        FieldLabel("Administrator email", "Shown on Apache's error pages.")
                    }
                }

                Section("Web folder behaviour") {
                    Toggle(isOn: $draft.allowOverride) {
                        FieldLabel(".htaccess files", "Lets folders change settings with .htaccess (AllowOverride All). Most PHP frameworks need this.")
                    }
                    Toggle(isOn: $draft.directoryListing) {
                        FieldLabel("List folder contents", "Show a file list for folders without an index.php or index.html.")
                    }
                }

                Section {
                    ForEach(ApacheSettings.features) { f in
                        Toggle(isOn: Binding(get: { draft.modules[f.id] ?? false }, set: { draft.modules[f.id] = $0 })) {
                            FieldLabel(f.title, f.detail)
                        }
                    }
                } header: {
                    Text("Modules")
                } footer: {
                    Text("PHP and phpMyAdmin are always on. For anything else, edit httpd.conf directly.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Logging") {
                    Picker(selection: $draft.logLevel) {
                        ForEach(ApacheSettings.logLevels, id: \.self) { Text($0.capitalized).tag($0) }
                    } label: {
                        FieldLabel("Error log detail", "Warn is a good default. Debug writes a lot and slows Apache down.")
                    }
                    LabeledContent("Log files") {
                        HStack {
                            Button("Errors") { panel.show(.apacheError) }
                            Button("Requests") { panel.show(.apacheAccess) }
                        }
                    }
                }

                Section("More configuration") {
                    LabeledContent {
                        Button("Edit") { panel.openFile(Paths.vhostsConf, module: "Apache") }
                    } label: {
                        FieldLabel("Virtual hosts", "httpd-vhosts.conf. Include it from httpd.conf to use it.")
                    }
                    LabeledContent {
                        Button("Edit") { panel.openFile(Paths.httpdConf, module: "Apache") }
                    } label: {
                        FieldLabel("Full configuration", "httpd.conf, for settings not shown here. Reopen this page afterwards.")
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(!loaded)

            SaveBar(dirty: draft != saved, problems: problems, saving: editor.saving,
                    restartName: running ? "Apache" : nil, message: editor.message,
                    onRevert: { draft = saved }, onSave: save)
        }
        .onAppear {
            if let kept = panel.storedDraft(.apache, as: ApacheSettings.self) {
                saved = kept.saved; draft = kept.draft; loaded = true
            } else { load() }
        }
        .onChange(of: draft) { panel.keepDraft(.apache, saved: saved, draft: draft) }
        .onChange(of: saved) { panel.keepDraft(.apache, saved: saved, draft: draft) }
        .settingsAlerts($editor, file: ApacheConfig.path, module: "Apache") { load() }
    }

    private func load() {
        do {
            let s = try ApacheConfig.load()
            saved = s; draft = s; loaded = true
        } catch {
            editor.error = error.localizedDescription
        }
    }

    private func save(restart: Bool) {
        let settings = draft
        editor.run(panel: panel, module: "Apache", restart: restart ? .apache : nil) {
            try ApacheConfig.save(settings)
        } done: {
            saved = settings
        }
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Use as Web Folder"
        p.directoryURL = URL(fileURLWithPath: draft.documentRoot)
        if p.runModal() == .OK, let url = p.url { draft.documentRoot = url.path }
    }

    static func isProtectedFolder(_ path: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["Desktop", "Documents", "Downloads"].contains { path.hasPrefix("\(home)/\($0)") }
    }
}

/// Shared save / restore / error handling for the settings pages.
struct SettingsEditor {
    var saving = false
    var message: (text: String, ok: Bool)?
    var error: String?
    var confirmRestore = false

    /// Saves in the background, logs the result and restarts the server if asked.
    mutating func run(panel: Panel, module: String, restart: Module?, _ work: @escaping () throws -> Void,
                      done: @escaping () -> Void) {
        saving = true
        message = nil
        let box = EditorBox()
        DispatchQueue.global(qos: .userInitiated).async {
            do { try work() } catch { box.error = error.localizedDescription }
            DispatchQueue.main.async {
                if let e = box.error {
                    panel.add(module, "Settings not saved: \(e.split(separator: "\n").first ?? "")", .error)
                    NotificationCenter.default.post(name: .settingsSaveFinished, object: module, userInfo: ["error": e])
                } else {
                    panel.add(module, "Settings saved", .ok)
                    done()
                    panel.reloadConfig()
                    if module == "PHP" { panel.reloadPHP() }
                    if let restart { panel.restart(restart) }
                    NotificationCenter.default.post(name: .settingsSaveFinished, object: module,
                                                    userInfo: ["restarted": restart != nil])
                }
            }
        }
    }

    private final class EditorBox { var error: String? }
}

extension Notification.Name {
    static let settingsSaveFinished = Notification.Name("lampion.settingsSaveFinished")
}

extension View {
    /// Error alert, "restore original" confirmation and save results for a settings page.
    func settingsAlerts(_ editor: Binding<SettingsEditor>, file: String, module: String,
                        restoreTitle: String = "Restore the original file?",
                        restoreMessage: String? = nil,
                        restore: (() throws -> Void)? = nil,
                        reload: @escaping () -> Void) -> some View {
        self
            .onReceive(NotificationCenter.default.publisher(for: .settingsSaveFinished)) { note in
                guard note.object as? String == module else { return }
                editor.wrappedValue.saving = false
                if let e = note.userInfo?["error"] as? String {
                    editor.wrappedValue.error = e
                } else {
                    let restarted = note.userInfo?["restarted"] as? Bool ?? false
                    editor.wrappedValue.message = (restarted ? "Saved. Restarting \(module)…" : "Saved. Restart \(module) to apply the changes.", true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        if editor.wrappedValue.message?.ok == true { editor.wrappedValue.message = nil }
                    }
                }
            }
            .alert("The settings could not be saved", isPresented: Binding(
                get: { editor.wrappedValue.error != nil }, set: { if !$0 { editor.wrappedValue.error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(editor.wrappedValue.error ?? "")
            }
            .confirmationDialog(restoreTitle, isPresented: editor.confirmRestore) {
                Button("Restore", role: .destructive) {
                    do {
                        if let restore { try restore() } else { try ConfigFile.restoreBackup(file) }
                        Panel.shared?.add(module, "Restored the original configuration", .warn)
                        Panel.shared?.reloadConfig()
                        reload()
                    } catch {
                        editor.wrappedValue.error = error.localizedDescription
                    }
                }
            } message: {
                Text(restoreMessage ?? (ConfigFile.hasBackup(file)
                     ? "This puts back the file as it was before Lampion first changed it. Restart the server afterwards."
                     : "Lampion has not changed this file, so there is no original to restore."))
            }
    }
}
