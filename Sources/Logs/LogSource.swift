import Foundation

/// A log the Logs pane can show.
enum LogSource: String, CaseIterable, Identifiable, Hashable {
    case activity, apacheError, apacheAccess, php, mariadb, mariadbSlow, mariadbGeneral

    var id: String { rawValue }

    var title: String {
        switch self {
        case .activity: return "Lampion Activity"
        case .apacheError: return "Apache Errors"
        case .apacheAccess: return "Apache Requests"
        case .php: return "PHP Errors"
        case .mariadb: return "MariaDB"
        case .mariadbSlow: return "Slow Queries"
        case .mariadbGeneral: return "All Queries"
        }
    }

    var symbol: String {
        switch self {
        case .activity: return "bolt.horizontal"
        case .apacheError: return "exclamationmark.triangle"
        case .apacheAccess: return "arrow.left.arrow.right"
        case .php: return "chevron.left.forwardslash.chevron.right"
        case .mariadb: return "cylinder.split.1x2"
        case .mariadbSlow: return "tortoise"
        case .mariadbGeneral: return "list.bullet.rectangle"
        }
    }

    var group: String {
        switch self {
        case .activity: return "Lampion"
        case .apacheError, .apacheAccess, .php: return "Web Server"
        case .mariadb, .mariadbSlow, .mariadbGeneral: return "Database"
        }
    }

    /// File behind the log; nil for Lampion's own activity log.
    var path: String? {
        switch self {
        case .activity: return nil
        case .apacheError: return Paths.apacheErrorLog
        case .apacheAccess: return Paths.apacheAccessLog
        case .php: return PHPConfig.currentErrorLog ?? Paths.phpErrorLog
        case .mariadb: return Paths.mysqlErrorLog
        case .mariadbSlow: return MariaDBConfig.slowLog
        case .mariadbGeneral: return MariaDBConfig.generalLog
        }
    }

    /// Shown when the file does not exist yet.
    var missingHint: String {
        switch self {
        case .php: return "Turn on “Separate PHP error log” in PHP settings. Until then PHP errors go to Apache Errors."
        case .mariadbSlow: return "Turn on the slow query log in MariaDB settings."
        case .mariadbGeneral: return "Turn on “Log every query” in MariaDB settings."
        default: return "The file is created the first time the server writes to it."
        }
    }

    /// Works out how serious a line is from the usual markers of each log format.
    func level(of line: String) -> LogEntry.Level {
        switch self {
        case .apacheAccess:
            // … "GET / HTTP/1.1" 404 196
            if let quote = line.range(of: "\" ", options: .backwards) {
                let code = line[quote.upperBound...].prefix(3)
                if code.hasPrefix("5") { return .error }
                if code.hasPrefix("4") { return .warn }
            }
            return .info
        case .mariadbSlow, .mariadbGeneral:
            return .info
        default:
            let l = line.lowercased()
            if l.contains(":error]") || l.contains(":emerg]") || l.contains(":crit]") || l.contains(":alert]")
                || l.contains("[error]") || l.contains("fatal error") || l.contains("parse error") || l.contains("php error") {
                return .error
            }
            if l.contains(":warn]") || l.contains("[warning]") || l.contains("php warning") || l.contains("php deprecated")
                || l.contains("php notice") {
                return .warn
            }
            return .info
        }
    }
}

struct LogLine: Identifiable, Equatable {
    let id: Int
    let text: String
    var level: LogEntry.Level
    var time: String? = nil
    var tag: String? = nil
    var message: String? = nil
}

extension LogSource {
    private static var regexCache: [String: NSRegularExpression] = [:]
    private static let regexLock = NSLock()

    private static func firstMatch(_ pattern: String, in s: String) -> [String]? {
        regexLock.lock()
        let cached = regexCache[pattern] ?? (try? NSRegularExpression(pattern: pattern))
        regexCache[pattern] = cached
        regexLock.unlock()
        guard let re = cached,
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
    }

