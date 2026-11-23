import SwiftUI
import AppKit

/// First-run setup: installs the server packages with Homebrew and wires PHP and phpMyAdmin into Apache.
enum SetupState: Equatable {
    case ready
    case needsHomebrew
    case needsPackages([String])     // missing Homebrew formulas; empty means only the configuration is missing
    case running
}

enum Setup {
    static let marker = "# ---- Szerverpanel: PHP and phpMyAdmin ----"
    static let phpMyAdminDir = "\(Paths.brew)/share/phpmyadmin"
    static let phpModule = "\(Paths.brew)/opt/php/lib/httpd/modules/libphp.so"

    /// Homebrew formulas that are not installed yet.
    static func missingFormulas() -> [String] {
        let fm = FileManager.default
        var missing: [String] = []
        if !fm.isExecutableFile(atPath: Paths.httpd) { missing.append("httpd") }
        if !fm.isExecutableFile(atPath: Paths.php) { missing.append("php") }
        if !fm.isExecutableFile(atPath: Paths.mariadbd) { missing.append("mariadb") }
        if !fm.fileExists(atPath: phpMyAdminDir) { missing.append("phpmyadmin") }
        return missing
    }

    static func phpIsLinked() -> Bool {
        let conf = (try? String(contentsOfFile: Paths.httpdConf, encoding: .utf8)) ?? ""
        return conf.components(separatedBy: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("LoadModule php_module") }
    }

    /// Returns `httpd.conf` with PHP, phpMyAdmin, mod_rewrite and .htaccess support enabled. Safe to apply repeatedly.
    static func configuredApache(_ conf: String) -> String {
        var lines = conf.components(separatedBy: "\n")
        func trimmed(_ i: Int) -> String { lines[i].trimmingCharacters(in: .whitespaces) }
        let hasServerName = lines.indices.contains { trimmed($0).hasPrefix("ServerName ") }
        var port = "8080"
        for i in lines.indices where trimmed(i).hasPrefix("Listen ") {
            port = String(trimmed(i).dropFirst(7).split(separator: ":").last ?? "8080"); break
        }
        var inDocumentRoot = false
        var serverNameSet = hasServerName
        for i in lines.indices {
            let t = trimmed(i)
            if t.hasPrefix("#LoadModule rewrite_module") {
                lines[i] = lines[i].replacingOccurrences(of: "#LoadModule", with: "LoadModule")
            } else if t.hasPrefix("#ServerName ") && !serverNameSet {
                lines[i] = "ServerName localhost:\(port)"
                serverNameSet = true
            } else if t == "DirectoryIndex index.html" {
                lines[i] = lines[i].replacingOccurrences(of: "DirectoryIndex index.html", with: "DirectoryIndex index.php index.html")
            } else if t.hasPrefix("<Directory \"\(Paths.htdocs)\">") {
                inDocumentRoot = true
            } else if t.hasPrefix("</Directory>") {
                inDocumentRoot = false
            } else if inDocumentRoot && t.hasPrefix("AllowOverride None") {
                lines[i] = lines[i].replacingOccurrences(of: "AllowOverride None", with: "AllowOverride All")
            }
        }
        var result = lines.joined(separator: "\n")
        let phpLoaded = lines.indices.contains { trimmed($0).hasPrefix("LoadModule php_module") }
        if !phpLoaded && !result.contains(marker) {
            if !result.hasSuffix("\n") { result += "\n" }
            result += """

            \(marker)
            LoadModule php_module \(phpModule)
            <FilesMatch \\.php$>
                SetHandler application/x-httpd-php
            </FilesMatch>

            Alias /phpmyadmin \(phpMyAdminDir)
            <Directory \(phpMyAdminDir)/>
                Options Indexes FollowSymLinks MultiViews
                AllowOverride All
                Require local
            </Directory>

            """
        }
        return result
    }

    /// Gives phpMyAdmin a proper 32-byte cookie secret if it has none (or a too-short one).
    static func configuredPhpMyAdmin(_ conf: String) -> String {
        let secret = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let value = "$cfg['blowfish_secret'] = sodium_hex2bin('\(secret)');"
        var result = conf.replacingOccurrences(of: "$cfg['blowfish_secret'] = '';", with: value)
        if let re = try? NSRegularExpression(pattern: "\\$cfg\\['blowfish_secret'\\] = sodium_hex2bin\\('[0-9a-f]{1,63}'\\);") {
            let ns = result as NSString
            if let m = re.firstMatch(in: result, range: NSRange(location: 0, length: ns.length)) {
                result = ns.replacingCharacters(in: m.range, with: value)
            }
        }
        return result
    }

    static let welcomePage = """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <title>It works</title>
          <style>
            body { font: 16px -apple-system, sans-serif; max-width: 34rem; margin: 15vh auto; padding: 0 1rem; color: #1d1d1f; }
            @media (prefers-color-scheme: dark) { body { background: #1e1e1e; color: #f5f5f7; } }
            code { font-family: ui-monospace, monospace; }
          </style>
        </head>
        <body>
          <h1>It works</h1>
          <p>Apache is serving this page with PHP <?= PHP_VERSION ?>.</p>
          <p>Put your site in <code><?= htmlspecialchars(__DIR__) ?></code>.</p>
        </body>
        </html>

        """

