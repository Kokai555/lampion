import SwiftUI
import AppKit

final class Panel: ObservableObject {
    @Published var status: [Module: ModuleStatus] = [:]
    @Published var busy: Set<Module> = []
    @Published var log: [LogEntry] = []
    @Published var phpVersion = "–"
    @Published var phpIni: String?
    @Published var phpLinked = false
    @Published var setupState: SetupState = .ready
    @Published var pane: Pane = .overview
    @Published var logSource: LogSource = .activity
    /// Settings pages with edits that are not saved yet, and those edits (saved, draft), kept across pane switches.
    @Published private(set) var unsaved: Set<Pane> = []
    private var drafts: [Pane: Any] = [:]
    @Published var versions: [Module: String] = [:]
    @Published var documentRoot = Paths.htdocs
    @Published var ports: [Module: Int] = [.apache: 8080, .mysql: 3306]
    /// Where the logs and the databases are (they move to ~/Lampion); views read Paths, this triggers their refresh.
    @Published var locations = Locations()
    /// True while everything is being moved to ~/Lampion.
    @Published var movingHome = false

    /// The running panel, for the app delegate (stop servers on quit).
    static weak var shared: Panel?

    let actions = DispatchQueue(label: "lampion.actions")   // műveletek sorban
    private var timer: Timer?
    private var refreshing = false
    var generation = 0
    private var refreshCount = 0
    private static var rootDefaultChecked = false

    init() {
        Panel.shared = self
        add("Panel", "Lampion started")
        add("Panel", "Homebrew: \(Paths.brew)  ·  web folder: \(ApacheConfig.documentRoot())")
        DispatchQueue.global(qos: .utility).async {
            self.loadPHP(); self.loadVersions()
            if !CommandLine.arguments.contains("--selftest") {
                PhpMyAdminConfig.enableByDefault { self.add("MySQL", $0) }
            }
        }
        reloadConfig()
        refresh(initial: true)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        if CommandLine.arguments.contains("--selftest") { runSelfTest() }
    }

    // Napló (a képernyőn és a ~/Library/Logs/Lampion.log fájlban)
    private static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Lampion.log")
    private static let fileFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()
    private let fileQueue = DispatchQueue(label: "lampion.logfile")

    func add(_ module: String, _ text: String, _ level: LogEntry.Level = .info) {
        let entry = LogEntry(module: module, text: text, level: level)
        let tag = ["info": "", "ok": " OK", "warn": " WARN", "error": " ERROR"]["\(level)"] ?? ""
        let line = "\(Panel.fileFmt.string(from: entry.time)) [\(module)]\(tag) \(text)\n"
        fileQueue.async {
            let url = Panel.logURL
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
        let append = {
            self.log.append(entry)
            if self.log.count > 2000 { self.log.removeFirst(self.log.count - 2000) }
        }
        Thread.isMainThread ? append() : DispatchQueue.main.async(execute: append)
    }

    func clearLog() { log.removeAll() }

    func keepDraft<T: Equatable>(_ pane: Pane, saved: T, draft: T) {
        if saved == draft {
            drafts[pane] = nil
            if unsaved.contains(pane) { unsaved.remove(pane) }
        } else {
            drafts[pane] = (saved, draft)
            if !unsaved.contains(pane) { unsaved.insert(pane) }
        }
    }

    func storedDraft<T>(_ pane: Pane, as type: T.Type) -> (saved: T, draft: T)? {
        drafts[pane] as? (T, T)
    }

    /// Switches to the Logs pane showing the given log.
    func show(_ source: LogSource) {
        logSource = source
        pane = .logs
    }

    private func addOutput(_ module: String, _ out: String, _ level: LogEntry.Level = .error) {
        let lines = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for line in lines.suffix(6) { add(module, "  " + line, level) }
    }

    // PHP adatok
    func reloadPHP() { DispatchQueue.global(qos: .utility).async { self.loadPHP() } }

    private func loadPHP() {
        let r = Shell.run(Paths.php, ["-r", "echo PHP_VERSION.PHP_EOL.php_ini_loaded_file();"])
        let parts = r.out.split(separator: "\n").map(String.init)
        let conf = (try? String(contentsOfFile: Paths.httpdConf, encoding: .utf8)) ?? ""
        let linked = conf.split(separator: "\n").contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("LoadModule php_module")
        }
        DispatchQueue.main.async {
            if r.status == 0, let v = parts.first {
                self.phpVersion = v
                self.phpIni = parts.count > 1 ? parts[1] : nil
                self.add("PHP", "PHP \(v) – " + (linked ? "linked into Apache" : "NOT linked into Apache"),
                         linked ? .info : .warn)
            } else {
                self.add("PHP", "PHP not found (\(Paths.php))", .error)
            }
            self.phpLinked = linked
        }
    }

