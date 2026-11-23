import Foundation

/// phpMyAdmin's sign-in. Homebrew's MariaDB lets your macOS user in through the socket without a password
/// (unix_socket), and Apache runs as that same user, so phpMyAdmin can sign in by itself.
enum PhpMyAdminConfig {
    static var path: String { Paths.pmaConf }
    private static let marker = "// Lampion: automatic sign-in"

    /// True when phpMyAdmin opens without a login page.
    static func autoLogin(in text: String) -> Bool {
        text.range(of: #"\['auth_type'\]\s*=\s*'config'"#, options: .regularExpression) != nil
    }

    static func setAutoLogin(_ on: Bool, user: String, in text: String) -> String {
        let quoted = user.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        var lines = text.components(separatedBy: "\n").filter { !$0.contains(marker) }
        func replace(_ key: String, _ value: String) -> Int? {
            guard let i = lines.firstIndex(where: {
                !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") && $0.contains("['\(key)']") && $0.contains("=")
            }) else { return nil }
            lines[i] = "$cfg['Servers'][$i]['\(key)'] = \(value);"
            return i
        }
        let auth = replace("auth_type", on ? "'config'" : "'cookie'")
        _ = replace("AllowNoPassword", on ? "true" : "false")
        if on {
            let at = (auth ?? lines.lastIndex { $0.contains("$i++") } ?? lines.count - 1) + 1
            lines.insert(contentsOf: [
                "$cfg['Servers'][$i]['user'] = '\(quoted)'; \(marker)",
                "$cfg['Servers'][$i]['password'] = ''; \(marker)",
            ], at: min(at, lines.count))
        }
        return lines.joined(separator: "\n")
    }

    /// Like XAMPP: phpMyAdmin opens without a login page unless the user has turned that off. Done once, at launch.
    static func enableByDefault(log: (String) -> Void) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Prefs.phpMyAdminSignInChosen),
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        defaults.set(true, forKey: Prefs.phpMyAdminSignInChosen)
        guard !autoLogin(in: text) else { return }
        do {
            try save(autoLogin: true)
            log("phpMyAdmin now signs in automatically as \(NSUserName()). Turn this off in MariaDB settings.")
        } catch {
            log("Could not set up phpMyAdmin's automatic sign-in: \(error.localizedDescription)")
        }
    }

    /// Changes the setting in config.inc.php after PHP has checked the result.
    static func save(autoLogin on: Bool) throws {
        let current = try ConfigFile.read(path)
        let updated = setAutoLogin(on, user: NSUserName(), in: current)
        guard updated != current else { return }
        let tmp = NSTemporaryDirectory() + "lampion-pma-test.php"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try updated.write(toFile: tmp, atomically: true, encoding: .utf8)
        let lint = Shell.run(Paths.php, ["-l", tmp])
        guard lint.status == 0 else {
            throw ConfigFile.Problem("The phpMyAdmin configuration would not be valid, so nothing was changed.\n\n" + lint.out.trimmed)
        }
        try ConfigFile.write(updated, to: path)
    }
}
