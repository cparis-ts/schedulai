import Foundation

/// `schedulai <command>`: the app's binary run from a terminal (install.sh
/// links it into ~/.local/bin). It goes through the same JobStore as the
/// window, so a job enabled here gets exactly the LaunchAgent the toggle writes.
@MainActor
enum CLI {
    static let usage = """
    usage: schedulai <command> [id]

      list              every job: id, active or not, last result, schedule
      check <id>        validate a job's prompt.md; exit 1 when something is wrong
      enable <id>       validate, then schedule it (writes its LaunchAgent)
      disable <id>      unschedule it
      delete <id>       unschedule it and move its folder to the Trash
      session <id> [agent]
                        open an AI session on the job in this terminal, its brief
                        as the first message (agent: claude, codex or gemini)
      brief <id>        print what an AI needs to challenge the job: schedule,
                        permissions, last runs and reports, the prompt
      run <id>          run it now in the foreground; prints its log, exits with its code
      dir               print the jobs directory
      version           print the installed version

    A job is ~/.claude/scheduled/<id>/prompt.md:
      ---
      name: Morning PR digest
      description: Lists my open PRs waiting on a review   (optional, shown in the app)
      schedule: weekdays 08:00     (08:00 · daily 08:00 · mon,thu 09:30 · 08:00, 14:00 · every 30m · every 2h)
      workdir: ~/projects/my-app
      agent: claude                (optional: claude, codex or gemini; claude when absent)
      model: sonnet                (optional)
      …the agent's permissions:
        claude  allowedTools: "Bash(gh pr list:*),Bash(gh pr view:*)"
        codex   sandbox: read-only | workspace-write | danger-full-access   network: true
        gemini  allowedTools: "run_shell_command(gh pr list)"   approval: default | auto_edit | yolo
      ---
      The prompt, given to the agent's headless mode (claude -p, codex exec, gemini -p).
    """