    // Configured ports and web folder (read from the config files, cached for the views)
    var apachePort: Int { ports[.apache] ?? 8080 }
    var mysqlPort: Int { ports[.mysql] ?? 3306 }

    func configuredPort(_ m: Module) -> Int { m == .apache ? apachePort : mysqlPort }

    /// Reads the port from the configuration files now (the files may have been edited by hand).
    static func freshPort(_ m: Module) -> Int {
        m == .apache ? ((try? ApacheConfig.load().port) ?? 8080) : MariaDBConfig.effectivePort()
    }

    /// Re-reads the ports and the web folder after the configuration changes.
    func reloadConfig() {
        DispatchQueue.global(qos: .utility).async {
            let apache = (try? ApacheConfig.load())
            let mysql = MariaDBConfig.effectivePort()
            let locations = Locations.refresh()
            DispatchQueue.main.async {
                if self.locations != locations { self.locations = locations }
                // Assign only real changes: this runs every 10 s, and each publish redraws the whole window.
                if let apache {
                    if self.ports[.apache] != apache.port { self.ports[.apache] = apache.port }
                    if self.documentRoot != apache.documentRoot { self.documentRoot = apache.documentRoot }
                }
                if self.ports[.mysql] != mysql { self.ports[.mysql] = mysql }
            }
        }
    }

    private func loadVersions() {
        let apache = Shell.run(Paths.httpd, ["-v"]).out
        let maria = Shell.run(Paths.mariadbd, ["--version"]).out
        var v: [Module: String] = [:]
        if let r = apache.range(of: "Apache/") {
            v[.apache] = String(apache[r.upperBound...].prefix { !$0.isWhitespace })
        }
        if let r = maria.range(of: "Ver ") {
            v[.mysql] = String(maria[r.upperBound...].prefix { !$0.isWhitespace }).replacingOccurrences(of: "-MariaDB", with: "")
        }
        DispatchQueue.main.async { self.versions = v }
    }

    // Állapot lekérdezése
    static func probeAll() -> [Module: ModuleStatus] {
        let list = Shell.run("/bin/launchctl", ["list"]).out
        var result: [Module: ModuleStatus] = [:]
        for m in Module.allCases {
            var s = ModuleStatus()
            s.installed = FileManager.default.isExecutableFile(atPath: m.binary)
            for line in list.split(separator: "\n") {
                let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard cols.count == 3, cols[2] == m.label else { continue }
                s.loaded = true
                if let pid = Int(cols[0]) { s.pids = [pid] }
            }
            if let main = s.pids.first {
                s.running = true
                let kids = Shell.run("/usr/bin/pgrep", ["-P", String(main)]).out
                let all = [main] + kids.split(separator: "\n").compactMap { Int($0) }
                let lsof = Shell.run("/usr/sbin/lsof", ["-nP", "-a", "-p", all.map(String.init).joined(separator: ","),
                                                         "-iTCP", "-sTCP:LISTEN", "-Fpn"]).out
                var current = 0
                var listeners = Set<Int>(), ports = Set<Int>()
                for line in lsof.split(separator: "\n") {
                    if line.hasPrefix("p") { current = Int(line.dropFirst()) ?? 0 }
                    if line.hasPrefix("n"), let port = Int(line.split(separator: ":").last ?? "") {
                        ports.insert(port); listeners.insert(current)
                    }
                }
                if !listeners.isEmpty { s.pids = listeners.sorted() }
                s.ports = ports.sorted()
            }
            result[m] = s
        }
        return result
    }

    static func portInUse(_ port: Int) -> Bool {
        Shell.run("/usr/bin/nc", ["-z", "-G", "1", "127.0.0.1", String(port)]).status == 0
    }

