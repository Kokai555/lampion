import SwiftUI
import AppKit

/// Önteszt: open -a Szerverpanel --args --selftest
extension Panel {
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

            // Setup: the Apache configuration rewrite, tested on a copy of Homebrew's stock httpd.conf.
            let live = (try? String(contentsOfFile: Paths.httpdConf, encoding: .utf8)) ?? ""
            check(Setup.configuredApache(live) == live, "Setup leaves an already configured httpd.conf unchanged")
            let stockPath = (try? FileManager.default.contentsOfDirectory(atPath: "\(Paths.brew)/etc/httpd"))?
                .filter { $0.hasPrefix("httpd.conf.bak") || $0 == "httpd.conf.szerverpanel-backup" }.sorted().first
            if let stockPath, let stock = try? String(contentsOfFile: "\(Paths.brew)/etc/httpd/\(stockPath)", encoding: .utf8) {
                let configured = Setup.configuredApache(stock)
                check(configured.contains("LoadModule php_module") && configured.contains("Alias /phpmyadmin")
                      && configured.contains("DirectoryIndex index.php index.html") && configured.contains("\nLoadModule rewrite_module")
                      && configured.contains("ServerName localhost:8080"), "Setup enables PHP, phpMyAdmin and mod_rewrite in a stock httpd.conf")
                check(Setup.configuredApache(configured) == configured, "Setup can be applied twice without further changes")
                let tmp = NSTemporaryDirectory() + "szerverpanel-httpd-test.conf"
                try? configured.write(toFile: tmp, atomically: true, encoding: .utf8)
                let syntax = Shell.run(Paths.httpd, ["-t", "-f", tmp])
                check(syntax.status == 0, "Apache accepts the configuration Setup writes")
                try? FileManager.default.removeItem(atPath: tmp)
            }
            let pma = Setup.configuredPhpMyAdmin("$cfg['blowfish_secret'] = '';")
            check(pma.range(of: "sodium_hex2bin\\('[0-9a-f]{64}'\\)", options: .regularExpression) != nil, "Setup generates a 32-byte phpMyAdmin secret")
            check(onMain { self.setupState == .ready }, "No setup banner when everything is installed")
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
}
