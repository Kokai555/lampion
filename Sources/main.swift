// Szerverpanel – natív macOS kezelőpanel a Homebrew-os Apache + PHP + MariaDB stackhez.
import SwiftUI
import AppKit

// MARK: - Útvonalak

enum Paths {
    static let brew = "/opt/homebrew"
    static let brewBin = "\(brew)/bin/brew"
    static let httpd = "\(brew)/bin/httpd"
    static let mariadbd = "\(brew)/bin/mariadbd"
    static let php = "\(brew)/bin/php"
    static let httpdConf = "\(brew)/etc/httpd/httpd.conf"
    static let vhostsConf = "\(brew)/etc/httpd/extra/httpd-vhosts.conf"
    static let apacheErrorLog = "\(brew)/var/log/httpd/error_log"
    static let apacheAccessLog = "\(brew)/var/log/httpd/access_log"
    static let myCnf = "\(brew)/etc/my.cnf"
    static let mysqlData = "\(brew)/var/mysql"
    static let pmaConf = "\(brew)/etc/phpmyadmin.config.inc.php"
    static let htdocs = "\(brew)/var/www"

    /// A MariaDB hibanaplója: <hostname>.err a data mappában.
    static var mysqlErrorLog: String? {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: mysqlData)) ?? []
        return files.first { $0.hasSuffix(".err") }.map { "\(mysqlData)/\($0)" }
    }
}

// MARK: - Parancsfuttatás

enum Shell {
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(Paths.brew)/bin:\(Paths.brew)/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func open(_ args: [String]) { run("/usr/bin/open", args) }
}

// MARK: - Modell

enum Module: String, CaseIterable, Identifiable {
    case apache, mysql
    var id: String { rawValue }
    var title: String { self == .apache ? "Apache" : "MySQL" }
    var formula: String { self == .apache ? "httpd" : "mariadb" }
    var label: String { "sh.brew.\(formula)" }
    var binary: String { self == .apache ? Paths.httpd : Paths.mariadbd }
}

struct ModuleStatus: Equatable {
    var installed = true
    var loaded = false      // regisztrálva van a launchd-ben
    var running = false
    var pids: [Int] = []
    var ports: [Int] = []
}

struct LogEntry: Identifiable {
    enum Level { case info, ok, warn, error }
    let id = UUID()
    let time = Date()
    let module: String
    let text: String
    let level: Level
}

// MARK: - Vezérlő

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

    // MARK: Önteszt (indítás: open -a Szerverpanel --args --selftest)

    func runSelfTest() {
        DispatchQueue.global(qos: .userInitiated).async {
            var failures: [String] = []
            func onMain<T>(_ f: () -> T) -> T { DispatchQueue.main.sync(execute: f) }
            func waitIdle() {
                Thread.sleep(forTimeInterval: 0.3)
                for _ in 0..<120 where !onMain({ self.busy.isEmpty }) { Thread.sleep(forTimeInterval: 0.25) }
            }
            func running(_ m: Module) -> Bool { onMain { self.status[m]?.running == true } }
            func httpCode(_ url: String) -> String {
                Shell.run("/usr/bin/curl", ["-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", url]).out
            }
            func check(_ ok: Bool, _ what: String) {
                self.add("Test", (ok ? "✓ " : "✗ ") + what, ok ? .ok : .error)
                if !ok { failures.append(what) }
            }

            Thread.sleep(forTimeInterval: 1.5)
            self.add("Test", "Self-test starting")

            // 1. Leállítás
            onMain { self.stopAll() }; waitIdle()
            check(!running(.apache) && !running(.mysql), "Stop All: both servers stopped")

            // 2. Port-ütközés felismerése
            let port = onMain { self.apachePort }
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port).bigEndian)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            } == 0 && listen(fd, 1) == 0
            if bound {
                let before = onMain { self.log.count }
                onMain { self.toggle(.apache) }; waitIdle()
                let msgs = onMain { self.log.suffix(from: before).map(\.text) }
                check(!running(.apache) && msgs.contains { $0.contains("already in use") },
                      "With port \(port) taken, Apache does not start and reports an error")
            } else {
                check(false, "Reserving test port (\(port))")
            }
            close(fd)

            // 3. Indítás
            onMain { self.startAll() }; waitIdle()
            check(running(.apache), "Apache started")
            check(running(.mysql), "MySQL started")

            // 4. Elérhetőség
            check(httpCode("http://localhost:\(port)/") == "200", "Website responds (http://localhost:\(port)/)")
            check(httpCode("http://localhost:\(port)/phpmyadmin/") == "200", "phpMyAdmin responds")
            let db = Shell.run("\(Paths.brew)/bin/mariadb", ["-N", "-e", "SELECT 1"])
            check(db.status == 0 && db.out.trimmingCharacters(in: .whitespacesAndNewlines) == "1", "MySQL query works")

            self.add("Test", failures.isEmpty ? "SELF-TEST PASSED" : "SELF-TEST FAILED: \(failures.count) failures",
                     failures.isEmpty ? .ok : .error)
        }
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

