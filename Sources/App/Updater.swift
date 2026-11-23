import SwiftUI
import AppKit
import CryptoKit

/// Checks GitHub for a newer release and installs it in place of the running app.
final class Updater: ObservableObject {
    static let repository = "Kokai555/szerverpanel"
    static let releasesPage = "https://github.com/\(repository)/releases"

    struct Release: Equatable {
        let version: String
        let page: String
        let dmgURL: String
        let sha256: String?
    }

    enum State: Equatable {
        case idle
        case checking
        case available(Release)
        case installing(String)        // what is happening right now
        case failed(String)
    }

    @Published var state: State = .idle
    /// Shown in an alert after a check the user asked for.
    @Published var notice: String?

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
        return Release(version: version, page: json["html_url"] as? String ?? releasesPage, dmgURL: url, sha256: digest)
    }

    func check(userInitiated: Bool, then: (() -> Void)? = nil) {
        if case .installing = state { return }
        guard let url = URL(string: "https://api.github.com/repos/\(Updater.repository)/releases/latest") else { return }
        state = .checking
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                defer { then?() }
                guard let data, let release = Updater.parseRelease(data) else {
                    self.state = .idle
                    if userInitiated {
                        self.notice = "Could not check for updates. \(error?.localizedDescription ?? "GitHub did not return a release.")"
                    }
                    return
                }
                if Updater.isNewer(release.version, than: self.currentVersion) {
                    self.state = .available(release)
                } else {
                    self.state = .idle
                    if userInitiated { self.notice = "Szerverpanel \(self.currentVersion) is the latest version." }
                }
            }
        }.resume()
    }

    func install(_ release: Release) {
        guard let url = URL(string: release.dmgURL) else { return }
        let target = Bundle.main.bundlePath
        let parent = (target as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: parent), !target.contains("/AppTranslocation/"), !target.hasPrefix("/Volumes/") else {
            state = .failed("Move Szerverpanel to the Applications folder first, then update.")
            return
        }
        state = .installing("Downloading Szerverpanel \(release.version)…")
        URLSession.shared.downloadTask(with: url) { file, _, error in
            guard let file else { self.fail("The download failed. \(error?.localizedDescription ?? "")"); return }
            self.finishInstall(release, downloaded: file, target: target)
        }.resume()
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async { self.state = .failed(message) }
    }

    private func finishInstall(_ release: Release, downloaded: URL, target: String) {
        let fm = FileManager.default
        let work = NSTemporaryDirectory() + "szerverpanel-update-\(ProcessInfo.processInfo.processIdentifier)"
        let dmg = work + "/Szerverpanel.dmg", mount = work + "/mount", staged = work + "/Szerverpanel.app"
        do {
            try? fm.removeItem(atPath: work)
            try fm.createDirectory(atPath: mount, withIntermediateDirectories: true)
            try fm.moveItem(atPath: downloaded.path, toPath: dmg)

            // 1. The file must be the one GitHub lists for the release.
            if let expected = release.sha256 {
                let data = try Data(contentsOf: URL(fileURLWithPath: dmg))
                let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard actual == expected.lowercased() else { throw Problem("The download does not match the release (checksum mismatch).") }
            }

            // 2. Copy the app out of the disk image.
            DispatchQueue.main.async { self.state = .installing("Installing Szerverpanel \(release.version)…") }
            let attach = Shell.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-mountpoint", mount, dmg])
            guard attach.status == 0 else { throw Problem("Could not open the disk image.") }
            let copy = Shell.run("/usr/bin/ditto", ["\(mount)/Szerverpanel.app", staged])
            Shell.run("/usr/bin/hdiutil", ["detach", mount, "-quiet"])
            guard copy.status == 0 else { throw Problem("The disk image does not contain Szerverpanel.") }

            // 3. It must be an intact, newer copy of this app.
            guard Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged]).status == 0 else {
                throw Problem("The downloaded app is damaged (its signature is not valid).")
            }
            let info = NSDictionary(contentsOfFile: staged + "/Contents/Info.plist")
            guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
                  let newVersion = info?["CFBundleShortVersionString"] as? String,
                  Updater.isNewer(newVersion, than: currentVersion) else {
                throw Problem("The download is not a newer version of Szerverpanel.")
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
            DispatchQueue.main.async { NSApp.terminate(nil) }
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
