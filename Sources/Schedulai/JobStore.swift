import AppKit
import Foundation
import Observation
import ServiceManagement

/// The jobs under ~/.claude/scheduled/<id>/prompt.md, and their LaunchAgents.
///
/// A job is active when its plist sits in ~/Library/LaunchAgents. Every reload
/// rewrites the plist of an active job whose prompt.md changed its schedule.
@MainActor
@Observable
final class JobStore {
    static let shared = JobStore()
    /// Set by the `schedulai` command line before `shared` is first read:
    /// no Dock badge, no polling.
    static var headless = false

    private(set) var jobs: [Job] = []
    private(set) var loginItemStatus = SMAppService.mainApp.status
    var errorMessage: String?
    /// Called after every reload: the menu bar icon follows the jobs' state.
    @ObservationIgnored var onReload: (() -> Void)?

    var summary: String {
        let active = jobs.filter(\.enabled).count
        if active == 0 { return tr("No active cron") }
        return tr(active > 1 ? "%@ active crons" : "%@ active cron", "\(active)")
    }

    var headerCaption: String {
        let failed = jobs.filter { $0.state == .failed }.count
        let running = jobs.filter { $0.state == .running }.count
        var parts: [String] = []
        if running > 0 { parts.append(tr("%@ running", "\(running)")) }
        if failed > 0 { parts.append(tr("%@ failed on the last run", "\(failed)")) }
        if parts.isEmpty, let next = jobs.filter(\.enabled).compactMap({ $0.schedule?.nextRun(after: .now) }).min() {
            return tr("Next run %@.", L10n.relative(next))
        }
        return parts.isEmpty ? tr("All good.") : parts.joined(separator: " · ").capitalizedFirst + "."
    }

    var menuBarBadge: Icons.Badge {
        if jobs.contains(where: { $0.state == .failed }) { return .failure }
        if jobs.contains(where: { $0.state == .running }) { return .running }
        return .sparkle
    }

    /// `SCHEDULAI_DEMO=<dir>`: jobs read from <dir>, LaunchAgents kept in
    /// <dir>/.agents and launchctl never called — the README's screenshots
    /// come from such a copy, so they show sample jobs and touch nothing real.
    static let demoRoot = ProcessInfo.processInfo.environment["SCHEDULAI_DEMO"].map { URL(filePath: $0) }

    let root = demoRoot ?? URL.homeDirectory.appending(path: ".claude/scheduled")
    var runner: URL { root.appending(path: ".bin/run-job.sh") }
    private let agentsDir = demoRoot?.appending(path: ".agents") ?? URL.homeDirectory.appending(path: "Library/LaunchAgents")
    private let domain = "gui/\(getuid())"
    private let fm = FileManager.default