// MARK: - Nézetek

struct ContentView: View {
    @EnvironmentObject var panel: Panel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
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
        .onAppear {
            let args = CommandLine.arguments
            if args.contains("--db") || args.contains("--dbtest") { openWindow(id: "db") }
        }
    }
}

/// Állapotjelző: az állapotot szimbólum és szöveg is jelzi, nem csak a szín.
struct StatusBadge: View {
    let title: String
    let on: Bool
    var onText = "Running"
    var offText = "Stopped"

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: on ? "checkmark.circle.fill" : "stop.circle")
                .font(.system(size: 17))
                .foregroundStyle(on ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.semibold)
                Text(on ? onText : offText).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: 140, alignment: .leading)
        .accessibilityElement(children: .combine)
        .animation(.easeInOut(duration: 0.2), value: on)
    }
}

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

struct LogPane: View {
    @EnvironmentObject var panel: Panel
    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(panel.log) { e in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(Self.fmt.string(from: e.time)).foregroundStyle(.secondary)
                            Text("[\(e.module)]").foregroundStyle(.blue).frame(width: 72, alignment: .leading)
                            Text(e.text).foregroundStyle(color(e.level))
                        }
                        .id(e.id)
                    }
                }
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: panel.log.count) {
                if let last = panel.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func color(_ l: LogEntry.Level) -> Color {
        switch l {
        case .info: return .primary
        case .ok: return .green
        case .warn: return .orange
        case .error: return .red
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Minden parancs elérhető a menüsorból is.
struct AppCommands: Commands {
    @ObservedObject var panel: Panel
    @ObservedObject var db: DBModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}

        CommandMenu("Server") {
            Button("Start All") { panel.startAll() }.keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Stop All") { panel.stopAll() }.keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
            ForEach(Module.allCases) { m in
                Button("\(panel.status[m]?.running == true ? "Stop" : "Start") \(m.title)") { panel.toggle(m) }
                    .disabled(panel.busy.contains(m))
            }
            Divider()
            Button("Open Website") { panel.admin(.apache) }
            Button("Open phpMyAdmin") { panel.admin(.mysql) }
            Button("Open Web Folder") { panel.openHtdocs() }.keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Open Terminal") { panel.openTerminal() }
            Divider()
            Menu("Config Files") {
                Button("httpd.conf") { panel.openFile(Paths.httpdConf, module: "Apache") }
                Button("httpd-vhosts.conf") { panel.openFile(Paths.vhostsConf, module: "Apache") }
                Button("php.ini") { panel.openFile(panel.phpIni, module: "PHP") }
                Button("my.cnf") { panel.openFile(Paths.myCnf, module: "MySQL") }
                Button("phpMyAdmin (config.inc.php)") { panel.openFile(Paths.pmaConf, module: "MySQL") }
            }
            Menu("Logs") {
                Button("Apache error_log") { panel.openFile(Paths.apacheErrorLog, module: "Apache") }
                Button("Apache access_log") { panel.openFile(Paths.apacheAccessLog, module: "Apache") }
                Button("MariaDB Error Log") { panel.openFile(Paths.mysqlErrorLog, module: "MySQL") }
            }
        }

        CommandMenu("Database") {
            Button("Open Database Manager") { openWindow(id: "db") }.keyboardShortcut("d", modifiers: .command)
            Divider()
            Button("Refresh") { db.reloadAll() }.keyboardShortcut("r", modifiers: [.command, .shift])
            Button("New Database…") { openWindow(id: "db"); db.sheet = .newDatabase }
            Button("New Table…") { openWindow(id: "db"); db.sheet = .newTable }.disabled(db.currentDB == nil)
            Divider()
            Button("Export…") { if let d = db.currentDB { db.export(db: d, table: db.currentTable) } }
                .keyboardShortcut("e", modifiers: .command).disabled(db.currentDB == nil)
            Button("Import…") { db.importSQL(into: db.currentDB) }
            Divider()
            Button("Run Query") { db.tab = .query; db.runQuery() }
                .keyboardShortcut("r", modifiers: .command).disabled(db.queryText.trimmed.isEmpty)
        }
    }
}

@main
struct SzerverpanelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var panel = Panel()
    @StateObject private var database = DBModel()

    var body: some Scene {
        Window("Szerverpanel", id: "main") {
            ContentView().environmentObject(panel)
        }
        .defaultSize(width: 860, height: 560)
        .windowResizability(.contentMinSize)
        .commands { AppCommands(panel: panel, db: database) }

        Window("Database Manager", id: "db") {
            DatabaseWindow().environmentObject(database)
        }
        .defaultSize(width: 1120, height: 720)
    }
}
