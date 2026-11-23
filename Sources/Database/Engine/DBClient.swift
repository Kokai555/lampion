import SwiftUI
import AppKit

enum DBClient {
    static let client = "\(Paths.brew)/bin/mariadb"
    static let dump = "\(Paths.brew)/bin/mariadb-dump"

    static func exec(_ path: String, _ args: [String], stdin: Data? = nil) -> (status: Int32, out: Data, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let o = Pipe(), e = Pipe(), i = Pipe()
        p.standardOutput = o; p.standardError = e; p.standardInput = i
        do { try p.run() } catch { return (-1, Data(), error.localizedDescription) }
        let group = DispatchGroup()
        var errData = Data()
        DispatchQueue.global().async(group: group) { errData = e.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global().async(group: group) {
            if let stdin { try? i.fileHandleForWriting.write(contentsOf: stdin) }
            try? i.fileHandleForWriting.close()
        }
        let out = o.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        group.wait()
        return (p.terminationStatus, out, String(decoding: errData, as: UTF8.self))
    }

    static func run(_ sql: String, database: String? = nil) -> ExecResult {
        run(Data(sql.utf8), database: database)
    }

    static func run(_ sql: Data, database: String? = nil) -> ExecResult {
        let start = Date()
        var args = ["--xml", "--binary-as-hex", "--default-character-set=utf8mb4"]
        if let database { args += ["-D", database] }
        let r = exec(client, args, stdin: sql)
        var result = ExecResult()
        result.seconds = Date().timeIntervalSince(start)
        let parsed = XMLResults.parse(r.out)
        result.sets = parsed.sets
        if r.status != 0 {
            result.error = cleanError(r.err)
        } else if !parsed.ok {
            result.error = "The result can't be displayed (it probably contains control characters or binary data)."
        }
        return result
    }

    static func cleanError(_ err: String) -> String {
        let lines = err.split(separator: "\n").map(String.init)
        if let e = lines.last(where: { $0.hasPrefix("ERROR") }) {
            if e.contains("(HY000) ") && (e.contains("2002") || e.contains("Can't connect")) {
                return "Can't connect to the database. Is MySQL running? (\(e))"
            }
            return e
        }
        let t = err.trimmed
        return t.isEmpty ? "Unknown error" : t
    }
}
