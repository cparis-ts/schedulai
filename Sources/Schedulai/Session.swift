import AppKit
import Foundation

/// "Challenge with AI": an interactive agent session opened on a job, its
/// first message being the job's brief — schedule, permissions, last runs and
/// reports, the prompt as it is now — so the conversation starts from what the
/// scheduled run actually did.
@MainActor
enum Session {
    /// How many runs the brief lists, and how many reports it quotes.
    private static let runsListed = 10
    private static let reportsQuoted = 3
    private static let reportChars = 4000

    /// The brief, in Markdown. `focus` is the report the user was reading, quoted first.
    static func brief(_ job: Job, note: String? = nil, focus: URL? = nil, store: JobStore) -> String {
        var lines: [String] = []
        lines.append("""
        I want to challenge one of my scheduled jobs. It runs in SchedulAI, a macOS app \
        that hands a prompt to an AI agent's headless mode on a schedule (launchd; \
        `claude -p`, `codex exec` or `gemini -p`): nobody at the keyboard, no memory \
        between runs, only the permissions written in its frontmatter.
        """)

        lines.append("\n## The job\n")
        lines.append("- id: `\(job.id)` — \(job.name)\(job.about.map { " — \($0)" } ?? "")")
        lines.append("- prompt file (what runs): `\(job.promptURL.path)`")
        if let schedule = job.schedule {
            var when = "- schedule: `\(job.scheduleText)` → \(schedule.summary)"
            if job.enabled, let next = schedule.nextRun(after: .now) {
                when += ", next run \(next.formatted(date: .abbreviated, time: .shortened))"
            }
            lines.append(when)
        } else {
            lines.append("- schedule: `\(job.scheduleText)` — invalid: \(job.scheduleError ?? "?")")
        }
        lines.append("- active: \(job.enabled ? "yes" : "no (paused)")")
        lines.append("- agent: \(job.agent.rawValue); permissions: \(job.agent.permissions(job.meta))")
        lines.append("- workdir: `\(job.workdir)`")
        lines.append("- reports: `\(job.dir.appending(path: "logs").path)` (one file per run); history: `\(job.dir.appending(path: "history.jsonl").path)`")

        if !job.history.isEmpty {
            lines.append("\n## Last runs, newest first\n")
            for run in job.history.prefix(runsListed) {
                let outcome: String
                switch run.exitCode {
                case nil: outcome = run.endedAt == nil ? "running or interrupted" : "?"
                case 0?: outcome = "OK"
                case let code?: outcome = "FAILED (exit \(code))"
                }
                lines.append("- \(run.startedAt.formatted(date: .abbreviated, time: .shortened)) — \(outcome)\(run.log.map { " — `\($0)`" } ?? "")")
            }
        }

        var reports = Array(job.logs.prefix(reportsQuoted))
        if let focus, job.logs.contains(focus) {
            reports.removeAll { $0 == focus }
            reports.insert(focus, at: 0)
        }
        if !reports.isEmpty {
            lines.append("\n## Reports\n")
            for (index, log) in reports.enumerated() {
                let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                let quoted = text.count > reportChars ? "…" + text.suffix(reportChars) : text
                let label = index == 0 && log == focus ? " — the one I was looking at" : ""
                lines.append("### `\(log.lastPathComponent)`\(label)\n")
                lines.append(fenced(quoted.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }

        let promptText = (try? String(contentsOf: job.promptURL, encoding: .utf8)) ?? ""
        lines.append("\n## prompt.md as it is now\n")
        lines.append(fenced(promptText.trimmingCharacters(in: .whitespacesAndNewlines), language: "markdown"))

        lines.append("\n## What I need from you\n")
        if let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            lines.append("What is wrong, in my words: **\(note)**\n")
        }
        lines.append("""
        1. Start with three lines: what the job does, and what its last runs show — \
        failures, items it skipped, a "nothing to do" that looks wrong.
        2. \(note?.isEmpty == false ? "Find the cause of what I described." : "Then ask me what went wrong or what to change.") \
        Reproduce the job's steps here, read-only, to see what it saw. Remember the \
        scheduled run can only do what its permissions allow: a step that needs more is \
        a permission to add, not a prompt to reword.
        3. Fix the cause in `\(job.promptURL.path)` — the prompt, its permission keys, or \
        its schedule. Keep the prompt self-contained: the scheduled run never sees this \
        conversation. Show me the change before writing it.
        4. Check it with `schedulai check \(job.id)`. Offer a real test run with \
        `schedulai run \(job.id)`, and warn me first if the job writes anything.
        """)
        if L10n.lang == "fr" {
            lines.append("\nRéponds-moi en français.")
        }
        return lines.joined(separator: "\n")
    }

    /// The interactive command line of `agent`, `brief` being its first message.
    static func command(_ agent: Agent, job: Job, brief: URL, store: JobStore) -> String {
        let executable = shellQuoted(store.agentPaths?[agent] ?? agent.rawValue)
        let jobDir = shellQuoted(job.dir.path)
        let message = "\"$(cat \(shellQuoted(brief.path)))\""
        // The message first: claude's --add-dir takes every argument after it
        // as one more directory.
        switch agent {
        case .claude: return "\(executable) \(message) --add-dir \(jobDir)"
        case .codex: return "\(executable) \(message) --add-dir \(jobDir)"
        case .gemini: return "\(executable) -i \(message) --include-directories \(jobDir)"
        }
    }

    /// Writes the brief and a launcher into <job>/.session/, then opens the
    /// launcher in the user's terminal (the app that opens `.command` files).
    /// Returns the command, for "Copy the command".
    @discardableResult
    static func start(_ job: Job, agent: Agent, note: String?, focus: URL?, store: JobStore, open: Bool = true) -> String? {
        let dir = job.dir.appending(path: ".session")
        let briefURL = dir.appending(path: "brief.md")
        let launcher = dir.appending(path: "start.command")
        let line = command(agent, job: job, brief: briefURL, store: store)
        let script = """
        #!/bin/zsh -l
        # Written by SchedulAI: an interactive \(agent.displayName) session on the job "\(job.name)".
        cd \(shellQuoted(job.expandedWorkdir)) || cd ~
        \(line)

        """
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try brief(job, note: note, focus: focus, store: store).write(to: briefURL, atomically: true, encoding: .utf8)
            try script.write(to: launcher, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        } catch {
            store.errorMessage = tr("Could not prepare the session: %@", error.localizedDescription)
            return nil
        }
        if open, !NSWorkspace.shared.open(launcher) {
            store.errorMessage = tr("No app opens .command files; copy the command instead.")
        }
        return "cd \(shellQuoted(job.expandedWorkdir)) && \(line)"
    }

    private static func fenced(_ text: String, language: String = "") -> String {
        // A fence longer than any backtick run inside, so a report quoting code stays whole.
        var fence = "```"
        while text.contains(fence) { fence += "`" }
        return "\(fence)\(language)\n\(text)\n\(fence)\n"
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