    static func run(_ args: [String]) -> Int32 {
        let store = JobStore.shared
        switch (args.first, args.count) {
        case ("list", 1):
            for job in store.jobs {
                let schedule = job.schedule?.summary ?? "INVALID schedule"
                print("\(job.id)\t\(job.enabled ? "active" : "inactive")\t\(stateText(job))\t\(schedule)\t\(job.name)")
            }
            return 0
        case ("version", 1):
            print(Updater.shared.currentVersion)
            return 0
        case ("dir", 1):
            print(store.root.path)
            return 0
        case ("check", 2):
            guard let job = find(args[1], in: store) else { return 1 }
            return report(job)
        case ("enable", 2):
            guard let job = find(args[1], in: store) else { return 1 }
            guard report(job) == 0 else {
                printError("not enabled: fix the problems above first")
                return 1
            }
            store.setEnabled(job, true)
            if let error = store.errorMessage {
                printError(error)
                return 1
            }
            let next = job.schedule?.nextRun(after: .now).map { ", next run \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
            print("enabled: \(job.label)\(next)")
            return 0
        case ("disable", 2):
            guard let job = find(args[1], in: store) else { return 1 }
            store.setEnabled(job, false)
            print("disabled: \(job.id)")
            return 0
        case ("delete", 2):
            guard let job = find(args[1], in: store) else { return 1 }
            guard store.delete(job) else {
                printError(store.errorMessage ?? "not deleted")
                return 1
            }
            print("deleted: \(job.id) (folder moved to the Trash)")
            return 0
        case ("session", 2), ("session", 3):
            guard let job = find(args[1], in: store) else { return 1 }
            var agent = store.sessionAgent(for: job)
            if args.count == 3 {
                guard let chosen = Agent(rawValue: args[2].lowercased()) else {
                    printError("unknown agent \"\(args[2])\": claude, codex or gemini")
                    return 2
                }
                agent = chosen
            }
            guard store.isInstalled(agent) else {
                printError("\(agent.rawValue) is not installed; see \(agent.installURL.absoluteString)")
                return 1
            }
            guard let command = Session.start(job, agent: agent, note: nil, focus: job.logs.first, store: store, open: false) else {
                printError(store.errorMessage ?? "could not prepare the session")
                return 1
            }
            // The agent takes over this terminal.
            let argv: [String] = ["/bin/zsh", "-lc", command]
            var cArgs = argv.map { strdup($0) } + [nil]
            execv("/bin/zsh", &cArgs)
            printError("could not start zsh: \(String(cString: strerror(errno)))")
            return 1
        case ("brief", 2):
            guard let job = find(args[1], in: store) else { return 1 }
            print(Session.brief(job, store: store))
            return 0
        case ("run", 2):
            guard let job = find(args[1], in: store) else { return 1 }
            return runForeground(job, runner: store.runner, store: store)
        default:
            printError(usage)
            return 2
        }
    }

    private static func find(_ id: String, in store: JobStore) -> Job? {
        if let job = store.jobs.first(where: { $0.id == id }) { return job }
        printError("no job \"\(id)\" in \(store.root.path) (expected \(id)/prompt.md)")
        return nil
    }

    /// Prints the job as the runner will see it; returns 1 when it cannot run as written.
    private static func report(_ job: Job) -> Int32 {
        var problems: [String] = []
        print("id:           \(job.id)")
        print("name:         \(job.name)")
        print("description:  \(job.about ?? "(none)")")
        if let schedule = job.schedule {
            print("schedule:     \(job.scheduleText) → \(schedule.summary)")
            if let next = schedule.nextRun(after: .now) {
                print("next run:     \(L10n.date(next))")
            }
        } else {
            problems.append("schedule: \(job.scheduleError ?? "invalid")")
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: job.expandedWorkdir, isDirectory: &isDirectory), isDirectory.boolValue {
            print("workdir:      \(job.workdir)")
        } else {
            problems.append("workdir: \(job.workdir) is not a directory")
        }
        if let agentError = job.agentError {
            problems.append("agent: \(agentError)")
        } else {
            let found = JobStore.shared.agentPaths?[job.agent]
            print("agent:        \(job.agent.rawValue) (\(job.agent.displayName)) — \(found ?? (JobStore.shared.agentPaths == nil ? "not checked" : "command not found"))")
            if !JobStore.shared.isInstalled(job.agent) {
                problems.append("agent: `\(job.agent.rawValue)` is not installed (or not on the runner's PATH); see \(job.agent.installURL.absoluteString)")
            }
            print("permissions:  \(job.agent.permissions(job.meta))")
            problems += job.agent.problems(job.meta)
            for key in job.agent.ignoredKeys(job.meta) {
                print("note:         `\(key):` is ignored by \(job.agent.displayName)")
            }
        }
        print("model:        \(job.model ?? "(default)")")
        print("active:       \(job.enabled ? "yes" : "no")")
        print("last run:     \(job.lastRunText)\(job.logs.first.map { " — \($0.path)" } ?? "")")
        if job.prompt.isEmpty {
            problems.append("prompt: empty body after the frontmatter")
        }
        // On stdout, after the report they belong to.
        for problem in problems {
            print("PROBLEM      \(problem)")
        }
        return problems.isEmpty ? 0 : 1
    }

    private static func runForeground(_ job: Job, runner: URL, store: JobStore) -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/zsh")
        process.arguments = [runner.path, job.dir.path]
        do {
            try process.run()
        } catch {
            printError("cannot start \(runner.path): \(error.localizedDescription)")
            return 1
        }
        process.waitUntilExit()
        store.reload()
        if let log = store.jobs.first(where: { $0.id == job.id })?.logs.first,
           let text = try? String(contentsOf: log, encoding: .utf8) {
            print(text)
            print("--- \(log.path)")
        }
        print("exit code: \(process.terminationStatus)")
        return process.terminationStatus
    }

    private static func stateText(_ job: Job) -> String {
        switch job.state {
        case .never: return job.status == nil ? "never-run" : "interrupted"
        case .running: return "running"
        case .succeeded: return "ok"
        case .failed: return "failed(\(job.status?.exitCode ?? -1))"
        }
    }

    private static func printError(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