    private init() {
        installRunner()
        migrateLegacyAgents()
        reload()
        if Self.headless { return }
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                self.reload()
            }
        }
    }

    // MARK: Reading

    func reload() {
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        jobs = dirs
            .filter { !$0.lastPathComponent.hasPrefix(".") && fm.fileExists(atPath: $0.appending(path: "prompt.md").path) }
            .map(loadJob)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for job in jobs where job.enabled {
            syncAgent(job)
        }
        if !Self.headless {
            let failed = jobs.filter { $0.state == .failed }.count
            NSApplication.shared.dockTile.badgeLabel = failed > 0 ? "\(failed)" : nil
        }
        loginItemStatus = SMAppService.mainApp.status
        onReload?()
    }

    /// Opens the app at login, so the menu bar icon and the Dock badge are there.
    /// The jobs themselves run under launchd whether the app is open or not.
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = tr("Open at login: %@", error.localizedDescription)
        }
        loginItemStatus = SMAppService.mainApp.status
    }

    private func loadJob(_ dir: URL) -> Job {
        let id = dir.lastPathComponent
        let text = (try? String(contentsOf: dir.appending(path: "prompt.md"), encoding: .utf8)) ?? ""
        let prompt = PromptFile.parse(text)
        let scheduleText = prompt.meta["schedule"] ?? ""
        var schedule: Schedule?
        var scheduleError: String?
        do {
            schedule = try Schedule.parse(scheduleText)
        } catch let error as ScheduleError {
            scheduleError = error.message
        } catch {
            scheduleError = "\(error)"
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let status = (try? Data(contentsOf: dir.appending(path: "status.json")))
            .flatMap { try? decoder.decode(RunStatus.self, from: $0) }

        var runningPID: Int32?
        if let pidText = try? String(contentsOf: dir.appending(path: ".running"), encoding: .utf8),
           let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)), kill(pid, 0) == 0 {
            runningPID = pid
        }

        let history = ((try? String(contentsOf: dir.appending(path: "history.jsonl"), encoding: .utf8)) ?? "")
            .split(separator: "\n")
            .compactMap { try? decoder.decode(RunStatus.self, from: Data($0.utf8)) }
            .reversed()

        let logs = ((try? fm.contentsOfDirectory(at: dir.appending(path: "logs"),
                                                 includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "log" }
            .sorted { modificationDate($0) > modificationDate($1) }

        return Job(
            id: id,
            dir: dir,
            name: prompt.meta["name"].flatMap { $0.isEmpty ? nil : $0 } ?? id,
            about: prompt.meta["description"].flatMap { $0.isEmpty ? nil : $0 },
            scheduleText: scheduleText,
            schedule: schedule,
            scheduleError: scheduleError,
            workdir: prompt.meta["workdir"] ?? "~",
            allowedTools: prompt.meta["allowedTools"] ?? "",
            model: prompt.meta["model"],
            prompt: prompt.body.trimmingCharacters(in: .whitespacesAndNewlines),
            enabled: fm.fileExists(atPath: plistURL(id: id).path),
            runningPID: runningPID,
            status: status,
            history: history.isEmpty ? (status.map { [$0] } ?? []) : Array(history),
            logs: logs
        )
    }

    private func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    // MARK: Actions

    func setEnabled(_ job: Job, _ enabled: Bool) {
        if enabled {
            guard job.schedule != nil else {
                errorMessage = job.scheduleError ?? tr("Invalid schedule.")
                return
            }
            var copy = job
            copy.enabled = true
            syncAgent(copy)
        } else {
            launchctl("bootout", "\(domain)/\(job.label)")
            try? fm.removeItem(at: plistURL(id: job.id))
        }
        reload()
    }

    func runNow(_ job: Job) {
        if job.enabled {
            launchctl("kickstart", "\(domain)/\(job.label)")
        } else {
            let process = Process()
            process.executableURL = URL(filePath: "/bin/zsh")
            process.arguments = [runner.path, job.dir.path]
            do {
                try process.run()
            } catch {
                errorMessage = tr("Could not start the job: %@", error.localizedDescription)
            }
        }
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            reload()
        }
    }

    func stop(_ job: Job) {
        guard let pid = job.runningPID else { return }
        // claude (the runner's child) first, then the runner itself; the run
        // then shows as interrupted, since status.json never got its end.
        let pkill = Process()
        pkill.executableURL = URL(filePath: "/usr/bin/pkill")
        pkill.arguments = ["-TERM", "-P", "\(pid)"]
        try? pkill.run()
        pkill.waitUntilExit()
        kill(pid, SIGTERM)
        reload()
    }

    func createJob(named name: String) -> String? {
        let slug = name.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { result, char in
                if char != "-" || result.last != "-" { result.append(char) }
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !slug.isEmpty else {
            errorMessage = tr("Give the cron a name.")
            return nil
        }
        let dir = root.appending(path: slug)
        guard !fm.fileExists(atPath: dir.path) else {
            errorMessage = tr("A cron \"%@\" already exists.", slug)
            return nil
        }
        let template = """
        ---
        name: \(name)
        description: \(tr("What this cron does, in one sentence."))
        schedule: weekdays 08:00
        workdir: ~
        allowedTools: "Bash(gh pr list:*),Bash(gh pr view:*)"
        ---
        \(tr("Describe here what Claude should do, then end with a short report."))

        """
        do {
            try fm.createDirectory(at: dir.appending(path: "logs"), withIntermediateDirectories: true)
            try template.write(to: dir.appending(path: "prompt.md"), atomically: true, encoding: .utf8)
        } catch {
            errorMessage = tr("Could not create the cron: %@", error.localizedDescription)
            return nil
        }
        reload()
        return slug
    }

    func dockMenu() -> NSMenu {
        let menu = NSMenu()
        for job in jobs {
            menu.addItem(JobMenu.item(for: job, store: self))
        }
        if jobs.isEmpty {
            menu.addItem(withTitle: tr("No crons"), action: nil, keyEquivalent: "")
        }
        return menu
    }

    // MARK: Main window

    /// Writes one frontmatter line of a job's prompt.md (nil removes it).
    func setMeta(_ key: String, _ value: String?, of job: Job) {
        do {
            let text = try String(contentsOf: job.promptURL, encoding: .utf8)
            try PromptFile.setting(key, to: value, in: text).write(to: job.promptURL, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = tr("Could not change %@: %@", key, error.localizedDescription)
        }
        reload()
    }

    /// Set by the window's view: SwiftUI's openWindow, which reopens it once closed.
    @ObservationIgnored var openWindow: (() -> Void)?
    /// Raised to make the window show its "New cron" sheet.
    var newJobRequested = false
    /// A job the window should select, and whether to open its prompt editor.
    var requestedJob: String?
    var requestedPromptTab = false

    func showMainWindow(newJob: Bool = false, job: String? = nil, editPrompt: Bool = false) {
        requestedJob = job
        requestedPromptTab = editPrompt
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow?()
        }
        if newJob { newJobRequested = true }
    }

    // MARK: launchd

    private func plistURL(id: String) -> URL {
        agentsDir.appending(path: "com.charlesparis.schedulai.\(id).plist")
    }

    /// Writes the job's LaunchAgent and (re)loads it when its content changed.
    private func syncAgent(_ job: Job) {
        guard let schedule = job.schedule else { return }
        var dict: [String: Any] = [
            "Label": job.label,
            "ProgramArguments": ["/bin/zsh", runner.path, job.dir.path],
            "StandardOutPath": job.dir.appending(path: "logs/launchd.out").path,
            "StandardErrorPath": job.dir.appending(path: "logs/launchd.err").path,
        ]
        dict.merge(schedule.launchdKeys) { $1 }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) else {
            return
        }
        let url = plistURL(id: job.id)
        if (try? Data(contentsOf: url)) == data { return }
        do {
            try fm.createDirectory(at: job.dir.appending(path: "logs"), withIntermediateDirectories: true)
            try fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)
            launchctl("bootout", "\(domain)/\(job.label)")
            try data.write(to: url, options: .atomic)
            let (code, output) = launchctl("bootstrap", domain, url.path)
            if code != 0 {
                errorMessage = tr("launchctl bootstrap failed (%@): %@", "\(code)", output)
            }
        } catch {
            errorMessage = tr("Could not write the LaunchAgent: %@", error.localizedDescription)
        }
    }

    @discardableResult
    private func launchctl(_ args: String...) -> (Int32, String) {
        if Self.demoRoot != nil { return (0, "") }
        let process = Process()
        process.executableURL = URL(filePath: "/bin/launchctl")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Renames the LaunchAgents written while the app was called Claude Crons.
    /// An active job stays active: its new plist starts empty, and reload
    /// writes the real one, as it does for any plist whose content differs.
    private func migrateLegacyAgents() {
        let legacyPrefix = "com.charlesparis.claudecrons."
        let files = (try? fm.contentsOfDirectory(atPath: agentsDir.path)) ?? []
        for file in files where file.hasPrefix(legacyPrefix) && file.hasSuffix(".plist") {
            let label = String(file.dropLast(".plist".count))
            let id = String(label.dropFirst(legacyPrefix.count))
            launchctl("bootout", "\(domain)/\(label)")
            try? fm.removeItem(at: agentsDir.appending(path: file))
            fm.createFile(atPath: plistURL(id: id).path, contents: Data())
        }
    }

    /// Installs what ships inside the bundle, so an update refreshes it too:
    /// run-job.sh (where every LaunchAgent points), the Claude Code skill, and
    /// the `schedulai` command (a link to this binary). Only from the app
    /// itself: a `schedulai` run has no bundle resources to copy.
    private func installRunner() {
        guard !Self.headless, Self.demoRoot == nil,
              let bundledRunner = Bundle.main.url(forResource: "run-job", withExtension: "sh") else { return }
        let skill = URL.homeDirectory.appending(path: ".claude/skills/schedulai/SKILL.md")
        let command = URL.homeDirectory.appending(path: ".local/bin/schedulai")
        do {
            try replace(runner, with: bundledRunner)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runner.path)
            if let bundledSkill = Bundle.main.url(forResource: "SKILL", withExtension: "md") {
                try replace(skill, with: bundledSkill)
            }
            if let executable = Bundle.main.executableURL, Bundle.main.bundlePath.hasPrefix("/Applications/") {
                try fm.createDirectory(at: command.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: command)
                try fm.createSymbolicLink(at: command, withDestinationURL: executable)
            }
        } catch {
            errorMessage = tr("Could not install run-job.sh: %@", error.localizedDescription)
        }
    }

    private func replace(_ destination: URL, with source: URL) throws {
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.copyItem(at: source, to: destination)
    }
}

@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, key: String = "", handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func fire() {
        handler()
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
