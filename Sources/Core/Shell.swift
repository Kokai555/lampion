import SwiftUI
import AppKit

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

    /// Runs a long command and reports its output line by line. Returns the exit status.
    static func stream(_ path: String, _ args: [String], onLine: @escaping (String) -> Void) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(Paths.brew)/bin:\(Paths.brew)/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_NO_COLOR"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { onLine(error.localizedDescription); return -1 }
        var pending = ""
        while true {
            let data = pipe.fileHandleForReading.availableData
            if data.isEmpty { break }
            pending += String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r", with: "\n")
            while let nl = pending.firstIndex(of: "\n") {
                let line = pending[..<nl].trimmingCharacters(in: .whitespaces)
                pending = String(pending[pending.index(after: nl)...])
                if !line.isEmpty { onLine(line.count > 160 ? String(line.prefix(160)) + "…" : line) }
            }
        }
        let rest = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { onLine(rest) }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