    func refresh(initial: Bool = false) {
        if refreshing { return }
        refreshing = true
        let gen = generation
        DispatchQueue.global(qos: .utility).async {
            let new = Panel.probeAll()
            DispatchQueue.main.async {
                if gen != self.generation { self.refreshing = false; return }
                let old = self.status
                if new != old { self.status = new }
                self.refreshCount += 1
                if new[.mysql]?.running == true && !Panel.rootDefaultChecked && !CommandLine.arguments.contains("--selftest") {
                    Panel.rootDefaultChecked = true
                    DispatchQueue.global(qos: .utility).async { MariaDBAccess.enableByDefault { self.add("MySQL", $0) } }
                }
                if self.refreshCount % 5 == 0 { self.reloadConfig() }   // pick up hand edits of the config files
                self.refreshing = false
                self.evaluateSetup()
                if initial && UserDefaults.standard.bool(forKey: Prefs.startServersOnLaunch)
                    && !CommandLine.arguments.contains("--selftest") && self.setupState == .ready {
                    self.add("Panel", "Starting the servers (General → Start servers when Lampion opens)")
                    self.startAll()
                }
                for m in Module.allCases {
                    guard let n = new[m] else { continue }
                    if initial {
                        if !n.installed { self.add(m.title, "Not installed (\(m.binary))", .error) }
                        else if n.running { self.add(m.title, "Running – port: \(self.portText(n))", .ok) }
                        else { self.add(m.title, "Stopped") }
                    } else if let o = old[m], !self.busy.contains(m), o.running != n.running {
                        if n.running {
                            self.add(m.title, "Started (externally)", .ok)
                        } else {
                            self.add(m.title, "Stopped unexpectedly. The log says:", .warn)
                            for line in Panel.errorLines(m) { self.add(m.title, "  " + line, .warn) }
                        }
                    }
                }
            }
        }
    }

    func portText(_ s: ModuleStatus) -> String {
        s.ports.isEmpty ? "–" : s.ports.map(String.init).joined(separator: ", ")
    }

    // Start / Stop
    func toggle(_ m: Module) {
        guard !busy.contains(m) else { return }
        let current = status[m] ?? ModuleStatus()
        guard current.installed else {
            add(m.title, "Not installed yet – use Set Up at the top of the window.", .warn)
            return
        }
        let wasRunning = current.running
        busy.insert(m)
        add(m.title, wasRunning ? "Stopping…" : "Starting…")

        actions.async {
            let port = Panel.freshPort(m)
            var final: ModuleStatus?
            defer {
                DispatchQueue.main.async {
                    // A saját műveletünk eredményét rögzítjük, hogy a frissítés ne jelezze "váratlannak".
                    if let final { self.status[m] = final }
                    self.generation += 1   // a közben futó, elavult frissítést eldobjuk
                    self.busy.remove(m)
                }
            }

            if !wasRunning {
                if m == .apache {
                    let t = Shell.run(Paths.httpd, ["-t"])
                    if t.status != 0 {
                        self.add(m.title, "Invalid configuration (httpd.conf):", .error)
                        self.addOutput(m.title, t.out)
                        return
                    }
                }
                if Panel.portInUse(port) {
                    self.add(m.title, "Port \(port) is already in use, probably by XAMPP or another program.", .error)
                    return
                }
            }

            let verb = wasRunning ? "stop" : (current.loaded ? "restart" : "start")
            let r = Shell.run(Paths.brewBin, ["services", verb, m.formula])
            if r.status != 0 {
                self.add(m.title, "brew services \(verb) failed:", .error)
                self.addOutput(m.title, r.out)
                return
            }

            if wasRunning {
                var s = ModuleStatus()
                for _ in 0..<24 {
                    s = Panel.probeAll()[m] ?? ModuleStatus()
                    if !s.running { break }
                    Thread.sleep(forTimeInterval: 0.5)
                }
                s.running ? self.add(m.title, "Could not stop", .error)
                          : self.add(m.title, "Stopped", .ok)
                final = s
                return
            }
            final = self.awaitStart(m, verb: "Started")
        }
    }

    /// Waits until a server that was just started is listening and stays up. On failure it is stopped
    /// (so launchd does not keep restarting it) and the error lines from its log are shown.
    private func awaitStart(_ m: Module, verb: String) -> ModuleStatus? {
        var s = ModuleStatus()
        for _ in 0..<24 {
            s = Panel.probeAll()[m] ?? ModuleStatus()
            if s.running && !s.ports.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.5)
        }

        // Stabilitás: a szervernek pár másodperc múlva is ugyanazzal a PID-del kell futnia.
        if s.running && !s.ports.isEmpty {
            let pid = s.pids.first
            Thread.sleep(forTimeInterval: 2.5)
            let again = Panel.probeAll()[m] ?? ModuleStatus()
            if again.running && !again.ports.isEmpty && again.pids.first == pid {
                add(m.title, "\(verb) – PID: \(pid.map(String.init) ?? "?"), port: \(portText(again))", .ok)
                return again
            }
        }

