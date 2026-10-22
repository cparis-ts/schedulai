import AppKit
import CryptoKit
import Darwin
import Foundation
import Observation

/// Installs new versions on its own: checks the repository's
/// latest GitHub release shortly after launch and then twice a day, downloads
/// Schedulai.zip, checks it against Schedulai.zip.sha256, and swaps the app in
/// /Applications through a small script that waits for this process to quit,
/// then relaunches it. The jobs keep running throughout: they belong to launchd.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()
    static let repository = "cparis-ts/schedulai"

    /// One line for the menu: the version, and what the updater is doing.
    private(set) var statusLine = ""
    private(set) var isBusy = false

    var currentVersion: String {
        Self.appBundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// The .app this binary sits in. Run as `schedulai` through its symlink,
    /// Bundle.main is not it, so go from the executable's real path.
    static var appBundle: Bundle {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 else { return .main }
        let executable = URL(filePath: String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)).resolvingSymlinksInPath()
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        return Bundle(url: contents.deletingLastPathComponent()) ?? .main
    }

    private init() {
        statusLine = tr("Version %@", currentVersion)
    }

    func start() {
        guard JobStore.demoRoot == nil else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            while let self {
                await self.check(userInitiated: false)
                try? await Task.sleep(for: .seconds(12 * 3600))
            }
        }
    }

    func check(userInitiated: Bool) async {
        guard !isBusy else { return }
        // Only a copy in /Applications updates itself: a build run from the
        // checkout would be replaced by the release.
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else {
            if userInitiated { alert(tr("Updates only apply to the copy in /Applications.")) }
            return
        }
        isBusy = true
        defer { isBusy = false }
        statusLine = tr("Checking for updates…")
        do {
            let release = try await latestRelease()
            let version = release.tag.hasPrefix("v") ? String(release.tag.dropFirst()) : release.tag
            guard Self.isNewer(version, than: currentVersion) else {
                statusLine = tr("Version %@ · up to date", currentVersion)
                if userInitiated { alert(tr("SchedulAI %@ is the latest version.", currentVersion)) }
                return
            }
            if JobStore.shared.jobs.contains(where: { $0.state == .running }) {
                // Never swap the runner under a running job; the next check retries.
                statusLine = tr("Version %@ waits for the running cron", version)
                return
            }
            statusLine = tr("Installing SchedulAI %@…", version)
            try await install(release, version: version)
        } catch {
            statusLine = tr("Version %@ · update check failed", currentVersion)
            if userInitiated { alert(tr("Could not update: %@", error.localizedDescription)) }
        }
    }

    // MARK: GitHub

    private struct Release {
        let tag: String
        let zip: URL
        let checksum: URL
    }

    private struct UpdateError: LocalizedError {
        let errorDescription: String?
    }

    private func latestRelease() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]] else {
            throw UpdateError(errorDescription: tr("no release found on github.com/%@", Self.repository))
        }
        func asset(_ name: String) -> URL? {
            assets.first { $0["name"] as? String == name }
                .flatMap { $0["browser_download_url"] as? String }
                .flatMap(URL.init(string:))
        }
        guard let zip = asset("Schedulai.zip"), let checksum = asset("Schedulai.zip.sha256") else {
            throw UpdateError(errorDescription: tr("release %@ has no Schedulai.zip", tag))
        }
        return Release(tag: tag, zip: zip, checksum: checksum)
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Install

    private func install(_ release: Release, version: String) async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appending(path: "schedulai-update-\(version)")
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        let (zipFile, _) = try await URLSession.shared.download(from: release.zip)
        let (checksumData, _) = try await URLSession.shared.data(from: release.checksum)
        let expected = String(decoding: checksumData, as: UTF8.self).split(separator: " ").first.map(String.init) ?? ""
        let actual = SHA256.hash(data: try Data(contentsOf: zipFile)).map { String(format: "%02x", $0) }.joined()
        guard !expected.isEmpty, actual == expected else {
            throw UpdateError(errorDescription: tr("the download does not match its checksum"))
        }

        let zip = work.appending(path: "Schedulai.zip")
        try fm.moveItem(at: zipFile, to: zip)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
        let newApp = work.appending(path: "Schedulai.app")
        guard fm.fileExists(atPath: newApp.appending(path: "Contents/MacOS/Schedulai").path) else {
            throw UpdateError(errorDescription: tr("the archive holds no Schedulai.app"))
        }

        let script = work.appending(path: "install.sh")
        let target = Bundle.main.bundlePath
        try """
        #!/bin/zsh
        # Written by Schedulai's updater: waits for the app to quit, swaps it, reopens it.
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(target)"
        /usr/bin/ditto "\(newApp.path)" "\(target)"
        /usr/bin/xattr -dr com.apple.quarantine "\(target)" 2>/dev/null
        open "\(target)"
        osascript -e 'display notification "\(tr("SchedulAI %@ is installed.", version))" with title "SchedulAI"'
        rm -rf "\(work.path)"
        """.write(to: script, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(filePath: "/bin/zsh")
        process.arguments = [script.path]
        try process.run()
        NSApp.terminate(nil)
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError(errorDescription: "\(tool) exit \(process.terminationStatus)")
        }
    }

    private func alert(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "SchedulAI"
        alert.informativeText = text
        NSApp.activate()
        alert.runModal()
    }
}
