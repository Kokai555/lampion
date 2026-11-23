import SwiftUI
import AppKit

struct MariaDBSettingsView: View {
    @EnvironmentObject var panel: Panel
    @State private var saved = MariaDBSettings()
    @State private var draft = MariaDBSettings()
    @State private var editor = SettingsEditor()
    @State private var pmaAutoLogin = false
    @State private var rootOpen: Bool?          // nil: unknown (MariaDB not running)
    @State private var rootError: String?
    @State private var snippetDB = ""
    @State private var copied: String?
    @State private var pmaError: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var problems: [String] { MariaDBConfig.validate(draft) }
    private var running: Bool { panel.status[.mysql]?.running == true }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    SettingsHeader(symbol: Pane.mariadb.icon, tint: Pane.mariadb.tint,
                                   title: "MariaDB \(panel.versions[.mysql] ?? "")",
                                   detail: "The database server. Empty fields use MariaDB's default, shown in grey.",
                                   file: MariaDBConfig.path, onRestore: { editor.confirmRestore = true })
                }

                Section("Connection") {
                    LabeledContent {
                        ValueField(placeholder: "3306", text: $draft.port,
                                   valid: draft.port.isEmpty || (Int(draft.port).map { (1024...65535).contains($0) } ?? false), width: 90)
                    } label: {
                        FieldLabel("Port", "Programs on this Mac (phpMyAdmin, Lampion) connect through a socket and keep working on any port.")
                    }
                    Toggle(isOn: $draft.localOnly) {
                        FieldLabel("Only this Mac can connect", "bind-address = 127.0.0.1. Turn off to reach the database from other devices on your network.")
                    }
                }

                Section("Capacity") {
                    LabeledContent {
                        ValueField(placeholder: "151", text: $draft.maxConnections,
                                   valid: draft.maxConnections.isEmpty || (Int(draft.maxConnections) ?? 0) > 0, width: 90)
                    } label: {
                        FieldLabel("Maximum connections", "max_connections. How many clients may be connected at once.")
                    }
                    sizeRow("Maximum packet size", "max_allowed_packet. Raise it to import large dumps or store big BLOBs.", $draft.maxAllowedPacket, "16M")
                    sizeRow("InnoDB buffer pool", "innodb_buffer_pool_size. Memory for cached table data. 256M–1G suits most projects.", $draft.bufferPoolSize, "128M")
                }

                Section("Text and SQL") {
                    Picker(selection: $draft.characterSet) {
                        Text("Server default (utf8mb4)").tag("")
                        ForEach(MariaDBSettings.characterSets, id: \.charset) { Text($0.charset).tag($0.charset) }
                    } label: {
                        FieldLabel("Character set", "character-set-server, for new databases and tables.")
                    }
                    .onChange(of: draft.characterSet) { _, new in
                        if let set = MariaDBSettings.characterSets.first(where: { $0.charset == new }), !set.collations.contains(draft.collation) {
                            draft.collation = set.collations[0]
                        } else if new.isEmpty {
                            draft.collation = ""
                        }
                    }
                    Picker(selection: $draft.collation) {
                        Text("Default for the character set").tag("")
                        ForEach(collations, id: \.self) { Text($0).tag($0) }
                    } label: {
                        FieldLabel("Collation", "How text is sorted and compared. Pick a _hungarian_ collation for correct á, ő, ű order.")
                    }
                    .disabled(draft.characterSet.isEmpty)
                    Picker(selection: $draft.sqlMode) {
                        ForEach(MariaDBSettings.SQLMode.allCases.filter { $0 != .custom || saved.sqlMode == .custom }) {
                            Text($0 == .custom ? "Custom: \(draft.customSQLMode.isEmpty ? "none" : draft.customSQLMode)" : $0.title).tag($0)
                        }
                    } label: {
                        FieldLabel("SQL mode", "Strict rejects invalid values; relaxed quietly adjusts them, as old MySQL did.")
                    }
                }

                Section {
                    Toggle(isOn: $draft.slowQueryLog) {
                        FieldLabel("Log slow queries", "Records queries that take longer than the threshold below.")
                    }
                    if draft.slowQueryLog {
                        LabeledContent {
                            HStack(spacing: 6) {
                                ValueField(placeholder: "2", text: $draft.longQueryTime,
                                           valid: draft.longQueryTime.isEmpty || Double(draft.longQueryTime) != nil, width: 70)
                                Text("seconds").foregroundStyle(.secondary).font(.callout)
                            }
                        } label: {
                            FieldLabel("Slow query threshold")
                        }
                    }
                    Toggle(isOn: $draft.generalLog) {
                        FieldLabel("Log every query", "Useful for seeing exactly what an app sends. The file grows quickly, so turn it off when done.")
                    }
                } header: {
                    Text("Query logs")
                } footer: {
                    HStack {
                        Button("Server Log") { panel.show(.mariadb) }
                        Button("Slow Queries") { panel.show(.mariadbSlow) }
                        Button("All Queries") { panel.show(.mariadbGeneral) }
                    }
                    .controlSize(.small)
                }

                Section {
                    Toggle(isOn: Binding(get: { rootOpen ?? false }, set: setRootOpen)) {
                        FieldLabel("root without a password", rootError ?? (rootOpen == nil
                            ? "Start MariaDB to see or change this."
                            : "Like XAMPP: programs log in as root with an empty password. Only from this Mac, never from other computers."))
                    }
                    .disabled(rootOpen == nil)
                    LabeledContent("Host") { copyable("127.0.0.1") }
                    LabeledContent("Port") { copyable(String(panel.mysqlPort)) }
                    LabeledContent("User") { copyable("root") }
                    LabeledContent("Password") {
                        Text(rootOpen == true ? "(empty)" : "—").foregroundStyle(.secondary)
                    }
                    LabeledContent("Socket") { copyable("/tmp/mysql.sock") }
                    LabeledContent {
                        HStack(spacing: 8) {
                            TextField("", text: $snippetDB, prompt: Text("database name"))
                                .textFieldStyle(.roundedBorder).frame(width: 160).labelsHidden()
                            Menu("Copy Settings") {
                                ForEach(MariaDBAccess.snippets(database: snippetDB, port: panel.mysqlPort)) { s in
                                    Button(s.title) { copy(s.text, label: s.title) }
                                }
                            }
                            .fixedSize()
                        }
                    } label: {
                        FieldLabel("For your app", copied.map { "Copied: \($0)" }
                                   ?? "Ready-made settings for PHP, Laravel, Prisma, Node.js, Python and Java.")
                    }
                } header: {
                    Text("Connecting from apps")
                }

                Section {
                    Toggle(isOn: Binding(get: { pmaAutoLogin }, set: setPmaAutoLogin)) {
                        FieldLabel("Sign in automatically", pmaError
                                   ?? "Opens phpMyAdmin as \(NSUserName()) without a login page. Only this Mac can open phpMyAdmin. Applies straight away.")
                    }
                } header: {
                    Text("phpMyAdmin")
                }

                Section("More configuration") {
                    LabeledContent {
                        Button("Edit") { panel.openFile(Paths.myCnf, module: "MySQL") }
                    } label: {
                        FieldLabel("my.cnf", "The main option file. Lampion's settings above are applied after it.")
                    }
                    LabeledContent {
                        Button("Edit") { panel.openFile(Paths.pmaConf, module: "MySQL") }
                    } label: {
                        FieldLabel("phpMyAdmin", "config.inc.php")
                    }
                }
            }
            .formStyle(.grouped)
            // Animates the form only when the slow query toggle adds or removes its threshold row.
            .animation(Motion.standard(reduceMotion), value: draft.slowQueryLog)

            SaveBar(dirty: draft != saved, problems: problems, saving: editor.saving,
                    restartName: running ? "MySQL" : nil, message: editor.message,
                    onRevert: { draft = saved }, onSave: save)
        }
        .onAppear {
            loadPma()
            loadRoot()
            if let kept = panel.storedDraft(.mariadb, as: MariaDBSettings.self) {
                saved = kept.saved; draft = kept.draft
            } else { load() }
        }
        .onChange(of: draft) { panel.keepDraft(.mariadb, saved: saved, draft: draft) }
        .onChange(of: saved) { panel.keepDraft(.mariadb, saved: saved, draft: draft) }
        .settingsAlerts($editor, file: MariaDBConfig.path, module: "MySQL",
                        restoreTitle: "Go back to MariaDB's defaults?",
                        restoreMessage: "This deletes lampion.cnf, so only my.cnf and MariaDB's built-in defaults apply. Restart MariaDB afterwards.",
                        restore: MariaDBConfig.reset) { load() }
    }

    private var collations: [String] {
        MariaDBSettings.characterSets.first { $0.charset == draft.characterSet }?.collations ?? []
    }

    private func sizeRow(_ title: String, _ detail: String, _ value: Binding<String>, _ placeholder: String) -> some View {
        LabeledContent {
            ValueField(placeholder: placeholder, text: value,
                       valid: value.wrappedValue.isEmpty || ConfigFile.isSize(value.wrappedValue), width: 90)
        } label: {
            FieldLabel(title, detail)
        }
    }

    private func load() {
        let s = MariaDBConfig.load()
        saved = s; draft = s
    }

    private func copyable(_ value: String) -> some View {
        HStack(spacing: 6) {
            Text(value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Button { copy(value, label: value) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help("Copy")
        }
    }

    private func copy(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = label
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if copied == label { copied = nil } }
    }

    private func loadRoot() {
        DispatchQueue.global(qos: .userInitiated).async {
            let state = MariaDBAccess.rootWithoutPassword()
            DispatchQueue.main.async { rootOpen = state }
        }
    }

    private func setRootOpen(_ on: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try MariaDBAccess.setRootWithoutPassword(on) }
            DispatchQueue.main.async {
                switch result {
                case .success:
                    rootError = nil
                    UserDefaults.standard.set(true, forKey: Prefs.rootWithoutPasswordChosen)
                    panel.add("MySQL", on ? "root can now log in without a password (from this Mac only)"
                                         : "root without a password is turned off", .ok)
                case .failure(let e):
                    rootError = e.localizedDescription
                }
                loadRoot()
            }
        }
    }

    private func loadPma() {
        pmaAutoLogin = (try? String(contentsOfFile: PhpMyAdminConfig.path, encoding: .utf8)).map(PhpMyAdminConfig.autoLogin(in:)) ?? false
    }

    private func setPmaAutoLogin(_ on: Bool) {
        do {
            try PhpMyAdminConfig.save(autoLogin: on)
            UserDefaults.standard.set(true, forKey: Prefs.phpMyAdminSignInChosen)
            pmaError = nil
            panel.add("MySQL", on ? "phpMyAdmin now signs in automatically as \(NSUserName())" : "phpMyAdmin asks for a login again", .ok)
        } catch {
            pmaError = error.localizedDescription
        }
        loadPma()
    }

    private func save(restart: Bool) {
        let settings = draft
        editor.run(panel: panel, module: "MySQL", restart: restart ? .mysql : nil) {
            try MariaDBConfig.save(settings)
        } done: {
            saved = settings
        }
    }
}