    /// Writes the configuration files. Returns a description of each change made.
    static func applyConfiguration() throws -> [String] {
        let fm = FileManager.default
        var changes: [String] = []

        let conf = try String(contentsOfFile: Paths.httpdConf, encoding: .utf8)
        let newConf = configuredApache(conf)
        if newConf != conf {
            let backup = Paths.httpdConf + ".szerverpanel-backup"
            if !fm.fileExists(atPath: backup) { try conf.write(toFile: backup, atomically: true, encoding: .utf8) }
            try newConf.write(toFile: Paths.httpdConf, atomically: true, encoding: .utf8)
            changes.append("Enabled PHP and phpMyAdmin in httpd.conf (original saved as httpd.conf.szerverpanel-backup)")
        }

        if let pma = try? String(contentsOfFile: Paths.pmaConf, encoding: .utf8) {
            let hasGoodSecret = pma.range(of: "sodium_hex2bin\\('[0-9a-f]{64}'\\)", options: .regularExpression) != nil
            if !hasGoodSecret {
                let newPma = configuredPhpMyAdmin(pma)
                if newPma != pma {
                    try newPma.write(toFile: Paths.pmaConf, atomically: true, encoding: .utf8)
                    changes.append("Generated a cookie secret for phpMyAdmin")
                }
            }
        }

        try fm.createDirectory(atPath: Paths.htdocs, withIntermediateDirectories: true)
        let hasIndex = ["index.php", "index.html"].contains { fm.fileExists(atPath: "\(Paths.htdocs)/\($0)") }
        if !hasIndex {
            try welcomePage.write(toFile: "\(Paths.htdocs)/index.php", atomically: true, encoding: .utf8)
            changes.append("Added a welcome page to the web folder")
        }
        return changes
    }
}

extension Panel {
    /// Works out whether anything is missing. Called on every status refresh.
    func evaluateSetup() {
        guard setupState != .running else { return }
        let state: SetupState
        if !FileManager.default.isExecutableFile(atPath: Paths.brewBin) {
            state = .needsHomebrew
        } else {
            let missing = Setup.missingFormulas()
            state = (missing.isEmpty && Setup.phpIsLinked()) ? .ready : .needsPackages(missing)
        }
        if state != setupState { setupState = state }
        startSetupAutomatically()
    }

    private static var autoInstallStarted = false
    private static var autoHomebrewStarted = false

    /// On first launch the download starts by itself, once per launch; the banner button remains for retries.
    /// An existing installation that only lacks the PHP configuration is left for the user to confirm.
    private func startSetupAutomatically() {
        switch setupState {
        case .needsPackages(let missing) where !missing.isEmpty && !Panel.autoInstallStarted:
            Panel.autoInstallStarted = true
            runSetup()
        case .needsHomebrew where !Panel.autoHomebrewStarted:
            Panel.autoHomebrewStarted = true
            installHomebrew()
        default:
            break
        }
    }

    /// Homebrew's installer needs a password, so it runs in Terminal where the user can see and answer it.
    func installHomebrew() {
        let script = """
            #!/bin/bash
            echo "Szerverpanel needs Homebrew to install Apache, PHP and MariaDB."
            echo "This runs Homebrew's official installer from https://brew.sh"
            echo
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
            echo
            echo "Finished. Close this window and return to Szerverpanel."

            """
        let path = NSTemporaryDirectory() + "Install Homebrew.command"
        do {
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            Shell.open([path])
            add("Setup", "Opened Terminal to install Homebrew. Come back here when it finishes.")
        } catch {
            add("Setup", "Could not start the Homebrew installer: \(error.localizedDescription)", .error)
        }
    }

    /// Installs the missing packages and writes the configuration.
    func runSetup() {
        guard case .needsPackages(let missing) = setupState else { return }
        setupState = .running
        if !missing.isEmpty {
            add("Setup", "Installing \(missing.joined(separator: ", ")) with Homebrew. This can take several minutes.")
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var ok = true
            var started = false
            if !missing.isEmpty {
                let status = Shell.stream(Paths.brewBin, ["install"] + missing) { line in self.add("Setup", "  " + line) }
                if status != 0 {
                    self.add("Setup", "Homebrew could not install the packages. See the lines above.", .error)
                    ok = false
                }
            }
            if ok {
                do {
                    let changes = try Setup.applyConfiguration()
                    for c in changes { self.add("Setup", c) }
                    let test = Shell.run(Paths.httpd, ["-t"])
                    if test.status == 0 {
                        self.add("Setup", "Setup complete. Starting the servers.", .ok)
                        started = true
                    } else {
                        self.add("Setup", "Apache reports a configuration problem: \(test.out.trimmed)", .error)
                    }
                } catch {
                    self.add("Setup", "Could not write the configuration: \(error.localizedDescription)", .error)
                }
            }
            DispatchQueue.main.async {
                self.setupState = .ready
                self.evaluateSetup()
                self.reloadPHP()
                self.refresh()
                // After a fresh install, bring the servers up so the panel is ready to use.
                if started && !missing.isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.startAll() }
                }
            }
        }
    }
}
