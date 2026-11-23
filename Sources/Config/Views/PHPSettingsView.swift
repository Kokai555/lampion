import SwiftUI
import AppKit

struct PHPSettingsView: View {
    @EnvironmentObject var panel: Panel
    @State private var saved = PHPSettings()
    @State private var draft = PHPSettings()
    @State private var iniPath: String?
    @State private var extensions: [String] = []
    @State private var editor = SettingsEditor()

    private var problems: [String] { PHPConfig.validate(draft) }
    private var running: Bool { panel.status[.apache]?.running == true }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    SettingsHeader(symbol: Pane.php.icon, tint: Pane.php.tint, title: "PHP \(panel.phpVersion)",
                                   detail: "PHP runs inside Apache, so Apache restarts to apply changes.",
                                   file: iniPath, onRestore: { editor.confirmRestore = true })
                }

                Section {
                    sizeRow("Memory limit", "The most memory one request may use. -1 means no limit.", $draft.memoryLimit, "128M")
                    sizeRow("Maximum upload size", "upload_max_filesize: the largest file a form can upload.", $draft.uploadMaxFilesize, "2M")
                    sizeRow("Maximum POST size", "post_max_size: the whole form, uploads included. Keep it above the upload size.", $draft.postMaxSize, "8M")
                    numberRow("Maximum run time", "Seconds a script may run before PHP stops it. 0 means no limit.", $draft.maxExecutionTime, "seconds")
                    numberRow("Maximum input time", "Seconds PHP waits for a request's data, such as a large upload. -1 uses the run time.", $draft.maxInputTime, "seconds")
                    numberRow("Maximum input variables", "How many form fields a request may have.", $draft.maxInputVars, "fields")
                } header: {
                    Text("Limits")
                }

                Section {
                    Toggle(isOn: $draft.displayErrors) {
                        FieldLabel("Show errors on the page", "display_errors. Handy while developing, never on a live site.")
                    }
                    Toggle(isOn: $draft.displayStartupErrors) {
                        FieldLabel("Show startup errors", "display_startup_errors. Problems while PHP itself starts.")
                    }
                    Picker(selection: $draft.errorReporting) {
                        ForEach(PHPSettings.errorReportingPresets, id: \.value) { Text($0.title).tag($0.value) }
                        if !PHPSettings.errorReportingPresets.contains(where: { $0.value == draft.errorReporting }) {
                            Divider()
                            Text("Custom: \(draft.errorReporting)").tag(draft.errorReporting)
                        }
                    } label: {
                        FieldLabel("Report", "error_reporting: which kinds of problems PHP reports.")
                    }
                    Toggle(isOn: $draft.logErrors) {
                        FieldLabel("Write errors to a log", "log_errors.")
                    }
                    Toggle(isOn: $draft.separateErrorLog) {
                        FieldLabel("Separate PHP error log", draft.separateErrorLog
                                   ? "PHP errors go to \(Paths.phpErrorLog)."
                                   : "Off: PHP errors go to Apache's error log.")
                    }
                    .disabled(!draft.logErrors)
                } header: {
                    HStack {
                        Text("Errors")
                        Spacer()
                        Button("Development") { draft.applyDevelopmentPreset() }
                            .help("Show every error on the page and log it")
                        Button("Production") { draft.applyProductionPreset() }
                            .help("Hide errors from the page and only log them, like a live server")
                    }
                    .controlSize(.small)
                }

                Section("Other") {
                    LabeledContent {
                        timezoneMenu
                    } label: {
                        FieldLabel("Time zone", "date.timezone, used by date() and DateTime.")
                    }
                    Toggle(isOn: $draft.shortOpenTag) {
                        FieldLabel("Short open tags", "Treat <? as <?php. Only some old projects need this.")
                    }
                    Toggle(isOn: $draft.opcache) {
                        FieldLabel("OPcache", "Keeps compiled scripts in memory. Changes to files are still picked up.")
                    }
                    LabeledContent {
                        HStack(spacing: 6) {
                            ValueField(placeholder: "1440", text: $draft.sessionLifetime.text, valid: draft.sessionLifetime > 0, width: 80)
                            Text("seconds").foregroundStyle(.secondary).font(.callout)
                        }
                    } label: {
                        FieldLabel("Session lifetime", "session.gc_maxlifetime. 1440 is 24 minutes.")
                    }
                }

                Section {
                    if extensions.isEmpty {
                        Text("Loading…").foregroundStyle(.secondary)
                    } else {
                        Text(extensions.joined(separator: "  ·  "))
                            .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text("Extensions (\(extensions.count))")
                } footer: {
                    Text("Homebrew's PHP comes with these built in. Add more with `pecl install`.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent {
                        Button("Show") { panel.show(draft.separateErrorLog ? .php : .apacheError) }
                    } label: {
                        FieldLabel("Error log", draft.separateErrorLog ? "PHP Errors" : "Apache Errors")
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(iniPath == nil)

            SaveBar(dirty: draft != saved, problems: problems, saving: editor.saving,
                    restartName: running ? "Apache" : nil, message: editor.message,
                    onRevert: { draft = saved }, onSave: save)
        }
        .onAppear {
            if let kept = panel.storedDraft(.php, as: PHPSettings.self) {
                saved = kept.saved; draft = kept.draft
                load(settings: false)
            } else { load() }
        }
        .onChange(of: draft) { panel.keepDraft(.php, saved: saved, draft: draft) }
        .onChange(of: saved) { panel.keepDraft(.php, saved: saved, draft: draft) }
        .settingsAlerts($editor, file: iniPath ?? "", module: "PHP") { load() }
    }

    private func sizeRow(_ title: String, _ detail: String, _ value: Binding<String>, _ placeholder: String) -> some View {
        LabeledContent {
            ValueField(placeholder: placeholder, text: value, valid: ConfigFile.isSize(value.wrappedValue), width: 90)
        } label: {
            FieldLabel(title, detail)
        }
    }

    private func numberRow(_ title: String, _ detail: String, _ value: Binding<Int>, _ unit: String) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                ValueField(placeholder: "", text: value.text, width: 80)
                Text(unit).foregroundStyle(.secondary).font(.callout).frame(width: 52, alignment: .leading)
            }
        } label: {
            FieldLabel(title, detail)
        }
    }

    private static let zonesByRegion: [(region: String, zones: [String])] = {
        let groups = Dictionary(grouping: TimeZone.knownTimeZoneIdentifiers.filter { $0.contains("/") }) {
            String($0.split(separator: "/").first ?? "")
        }
        return groups.keys.sorted().map { ($0, groups[$0]!.sorted()) }
    }()

    private var timezoneMenu: some View {
        Menu(draft.timezone.isEmpty ? "Not set" : draft.timezone) {
            let mine = TimeZone.current.identifier
            Button("This Mac (\(mine))") { draft.timezone = mine }
            Button("UTC") { draft.timezone = "UTC" }
            Button("Not set") { draft.timezone = "" }
            Divider()
            ForEach(Self.zonesByRegion, id: \.region) { group in
                Menu(group.region) {
                    ForEach(group.zones, id: \.self) { z in
                        Button(z.split(separator: "/").dropFirst().joined(separator: "/").replacingOccurrences(of: "_", with: " ")) {
                            draft.timezone = z
                        }
                    }
                }
            }
        }
        .fixedSize()
    }

    /// `settings: false` only looks up php.ini and the extensions, keeping the edits in progress.
    private func load(settings: Bool = true) {
        DispatchQueue.global(qos: .userInitiated).async {
            let path = PHPConfig.iniPath()
            let result = Result { try path.map(PHPConfig.load(from:)) }
            let mods = Shell.run(Paths.php, ["-m"]).out.split(separator: "\n").map(String.init)
                .filter { !$0.isEmpty && !$0.hasPrefix("[") }
            DispatchQueue.main.async {
                iniPath = path
                extensions = Array(Set(mods)).sorted { $0.lowercased() < $1.lowercased() }
                guard settings else { return }
                switch result {
                case .success(let s?): saved = s; draft = s
                case .success(nil): editor.error = "PHP did not report a php.ini file. Is PHP installed?"
                case .failure(let e): editor.error = e.localizedDescription
                }
            }
        }
    }

    private func save(restart: Bool) {
        guard let iniPath else { return }
        let settings = draft
        editor.run(panel: panel, module: "PHP", restart: restart ? .apache : nil) {
            try PHPConfig.save(settings, to: iniPath)
        } done: {
            saved = settings
        }
    }
}
