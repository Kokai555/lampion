import Foundation

/// The Apache settings Lampion edits in httpd.conf.
struct ApacheSettings: Equatable {
    var port = 8080
    var documentRoot = Paths.htdocs
    var allowOverride = true          // .htaccess files
    var directoryListing = true       // Options Indexes
    var logLevel = "warn"
    var serverAdmin = ""
    var modules: [String: Bool] = [:] // feature id → on

    struct Feature: Identifiable {
        let id: String
        let title: String
        let detail: String
        let modules: [String]
    }

    static let features: [Feature] = [
        Feature(id: "rewrite", title: "URL rewriting", detail: "mod_rewrite. Needed by Laravel, WordPress permalinks and most .htaccess rules.", modules: ["rewrite"]),
        Feature(id: "headers", title: "Custom headers", detail: "mod_headers. Lets .htaccess set CORS and caching headers.", modules: ["headers"]),
        Feature(id: "deflate", title: "Gzip compression", detail: "mod_deflate. Compresses responses, as most live servers do.", modules: ["deflate"]),
        Feature(id: "expires", title: "Cache expiry", detail: "mod_expires. Honours ExpiresActive and ExpiresByType rules.", modules: ["expires"]),
        Feature(id: "proxy", title: "Reverse proxy", detail: "mod_proxy, mod_proxy_http and mod_proxy_wstunnel. Forward requests to Node, Vite and similar dev servers.", modules: ["proxy", "proxy_http", "proxy_wstunnel"]),
        Feature(id: "vhost_alias", title: "Dynamic virtual hosts", detail: "mod_vhost_alias. Map host names to folders with VirtualDocumentRoot.", modules: ["vhost_alias"]),
        Feature(id: "info", title: "Server info page", detail: "mod_info. Shows the loaded configuration at a /server-info handler you configure.", modules: ["info"]),
    ]

    static let logLevels = ["emerg", "alert", "crit", "error", "warn", "notice", "info", "debug"]
}

enum ApacheConfig {
    static var path: String { Paths.httpdConf }

    static func load() throws -> ApacheSettings { parse(try ConfigFile.read(path)) }

    /// `Listen [addr:]port [protocol]` → (address prefix incl. colon, port, protocol suffix incl. space).
    static func splitListen(_ value: String) -> (prefix: String, port: Int?, suffix: String) {
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let addr = parts.first.map(String.init) ?? ""
        let suffix = parts.count > 1 ? " " + parts[1] : ""
        if let colon = addr.range(of: ":", options: .backwards) {
            return (String(addr[..<colon.upperBound]), Int(addr[colon.upperBound...]), suffix)
        }
        return ("", Int(addr), suffix)
    }

    static func parse(_ text: String) -> ApacheSettings {
        let conf = ApacheConfText(text)
        var s = ApacheSettings()
        if let listen = conf.value("Listen"), let p = splitListen(listen).port { s.port = p }
        if let root = conf.value("DocumentRoot") { s.documentRoot = root }
        if let o = conf.directoryValue(s.documentRoot, "AllowOverride") { s.allowOverride = o.lowercased() != "none" }
        if let o = conf.directoryValue(s.documentRoot, "Options") {
            s.directoryListing = o.split(separator: " ").contains { $0 == "Indexes" || $0 == "+Indexes" }
        } else {
            s.directoryListing = false
        }
        if let l = conf.value("LogLevel") { s.logLevel = String(l.split(separator: " ").first ?? "warn").lowercased() }
        s.serverAdmin = conf.value("ServerAdmin") ?? ""
        for f in ApacheSettings.features { s.modules[f.id] = f.modules.allSatisfy(conf.moduleEnabled) }
        return s
    }

