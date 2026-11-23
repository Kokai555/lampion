import SwiftUI
import AppKit
import CryptoKit

/// Checks GitHub for a newer release and installs it in place of the running app.
final class Updater: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let repository = "Kokai555/lampion"
    static let releasesPage = "https://github.com/\(repository)/releases"
    private static let skippedKey = "skippedUpdateVersion"

    struct Release: Equatable {
        let version: String
        let page: String
        let dmgURL: String
        let sha256: String?
        var notes = ""

        /// The "what's new" part of the release notes, without the install instructions.
        var highlights: String {
            var text = notes.replacingOccurrences(of: "\r\n", with: "\n")
            for heading in ["\n## Install", "\n## Requirements", "\nSHA-256"] {
                if let r = text.range(of: heading) { text = String(text[..<r.lowerBound]) }
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Release, Double)   // 0...1
        case installing(Release)
        case failed(String)
    }

    @Published var state: State = .idle

    /// True while the app quits to install an update (the servers are left running).
    static var isRelaunching = false

    private var session: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var pending: (release: Release, target: String)?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// True when `a` is a higher version than `b` ("1.10" is newer than "1.9").
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Reads the latest release from GitHub's JSON.
    static func parseRelease(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String, let assets = json["assets"] as? [[String: Any]],
              let dmg = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
              let url = dmg["browser_download_url"] as? String else { return nil }
        let digest = (dmg["digest"] as? String).flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
        let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        return Release(version: version, page: json["html_url"] as? String ?? releasesPage, dmgURL: url, sha256: digest,
                       notes: json["body"] as? String ?? "")
    }

    /// `userInitiated`: chosen from the menu. Then the answer is always shown, including "up to date" and errors,
    /// and a version the user skipped earlier is offered again.
    func check(userInitiated: Bool, then: (() -> Void)? = nil) {
        switch state {
        case .downloading, .installing, .checking: return
        default: break
        }
        guard let url = URL(string: "https://api.github.com/repos/\(Updater.repository)/releases/latest") else { return }
        if userInitiated { state = .checking }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                defer { then?() }
                guard let data, let release = Updater.parseRelease(data) else {
                    self.state = userInitiated
                        ? .failed("Could not check for updates. \(error?.localizedDescription ?? "GitHub did not return a release.")")
                        : .idle
                    return
                }
                let skipped = UserDefaults.standard.string(forKey: Updater.skippedKey)
                if Updater.isNewer(release.version, than: self.currentVersion) && (userInitiated || skipped != release.version) {
                    self.state = .available(release)
                } else if userInitiated {
                    self.state = .upToDate
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if self.state == .upToDate { self.state = .idle } }
                } else {
                    self.state = .idle
                }
            }
        }.resume()
    }

    /// Shows the notice in a given state without contacting GitHub: `--preview-update available|downloading|installing|uptodate|failed`.
    func preview(_ name: String) {
        let sample = Release(version: "2.0", page: Updater.releasesPage, dmgURL: "", sha256: nil, notes: """
            ## What's new

            - **Table structure editing.** A table designer for new tables; change, rename and reorder columns; add indexes and foreign keys.
            - **Built-in updates.** The app checks GitHub for a newer release and updates itself with one click.
            - The Structure and Query tabs now stay selected when you move between tables.

            ## Install

            1. Download the disk image.
            """)
        switch name {
        case "available", "notes": state = .available(sample)
        case "downloading": state = .downloading(sample, 0.62)
        case "installing": state = .installing(sample)
        case "uptodate": state = .upToDate
        case "failed": state = .failed("The download does not match the release (checksum mismatch).")
        default: state = .idle
        }
    }

    /// Hides the offer until the next launch.
    func later() { state = .idle }

    /// Hides the offer until a newer version than this one is released.
    func skip(_ release: Release) {
        UserDefaults.standard.set(release.version, forKey: Updater.skippedKey)
        state = .idle
    }

    func install(_ release: Release) {
        guard let url = URL(string: release.dmgURL) else { return }
        let target = Bundle.main.bundlePath
        let parent = (target as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: parent), !target.contains("/AppTranslocation/"), !target.hasPrefix("/Volumes/") else {
            state = .failed("Move Lampion to the Applications folder first, then update.")
            return
        }
        state = .downloading(release, 0)
        pending = (release, target)
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        self.session = session
        downloadTask = session.downloadTask(with: url)
        downloadTask?.resume()
    }

    func cancelDownload() {
        guard case .downloading(let release, _) = state else { return }
        pending = nil
        downloadTask?.cancel()
        state = .available(release)
    }

    // URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        DispatchQueue.main.async {
            if case .downloading(let release, _) = self.state { self.state = .downloading(release, fraction) }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let pending else { return }
        self.pending = nil
        finishInstall(pending.release, downloaded: location, target: pending.target)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        guard let error, pending != nil, (error as NSError).code != NSURLErrorCancelled else { return }
        pending = nil
        fail("The download failed. \(error.localizedDescription)")
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async { self.state = .failed(message) }
    }

    private func finishInstall(_ release: Release, downloaded: URL, target: String) {
        let fm = FileManager.default
        let work = NSTemporaryDirectory() + "lampion-update-\(ProcessInfo.processInfo.processIdentifier)"
        let dmg = work + "/Lampion.dmg", mount = work + "/mount", staged = work + "/Lampion.app"
        do {
            try? fm.removeItem(atPath: work)
            try fm.createDirectory(atPath: mount, withIntermediateDirectories: true)
            try fm.moveItem(atPath: downloaded.path, toPath: dmg)
            DispatchQueue.main.async { self.state = .installing(release) }

            // 1. The file must be the one GitHub lists for the release.
            if let expected = release.sha256 {
                let data = try Data(contentsOf: URL(fileURLWithPath: dmg))
                let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard actual == expected.lowercased() else { throw Problem("The download does not match the release (checksum mismatch).") }
            }

            // 2. Copy the app out of the disk image.
            let attach = Shell.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-mountpoint", mount, dmg])
            guard attach.status == 0 else { throw Problem("Could not open the disk image.") }
            // Take whichever app the disk image holds, so a renamed app can still update.
            let appName = (try? fm.contentsOfDirectory(atPath: mount))?.first { $0.hasSuffix(".app") }
            let copy = appName.map { Shell.run("/usr/bin/ditto", ["\(mount)/\($0)", staged]) }
            Shell.run("/usr/bin/hdiutil", ["detach", mount, "-quiet"])
            guard copy?.status == 0 else { throw Problem("The disk image does not contain an app.") }

            // 3. It must be an intact, newer copy of this app.
            guard Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged]).status == 0 else {
                throw Problem("The downloaded app is damaged (its signature is not valid).")
            }
            let info = NSDictionary(contentsOfFile: staged + "/Contents/Info.plist")
            guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
                  let newVersion = info?["CFBundleShortVersionString"] as? String,
                  Updater.isNewer(newVersion, than: currentVersion) else {
                throw Problem("The download is not a newer version of Lampion.")
            }

            // 4. Swap the app once this copy has quit, then open the new one.
            let script = """
                #!/bin/bash
                while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
                TARGET=\(Updater.quoted(target))
                rm -rf "$TARGET.old"
                if mv "$TARGET" "$TARGET.old" && /usr/bin/ditto \(Updater.quoted(staged)) "$TARGET"; then
                  rm -rf "$TARGET.old"
                else
                  rm -rf "$TARGET"; mv "$TARGET.old" "$TARGET"
                fi
                /usr/bin/open -n "$TARGET"
                rm -rf \(Updater.quoted(work))

                """
            let scriptPath = work + "/install.sh"
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            Shell.run("/bin/bash", ["-c", "nohup /bin/bash \(Updater.quoted(scriptPath)) >/dev/null 2>&1 &"])
            // A short pause so the "Installing" state is readable before the app closes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { Updater.isRelaunching = true; NSApp.terminate(nil) }
        } catch {
            Shell.run("/usr/bin/hdiutil", ["detach", mount, "-quiet"])
            try? fm.removeItem(atPath: work)
            fail((error as? Problem)?.message ?? error.localizedDescription)
        }
    }

    private struct Problem: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
