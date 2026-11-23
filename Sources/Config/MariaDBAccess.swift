import Foundation

/// How other programs log in to the local MariaDB. Like XAMPP: `root` with no password, but only from this Mac
/// (root@localhost, root@127.0.0.1, root@::1). Homebrew's default is socket login for the macOS user only.
enum MariaDBAccess {
    static let client = "\(Paths.brew)/bin/mariadb"

    /// True / false once known; nil when MariaDB is not running.
    static func rootWithoutPassword() -> Bool? {
        let probe = Shell.run(client, ["--protocol=TCP", "-h", "127.0.0.1", "-P", String(MariaDBConfig.effectivePort()),
                                       "-u", "root", "--password=", "-N", "-e", "SELECT 1"])
        if probe.status == 0 { return true }
        if probe.out.contains("1045") || probe.out.contains("1698") { return false }   // access denied
        return nil
    }

    /// Runs as the macOS user (socket login), who has full rights on Homebrew's MariaDB.
    static func setRootWithoutPassword(_ on: Bool) throws {
        let sql = on ? """
            ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('') OR unix_socket;
            CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY '';
            GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;
            CREATE USER IF NOT EXISTS 'root'@'::1' IDENTIFIED BY '';
            GRANT ALL PRIVILEGES ON *.* TO 'root'@'::1' WITH GRANT OPTION;
            FLUSH PRIVILEGES;
            """ : """
            ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING 'invalid' OR unix_socket;
            DROP USER IF EXISTS 'root'@'127.0.0.1';
            DROP USER IF EXISTS 'root'@'::1';
            FLUSH PRIVILEGES;
            """
        let r = Shell.run(client, ["-e", sql])
        guard r.status == 0 else {
            throw ConfigFile.Problem("MariaDB did not accept the change. Is it running?\n\n" + r.out.trimmed)
        }
    }

    /// Like XAMPP: on the first launch with MariaDB running, root gets an empty password (from this Mac only).
    /// Done once; after that the user's choice in MariaDB settings stands.
    static func enableByDefault(log: (String) -> Void) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Prefs.rootWithoutPasswordChosen), let current = rootWithoutPassword() else { return }
        defaults.set(true, forKey: Prefs.rootWithoutPasswordChosen)
        guard !current else { return }
        do {
            try setRootWithoutPassword(true)
            log("Programs can now connect as root with no password, from this Mac only. Change this in MariaDB settings.")
        } catch {
            log("Could not set up the root login: \(error.localizedDescription)")
        }
    }

    // Connection snippets

    struct Snippet: Identifiable {
        let id: String
        let title: String
        let text: String
    }

    static func snippets(database db: String, port: Int) -> [Snippet] {
        let d = db.trimmed.isEmpty ? "your_database" : db.trimmed
        return [
            Snippet(id: "pdo", title: "PHP (PDO)",
                    text: "$pdo = new PDO('mysql:host=127.0.0.1;port=\(port);dbname=\(d);charset=utf8mb4', 'root', '');"),
            Snippet(id: "mysqli", title: "PHP (mysqli)",
                    text: "$db = new mysqli('127.0.0.1', 'root', '', '\(d)', \(port));"),
            Snippet(id: "laravel", title: "Laravel (.env)",
                    text: "DB_CONNECTION=mysql\nDB_HOST=127.0.0.1\nDB_PORT=\(port)\nDB_DATABASE=\(d)\nDB_USERNAME=root\nDB_PASSWORD="),
            Snippet(id: "prisma", title: "Prisma (.env)",
                    text: "DATABASE_URL=\"mysql://root@127.0.0.1:\(port)/\(d)\""),
            Snippet(id: "node", title: "Node.js (mysql2)",
                    text: "const db = await mysql.createConnection({ host: '127.0.0.1', port: \(port), user: 'root', password: '', database: '\(d)' });"),
            Snippet(id: "python", title: "Python",
                    text: "db = mysql.connector.connect(host=\"127.0.0.1\", port=\(port), user=\"root\", password=\"\", database=\"\(d)\")"),
            Snippet(id: "jdbc", title: "Java (JDBC)",
                    text: "jdbc:mariadb://127.0.0.1:\(port)/\(d)?user=root&password="),
            Snippet(id: "url", title: "Connection URL",
                    text: "mysql://root@127.0.0.1:\(port)/\(d)"),
        ]
    }
}
