import SwiftUI
import AppKit

final class Panel: ObservableObject {
    @Published var status: [Module: ModuleStatus] = [:]
    @Published var busy: Set<Module> = []
    @Published var log: [LogEntry] = []
    @Published var phpVersion = "–"
    @Published var phpIni: String?
    @Published var phpLinked = false

    private let actions = DispatchQueue(label: "szerverpanel.actions")   // műveletek sorban
    private var timer: Timer?
    private var refreshing = false
    private var generation = 0

    init() {
        add("Panel", "Szerverpanel started")
        add("Panel", "Homebrew: \(Paths.brew)  ·  htdocs: \(Paths.htdocs)")
        DispatchQueue.global(qos: .utility).async { self.loadPHP() }
        refresh(initial: true)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        if CommandLine.arguments.contains("--selftest") { runSelfTest() }
    }

    // Napló (a képernyőn és a ~/Library/Logs/Szerverpanel.log fájlban)
    private static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Szerverpanel.log")
    private static let fileFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()
    private let fileQueue = DispatchQueue(label: "szerverpanel.logfile")

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
            if self.log.count > 500 { self.log.removeFirst(self.log.count - 500) }
        }
        Thread.isMainThread ? append() : DispatchQueue.main.async(execute: append)
    }

    private func addOutput(_ module: String, _ out: String, _ level: LogEntry.Level = .error) {
        let lines = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for line in lines.suffix(6) { add(module, "  " + line, level) }
    }

    // PHP adatok
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

    // Beállított portok
    var apachePort: Int {
        let conf = (try? String(contentsOfFile: Paths.httpdConf, encoding: .utf8)) ?? ""
        for line in conf.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("Listen ") else { continue }
            if let p = Int(t.dropFirst(7).split(separator: ":").last ?? "") { return p }
        }
        return 80
    }

    var mysqlPort: Int {
        let conf = (try? String(contentsOfFile: Paths.myCnf, encoding: .utf8)) ?? ""
        for line in conf.split(separator: "\n") {
            let t = line.replacingOccurrences(of: " ", with: "")
            if t.hasPrefix("port="), let p = Int(t.dropFirst(5)) { return p }
        }
        return 3306
    }

    func configuredPort(_ m: Module) -> Int { m == .apache ? apachePort : mysqlPort }

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
                self.status = new
                self.refreshing = false
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
        let wasRunning = current.running
        busy.insert(m)
        add(m.title, wasRunning ? "Stopping…" : "Starting…")
        let port = configuredPort(m)

        actions.async {
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

            var s = ModuleStatus()
            for _ in 0..<24 {
                s = Panel.probeAll()[m] ?? ModuleStatus()
                if wasRunning ? !s.running : (s.running && !s.ports.isEmpty) { break }
                Thread.sleep(forTimeInterval: 0.5)
            }

            if wasRunning {
                s.running ? self.add(m.title, "Could not stop", .error)
                          : self.add(m.title, "Stopped", .ok)
                final = s
                return
            }

            // Stabilitás: a szervernek pár másodperc múlva is ugyanazzal a PID-del kell futnia.
            if s.running && !s.ports.isEmpty {
                let pid = s.pids.first
                Thread.sleep(forTimeInterval: 2.5)
                let again = Panel.probeAll()[m] ?? ModuleStatus()
                if again.running && !again.ports.isEmpty && again.pids.first == pid {
                    self.add(m.title, "Started – PID: \(pid.map(String.init) ?? "?"), port: \(self.portText(again))", .ok)
                    final = again
                    return
                }
            }

            // Sikertelen indítás: ne próbálkozzon újra a végtelenségig, és mutassuk a hibát.
            Shell.run(Paths.brewBin, ["services", "stop", m.formula])
            self.add(m.title, "Could not start. The log says:", .error)
            let errs = Panel.errorLines(m)
            if errs.isEmpty { self.add(m.title, "  (no error line found – open Logs)", .error) }
            for line in errs { self.add(m.title, "  " + line, .error) }
            final = Panel.probeAll()[m]
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

    func startAll() { for m in Module.allCases where status[m]?.running == false { toggle(m) } }
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

    func openHtdocs() { Shell.open([Paths.htdocs]) }
    func openTerminal() { Shell.open(["-a", "Terminal", Paths.htdocs]) }
}