    private static let clock = try! NSRegularExpression(pattern: "(?<![0-9])[0-9]{2}:[0-9]{2}:[0-9]{2}")
    private static func clockTime(_ s: String) -> String? {
        guard let m = clock.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range, in: s) else { return nil }
        return String(s[r])
    }

    /// Splits a line into time, tag and message for the known log formats.
    func parse(_ text: String, id: Int) -> LogLine {
        let level = level(of: text)
        var line = LogLine(id: id, text: text, level: level)
        switch self {
        case .apacheError:
            // [Mon Nov 23 12:06:52.891929 2026] [mpm_prefork:notice] [pid 81322] AH00163: message
            if let m = Self.firstMatch("^\\[([^\\]]+)\\] \\[([^:\\]]*):([a-z0-9]+)\\](?: \\[pid [^\\]]+\\])?(?: \\[client [^\\]]+\\])? (?:AH\\d+: )?(.*)$", in: text) {
                line.time = Self.clockTime(m[1]); line.tag = m[2].isEmpty ? m[3] : m[2]; line.message = m[4]
            }
        case .apacheAccess:
            // 127.0.0.1 - - [23/Nov/2026:12:00:00 +0100] "GET / HTTP/1.1" 200 45
            if let m = Self.firstMatch("^(\\S+) \\S+ \\S+ \\[([^\\]]+)\\] \"([^\"]*)\" (\\d{3}) (\\S+)(.*)$", in: text) {
                let request = m[3].replacingOccurrences(of: " HTTP/1.1", with: "").replacingOccurrences(of: " HTTP/2.0", with: "")
                line.level = m[4].hasPrefix("5") ? .error : m[4].hasPrefix("4") ? .warn : .info
                line.time = Self.clockTime(m[2]); line.tag = m[4]; line.message = request + (m[5] == "-" ? "" : "  ·  \(m[5]) B") + "  ·  " + m[1]
            }
        case .mariadb:
            // 2026-11-23 14:34:54 0 [Warning] message
            if let m = Self.firstMatch("^\\d{4}-\\d{2}-\\d{2}\\s+(\\d{1,2}:\\d{2}:\\d{2})\\s+\\d+\\s+\\[([A-Za-z]+)\\]\\s*(.*)$", in: text) {
                line.time = m[1]; line.tag = m[2]; line.message = m[3]
            }
        case .php:
            // [23-Nov-2026 14:00:00 Europe/Budapest] PHP Warning:  message
            if let m = Self.firstMatch("^\\[([^\\]]+)\\] (?:PHP )?([A-Za-z ]+?):\\s+(.*)$", in: text) {
                line.time = Self.clockTime(m[1]); line.tag = m[2]; line.message = m[3]
            }
        default:
            break
        }
        return line
    }
}

/// Follows a log file like `tail -f`: loads the end of the file, then adds new lines as they are written.
final class LogTailer: ObservableObject {
    @Published private(set) var lines: [LogLine] = []
    @Published private(set) var exists = true
    @Published private(set) var size: UInt64 = 0

    static let maxLines = 5000
    private static let initialBytes: UInt64 = 1 << 20

    private var source: LogSource?          // used on `queue`
    private var activeSource: LogSource?    // used on the main thread
    private var offset: UInt64 = 0
    private var nextID = 0
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "lampion.logtail")

    func follow(_ source: LogSource) {
        stop()
        activeSource = source
        lines = []
        queue.async {
            self.source = source
            self.offset = 0
            self.inode = 0
            self.partialData = Data()
            self.poll(initial: true)
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.poll(initial: false) }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Re-reads the file from scratch.
    func reload() { if let activeSource { follow(activeSource) } }

    /// Empties the log file.
    func truncate() throws {
        guard let path = activeSource?.path else { return }
        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try h.truncate(atOffset: 0)
        try h.close()
        reload()
    }

    private var inode: UInt64 = 0
    private var partialData = Data()

    private func poll(initial: Bool) {
        guard let source, let path = source.path else { return }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else {
            offset = 0; partialData = Data(); inode = 0
            DispatchQueue.main.async {
                guard self.activeSource == source else { return }
                if self.exists { self.exists = false }
                if !self.lines.isEmpty { self.lines = [] }
            }
            return
        }
        let node = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        // Start over when the file was truncated or replaced (log rotation), or when far too much is new to show it all.
        var reset = initial || size < offset || (inode != 0 && node != inode) || size - offset > Self.initialBytes
        if offset == 0 && size > Self.initialBytes { reset = true }
        inode = node
        if reset {
            offset = size > Self.initialBytes ? size - Self.initialBytes : 0
            partialData = Data()
        }
        guard size > offset || reset else { return }

        var data = Data()
        if size > offset, let h = FileHandle(forReadingAtPath: path) {
            try? h.seek(toOffset: offset)
            data = h.readData(ofLength: Int(size - offset))
            try? h.close()
            offset += UInt64(data.count)
        }
        var chunk = partialData + data
        // Starting part-way into the file: drop the cut-off first line.
        if reset && offset > UInt64(chunk.count), let nl = chunk.firstIndex(of: 0x0A) {
            chunk = chunk[chunk.index(after: nl)...]
        }
        // Keep an unfinished last line (and any half-written character) for the next poll.
        if let lastNL = chunk.lastIndex(of: 0x0A) {
            partialData = Data(chunk[chunk.index(after: lastNL)...])
            chunk = chunk[..<lastNL]
        } else {
            partialData = Data(chunk)
            chunk = Data()
        }
        let text = String(decoding: chunk, as: UTF8.self)
        let new: [LogLine] = text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            nextID += 1
            let clipped = line.count > 2000 ? String(line.prefix(2000)) + "…" : line
            return source.parse(clipped, id: nextID)
        }
        DispatchQueue.main.async {
            guard self.activeSource == source else { return }
            if !self.exists { self.exists = true }
            if self.size != size { self.size = size }   // publishing an unchanged size redrew the Logs pane every second
            if reset { self.lines = Array(new.suffix(Self.maxLines)); return }
            guard !new.isEmpty else { return }
            self.lines.append(contentsOf: new)
            if self.lines.count > Self.maxLines { self.lines.removeFirst(self.lines.count - Self.maxLines) }
        }
    }
}