    /// Current DocumentRoot (falls back to Homebrew's default).
    static func documentRoot() -> String {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return Paths.htdocs }
        return ApacheConfText(text).value("DocumentRoot") ?? Paths.htdocs
    }

    /// Applies only the settings that differ from what the file says now, so everything else in it is left exactly as it was.
    static func apply(_ s: ApacheSettings, to text: String) -> String {
        let old = parse(text)
        guard s != old else { return text }
        var conf = ApacheConfText(text)

        if s.port != old.port {
            let listen = splitListen(conf.value("Listen") ?? "")
            conf.set("Listen", "\(listen.prefix)\(s.port)\(listen.suffix)")
            if let name = conf.value("ServerName"), name.hasSuffix(":\(old.port)") {
                conf.set("ServerName", String(name.dropLast(String(old.port).count)) + String(s.port))
            }
        }
        if s.documentRoot != old.documentRoot {
            conf.set("DocumentRoot", "\"\(s.documentRoot)\"")
            conf.renameDirectory(old.documentRoot, to: s.documentRoot)
        }
        if s.allowOverride != old.allowOverride {
            conf.setDirectoryValue(s.documentRoot, "AllowOverride", s.allowOverride ? "All" : "None")
        }
        if s.directoryListing != old.directoryListing {
            var options = (conf.directoryValue(s.documentRoot, "Options") ?? "FollowSymLinks")
                .split(separator: " ").map(String.init)
                .filter { !["Indexes", "+Indexes", "-Indexes", "None"].contains($0) }
            // Options must either all carry +/- or none of them do.
            let relative = !options.isEmpty && options.allSatisfy { $0.hasPrefix("+") || $0.hasPrefix("-") }
            if s.directoryListing { options.insert(relative ? "+Indexes" : "Indexes", at: 0) }
            else if relative { options.append("-Indexes") }
            if options.isEmpty { options = ["None"] }
            conf.setDirectoryValue(s.documentRoot, "Options", options.joined(separator: " "))
        }
        if s.logLevel != old.logLevel {
            // Keep per-module levels such as "rewrite:trace3".
            let rest = (conf.value("LogLevel") ?? "").split(separator: " ").dropFirst().joined(separator: " ")
            conf.set("LogLevel", rest.isEmpty ? s.logLevel : "\(s.logLevel) \(rest)")
        }
        if s.serverAdmin.trimmed != old.serverAdmin {
            // An empty field removes the address from Apache's error pages.
            if s.serverAdmin.trimmed.isEmpty { conf.unset("ServerAdmin") } else { conf.set("ServerAdmin", s.serverAdmin.trimmed) }
        }
        for f in ApacheSettings.features where (s.modules[f.id] ?? false) != (old.modules[f.id] ?? false) {
            let on = s.modules[f.id] ?? false
            for m in f.modules { conf.setModule(m, enabled: on) }
        }
        return conf.text
    }

    /// Problems that stop the settings from being saved.
    static func validate(_ s: ApacheSettings) -> [String] {
        var problems: [String] = []
        if !(1024...65535).contains(s.port) {
            problems.append("The port must be between 1024 and 65535. Lower ports need administrator rights.")
        }
        var isDir: ObjCBool = false
        if !s.documentRoot.hasPrefix("/") || s.documentRoot.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty {
            problems.append("The web folder must be a full path to a folder, not the whole disk.")
        } else if !FileManager.default.fileExists(atPath: s.documentRoot, isDirectory: &isDir) || !isDir.boolValue {
            problems.append("The web folder does not exist: \(s.documentRoot)")
        }
        return problems
    }

    /// Writes httpd.conf after Apache has accepted a test copy. Throws Apache's message if it is rejected.
    static func save(_ s: ApacheSettings) throws {
        let current = try ConfigFile.read(path)
        let updated = apply(s, to: current)
        guard updated != current else { return }
        try check(updated)
        try ConfigFile.write(updated, to: path)
    }

    /// Runs `httpd -t` on a copy of the configuration.
    static func check(_ text: String) throws {
        let tmp = (path as NSString).deletingLastPathComponent + "/.httpd.lampion-test.conf"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        do { try text.write(toFile: tmp, atomically: true, encoding: .utf8) } catch {
            throw ConfigFile.Problem("Could not test the configuration: \(error.localizedDescription)")
        }
        let r = Shell.run(Paths.httpd, ["-t", "-f", tmp])
        if r.status != 0 {
            let lines = r.out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            throw ConfigFile.Problem("Apache rejected the new configuration, so nothing was changed.\n\n" + lines.suffix(4).joined(separator: "\n"))
        }
    }
}
