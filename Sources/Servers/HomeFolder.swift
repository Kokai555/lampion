import Foundation

/// Moves the sites, the databases and the logs into one folder, ~/Lampion (like XAMPP keeps everything in one place):
///
///     ~/Lampion/www         sites (Apache's DocumentRoot)
///     ~/Lampion/databases   MariaDB's data folder
///     ~/Lampion/logs        apache/, mariadb/, php/
///     ~/Lampion/backups     where exports go by default
///
/// The old files are copied, never deleted. If anything goes wrong the old configuration is put back.
enum HomeFolder {
    struct Problem: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
    }

    static var isMoved: Bool { Paths.usesHome }

    private static func isEmptyDir(_ path: String) -> Bool {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return items.allSatisfy { $0 == ".DS_Store" }
    }

    private static func databases() -> Set<String>? {
        let r = Shell.run("\(Paths.brew)/bin/mariadb", ["-N", "-e", "SHOW DATABASES"])
        guard r.status == 0 else { return nil }
        return Set(r.out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    private static func waitUntil(_ m: Module, running: Bool, seconds: Double = 20) -> Bool {
        let tries = Int(seconds / 0.5)
        for _ in 0..<tries {
            let s = Panel.probeAll()[m] ?? ModuleStatus()
            if running ? (s.running && !s.ports.isEmpty) : !s.running { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    /// Replaces the file path of every active `CustomLog` line, keeping its format argument.
    static func settingCustomLog(_ path: String, in text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("CustomLog ") else { return line }
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            var rest = String(t.dropFirst(10)).trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("\"") {
                rest = String(rest.dropFirst())
                if let close = rest.firstIndex(of: "\"") { rest = String(rest[rest.index(after: close)...]) }
            } else {
                rest = String(rest.drop { $0 != " " })
            }
            return indent + "CustomLog \"\(path)\"" + rest
        }.joined(separator: "\n")
    }

    /// Does the move. Runs on Panel's action queue; `log` reports progress. `startAfter` starts both servers at the end
    /// (otherwise only those that were running).
    static func move(startAfter: Bool, log: (String) -> Void) throws {
        let fm = FileManager.default
        let home = Paths.home
        let www = Paths.homeWWW, data = Paths.homeDatabases, logs = Paths.homeLogs, backups = Paths.homeBackups
        let oldData = Locations.refresh().mysqlData          // symlinks resolved
        let oldRoot = ApacheConfig.documentRoot()
        // Homebrew always starts MariaDB with this path, so it becomes a link to ~/Lampion/databases.
        let brewData = Paths.mysqlData_default
        let parked = brewData + ".lampion-old"
        guard oldData != data else { throw Problem("The databases are already in \(data).") }
        guard oldData == brewData else {
            throw Problem("MariaDB uses a custom data folder (\(oldData)), so Lampion leaves it where it is.")
        }
        if fm.fileExists(atPath: parked) { throw Problem("\(parked) already exists. Move it away, then try again.") }
        if fm.fileExists(atPath: data) && !isEmptyDir(data) {
            throw Problem("\(data) already contains files. Move or empty it, then try again.")
        }

        let status = Panel.probeAll()
        let wasRunning = Set(Module.allCases.filter { status[$0]?.running == true })
        let before = wasRunning.contains(.mysql) ? databases() : nil

        // Keep the current configuration to put back if anything fails.
        let httpdBefore = try ConfigFile.read(Paths.httpdConf)
        let cnfBefore = try? String(contentsOfFile: MariaDBConfig.path, encoding: .utf8)
        let iniPath = PHPConfig.iniPathCached
        let iniBefore = iniPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }

        var parkedOld = false        // the real data folder was renamed to .lampion-old
        var copiedData = false       // ~/Lampion/databases was filled by this attempt
        func restoreConfiguration() {
            if parkedOld {
                if (try? fm.destinationOfSymbolicLink(atPath: brewData)) != nil {
                    try? fm.removeItem(atPath: brewData)        // the link only, never the data
                }
                if !fm.fileExists(atPath: brewData) { try? fm.moveItem(atPath: parked, toPath: brewData) }
            }
            // The half-made copy would block a retry. The original is back in place, so the copy can go.
            var isDir: ObjCBool = false
            if copiedData, fm.fileExists(atPath: brewData, isDirectory: &isDir), isDir.boolValue,
               (try? fm.destinationOfSymbolicLink(atPath: brewData)) == nil {
                try? fm.removeItem(atPath: data)
            }
            try? httpdBefore.write(toFile: Paths.httpdConf, atomically: true, encoding: .utf8)
            if let cnfBefore { try? cnfBefore.write(toFile: MariaDBConfig.path, atomically: true, encoding: .utf8) }
            else { try? fm.removeItem(atPath: MariaDBConfig.path) }
            if let iniPath, let iniBefore { try? iniBefore.write(toFile: iniPath, atomically: true, encoding: .utf8) }
            Locations.refresh()
        }
        func startAgain(_ modules: Set<Module>) {
            for m in Module.allCases where modules.contains(m) {
                Shell.run(Paths.brewBin, ["services", "start", m.formula])
                _ = waitUntil(m, running: true)
            }
        }

        // 1. Folders
        log("Creating \(home)")
        for dir in [www, data, logs + "/apache", logs + "/mariadb", logs + "/php", backups] {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        // 2. Stop the servers so the database files are complete when copied.
        for m in [Module.apache, .mysql] where status[m]?.loaded == true || status[m]?.running == true {
            log("Stopping \(m == .apache ? "Apache" : "MariaDB")…")
            Shell.run(Paths.brewBin, ["services", "stop", m.formula])
            guard waitUntil(m, running: false) else {
                startAgain(wasRunning)
                throw Problem("\(m == .apache ? "Apache" : "MariaDB") did not stop, so nothing was moved.")
            }
        }

        do {
            // 3. Copy the databases and the sites.
            log("Copying the databases from \(oldData)…")
            let copy = Shell.run("/usr/bin/ditto", [oldData, data])
            copiedData = true
            guard copy.status == 0 else { throw Problem("Copying the databases failed: \(copy.out.trimmed)") }
            for leftover in (try? fm.contentsOfDirectory(atPath: data)) ?? [] where leftover.hasSuffix(".pid") {
                try? fm.removeItem(atPath: data + "/" + leftover)
            }
            if isEmptyDir(www) && fm.fileExists(atPath: oldRoot) && !oldRoot.hasPrefix(home + "/") {
                log("Copying the sites from \(oldRoot)…")
                let sites = Shell.run("/usr/bin/ditto", [oldRoot, www])
                guard sites.status == 0 else { throw Problem("Copying the sites failed: \(sites.out.trimmed)") }
            }

            // 4. Point the servers at the new places.
            log("Updating Apache, MariaDB and PHP settings…")
            var apache = ApacheConfig.parse(httpdBefore)
            apache.documentRoot = www
            var conf = ApacheConfText(ApacheConfig.apply(apache, to: httpdBefore))
            conf.set("ErrorLog", "\"\(logs)/apache/error_log\"")
            let httpdNew = settingCustomLog("\(logs)/apache/access_log", in: conf.text)
                .replacingOccurrences(of: "\"\(oldRoot)/cgi-bin", with: "\"\(www)/cgi-bin")
            try ApacheConfig.check(httpdNew)
            try ConfigFile.write(httpdNew, to: Paths.httpdConf)

            log("Linking \(brewData) to \(data)…")
            try fm.moveItem(atPath: brewData, toPath: parked)
            parkedOld = true
            try fm.createSymbolicLink(atPath: brewData, withDestinationPath: data)
            try MariaDBConfig.setLocation(errorLog: "\(logs)/mariadb/mariadb.err")
            let check = Shell.run(Paths.mariadbd, ["--help", "--verbose"])
            guard check.status == 0 else {
                throw Problem("MariaDB rejected the new data folder: " + (check.out.split(separator: "\n").last { $0.contains("ERROR") }.map(String.init) ?? check.out.trimmed))
            }
            Locations.refresh()
            // Slow / all-queries logs follow the logs to ~/Lampion/logs/mariadb.
            try MariaDBConfig.save(MariaDBConfig.load())

            if let iniPath, let iniBefore {
                var php = PHPConfig.parse(iniBefore)
                php.separateErrorLog = true
                // Force the new path even if a separate log was already on.
                var ini = IniText(PHPConfig.apply(php, to: iniBefore))
                ini.set("error_log", Paths.phpErrorLog)
                fm.createFile(atPath: Paths.phpErrorLog, contents: nil)
                try ConfigFile.write(ini.text, to: iniPath)
            }

            // 5. Start again and check that every database is still there.
            let toStart: Set<Module> = startAfter ? Set(Module.allCases) : wasRunning
            do {   // always start MariaDB once to prove it works from the new folder
                log("Starting MariaDB from \(data)…")
                Shell.run(Paths.brewBin, ["services", "start", Module.mysql.formula])
                guard waitUntil(.mysql, running: true, seconds: 30) else {
                    throw Problem("MariaDB did not start from the new folder.")
                }
                // It must really run from the new folder (not just show the same databases).
                let dir = Shell.run("\(Paths.brew)/bin/mariadb", ["-N", "-e", "SELECT @@datadir"]).out.trimmed
                guard URL(fileURLWithPath: dir).resolvingSymlinksInPath().path == data else {
                    throw Problem("MariaDB is still using \(dir) instead of \(data).")
                }
                let after = databases() ?? []
                if let before, !before.isSubset(of: after) {
                    throw Problem("After the move these databases were missing: \(before.subtracting(after).sorted().joined(separator: ", ")).")
                }
                guard after.contains("mysql") else { throw Problem("MariaDB started, but its system database was not found.") }
                if !toStart.contains(.mysql) {
                    Shell.run(Paths.brewBin, ["services", "stop", Module.mysql.formula])
                }
            }
            if toStart.contains(.apache) {
                log("Starting Apache from \(www)…")
                Shell.run(Paths.brewBin, ["services", "start", Module.apache.formula])
                guard waitUntil(.apache, running: true) else { throw Problem("Apache did not start with the new web folder.") }
            }
        } catch {
            log("Something went wrong — putting the old settings back.")
            for m in [Module.apache, .mysql] { Shell.run(Paths.brewBin, ["services", "stop", m.formula]) }
            restoreConfiguration()
            startAgain(wasRunning)
            throw error
        }

        let readme = """
            Lampion keeps everything for your local server here.

            www/        Your sites. http://localhost serves this folder.
            databases/  MariaDB's data files. Don't copy or edit these by hand while MariaDB runs;
                        use Export in Lampion's database manager for backups.
            logs/       apache/, mariadb/ and php/ logs. Lampion's Logs pane shows them live.
            backups/    Database exports are saved here by default.

            Before the move the files were in:
              databases: \(oldData)  (now kept as \(parked))
              sites:     \(oldRoot)
            \(brewData) is now a link to databases/, because Homebrew always starts MariaDB with that path.
            The old copies were kept, not deleted. Remove them once everything works.

            """
        try? readme.write(toFile: home + "/README.txt", atomically: true, encoding: .utf8)
        log("Done. The old copies are kept in \(parked) and \(oldRoot); delete them once you are sure everything works.")
    }
}

extension Panel {
    /// Moves everything into ~/Lampion (see HomeFolder). `startAfter`: start both servers afterwards (used after first setup).
    func moveToLampionHome(startAfter: Bool = false) {
        guard !movingHome else { return }
        movingHome = true
        busy = Set(Module.allCases)
        add("Panel", "Moving the sites, databases and logs to \(Paths.home)…")
        actions.async {
            let result = Result { try HomeFolder.move(startAfter: startAfter) { self.add("Move", $0) } }
            DispatchQueue.main.async {
                self.busy.removeAll()
                self.generation += 1
                self.movingHome = false
                switch result {
                case .success: self.add("Panel", "Everything is now in \(Paths.home)", .ok)
                case .failure(let e): self.add("Panel", "The move did not complete: \(e.localizedDescription)", .error)
                }
                self.reloadConfig()
                self.refresh()
            }
        }
    }
}