        // Sikertelen indítás: ne próbálkozzon újra a végtelenségig, és mutassuk a hibát.
        Shell.run(Paths.brewBin, ["services", "stop", m.formula])
        add(m.title, "Could not start. The log says:", .error)
        let errs = Panel.errorLines(m)
        if errs.isEmpty { add(m.title, "  (no error line found – see Logs)", .error) }
        for line in errs { add(m.title, "  " + line, .error) }
        return Panel.probeAll()[m]
    }

    /// Restarts a running server so it picks up configuration changes.
    func restart(_ m: Module) {
        guard !busy.contains(m), status[m]?.running == true else { return }
        busy.insert(m)
        add(m.title, "Restarting to apply the new settings…")
        actions.async {
            var final: ModuleStatus?
            defer {
                DispatchQueue.main.async {
                    if let final { self.status[m] = final }
                    self.generation += 1
                    self.busy.remove(m)
                }
            }
            if m == .apache {
                let t = Shell.run(Paths.httpd, ["-t"])
                if t.status != 0 {
                    self.add(m.title, "Invalid configuration (httpd.conf), not restarting:", .error)
                    self.addOutput(m.title, t.out)
                    return
                }
            }
            // A newly configured port must be free, or the server would not come back up.
            let port = Panel.freshPort(m)
            let current = DispatchQueue.main.sync { self.status[m]?.ports ?? [] }
            if !current.contains(port) && Panel.portInUse(port) {
                self.add(m.title, "Not restarting: the new port \(port) is already in use by another program. Pick another port.", .error)
                return
            }
            let r = Shell.run(Paths.brewBin, ["services", "restart", m.formula])
            if r.status != 0 {
                self.add(m.title, "brew services restart failed:", .error)
                self.addOutput(m.title, r.out)
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
            final = self.awaitStart(m, verb: "Restarted")
        }
    }

    /// Az utolsó néhány hibasor a modul naplófájljából.
    static func errorLines(_ m: Module, count: Int = 3) -> [String] {
        guard let path = m == .apache ? Paths.apacheErrorLog : Paths.mysqlErrorLog,
              let h = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 32_768 ? size - 32_768 : 0)
        let text = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        let lines = text.split(separator: "\n").map(String.init).filter {
            ["[ERROR]", ":error]", ":emerg]", ":crit]", ":alert]"].contains(where: $0.contains)
                && !$0.contains("Aborting")
        }
        return lines.suffix(count).map { $0.count > 140 ? String($0.prefix(140)) + "…" : $0 }
    }

    func startAll() { for m in Module.allCases where status[m]?.running == false && status[m]?.installed == true { toggle(m) } }
    func stopAll() { for m in Module.allCases where status[m]?.running == true { toggle(m) } }

    // Admin / Config / Logs
    func admin(_ m: Module) {
        guard status[.apache]?.running == true else {
            add(m.title, "Apache is not running – start it first.", .warn)
            return
        }
        if m == .mysql && status[.mysql]?.running != true {
            add(m.title, "MySQL is not running – phpMyAdmin can only sign in once you start it.", .warn)
        }
        let path = m == .apache ? "/" : "/phpmyadmin/"
        Shell.open(["http://localhost:\(apachePort)\(path)"])
    }

    func openFile(_ path: String?, module: String) {
        guard let path, FileManager.default.fileExists(atPath: path) else {
            add(module, "File not found: \(path ?? "?")", .error)
            return
        }
        Shell.open(["-t", path])
    }

    func openHtdocs() { Shell.open([documentRoot]) }
    func openTerminal() { Shell.open(["-a", "Terminal", documentRoot]) }

    /// Stops the servers before Lampion quits (General → Stop servers when Lampion quits). Waits for any start
    /// or stop that is still in progress, then stops every installed server, off the main thread.
    func stopAllBeforeQuit(then done: @escaping () -> Void) {
        let installed = Module.allCases.filter { status[$0]?.installed != false }
        add("Panel", "Stopping the servers before quitting…")
        actions.async {
            for m in installed where Panel.probeAll()[m]?.loaded == true {
                Shell.run(Paths.brewBin, ["services", "stop", m.formula])
            }
            DispatchQueue.main.async(execute: done)
        }
    }
}
