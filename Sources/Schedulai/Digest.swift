import Foundation

/// `schedulai digest`: what the scheduled jobs did, for a Claude Code session to read.
///
/// Plain, it is stateless: several sessions start in parallel, and a shared
/// "last seen" marker would let the first one swallow what the others never saw.
/// With `--hook` it reads the hook's JSON on stdin and keeps one mark per
/// session (`<jobs dir>/.digest/<session_id>`): SessionStart prints the stateless
/// digest and marks the newest run it saw; UserPromptSubmit prints only the runs
/// that ended after that mark, then moves it. It never blocks the session: it
/// reads files only (no network, no agent), always exits 0, errors go to stderr.
///
/// It does not touch `JobStore.shared` — loading the store resolves the agents
/// and rewrites LaunchAgents, too slow and too much for a hook run on every prompt.
enum Digest {
    static let recentWindow: TimeInterval = 48 * 3600
    static let failureWindow: TimeInterval = 72 * 3600
    static let markLifetime: TimeInterval = 14 * 24 * 3600

    static var root: URL {
        JobStore.demoRoot ?? URL.homeDirectory.appending(path: ".claude/scheduled")
    }

    struct Run {
        let job: String
        let dir: URL
        let end: Date
        let status: RunStatus

        var failed: Bool { (status.exitCode ?? 0) != 0 || (status.denied ?? 0) > 0 }
    }

    static func run(_ args: [String]) -> Int32 {
        if args == ["--hook"] {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            hook(input, now: .now)
        } else if args.isEmpty {
            if let text = stateless(loadRuns(), now: .now) { print(text) }
        } else {
            printError("usage: schedulai digest [--hook]")
        }
        return 0
    }

    // MARK: Reading

    /// Every run of every job, oldest first within a job, jobs sorted by id.
    static func loadRuns() -> [Run] {
        let fm = FileManager.default
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let dirs = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var runs: [Run] = []
        for dir in dirs {
            guard let text = try? String(contentsOf: dir.appending(path: "history.jsonl"), encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let status = try? decoder.decode(RunStatus.self, from: Data(line.utf8)) else { continue }
                runs.append(Run(job: dir.lastPathComponent, dir: dir, end: status.endedAt ?? status.startedAt, status: status))
            }
        }
        return runs
    }

    // MARK: Text

    /// Per job, its latest run of the last 48 h; every failed or refused run of the last 72 h.
    static func stateless(_ runs: [Run], now: Date) -> String? {
        let rows = rows(runs, recentSince: now.addingTimeInterval(-recentWindow),
                        failuresSince: now.addingTimeInterval(-failureWindow))
        guard !rows.isEmpty else { return nil }
        return (["[schedulai] Derniers passages des jobs planifiés (48 h ; échecs sur 72 h) :"] + rows
            + ["Ce qui demande une décision de l'utilisateur lui est signalé ; le reste va dans le suivi."])
            .joined(separator: "\n")
    }

    /// Only the runs that ended after `mark`: per job the latest, plus every failed one.
    static func since(_ runs: [Run], mark: Date) -> String? {
        let fresh = runs.filter { $0.end > mark }
        let rows = rows(fresh, recentSince: mark, failuresSince: mark)
        guard !rows.isEmpty else { return nil }
        return (["[schedulai] Nouveaux passages depuis ton dernier message :"] + rows).joined(separator: "\n")
    }

    private static func rows(_ runs: [Run], recentSince: Date, failuresSince: Date) -> [String] {
        var rows: [String] = []
        let byJob = Dictionary(grouping: runs, by: \.job)
        for job in byJob.keys.sorted() {
            let history = byJob[job] ?? []
            if let last = history.last(where: { $0.end >= recentSince }) {
                rows.append("- \(job) (\(when(last.end))) : \(verdict(last))")
            }
            for run in history where run.end >= failuresSince && run.failed {
                let log = run.status.log.map { run.dir.appending(path: "logs").appending(path: $0) }
                let where_ = log.map { FileManager.default.fileExists(atPath: $0.path) ? "log \($0.path)" : nil } ?? nil
                rows.append("  ! \(job) \(when(run.end)) : exit \(run.status.exitCode.map(String.init) ?? "None"), "
                    + "\(run.status.denied ?? 0) appel(s) refusé(s), \(where_ ?? "log déjà purgé")")
            }
        }
        return rows
    }

    /// The first non-empty line of the run's log, without markdown `*` / `#` around it.
    static func verdict(_ run: Run) -> String {
        guard let name = run.status.log,
              let data = try? Data(contentsOf: run.dir.appending(path: "logs").appending(path: name)) else {
            return "(log illisible)"
        }
        let markup = CharacterSet(charactersIn: "*#")
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: markup)
                .trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return String(text.prefix(200)) }
        }
        return "(log illisible)"
    }

    private static func when(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "dd/MM HH:mm"
        return format.string(from: date)
    }

    // MARK: Hook

    static func hook(_ input: Data, now: Date) {
        guard let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              let event = object["hook_event_name"] as? String else {
            printError("[schedulai] digest: no hook JSON on stdin")
            return
        }
        let session = (object["session_id"] as? String).flatMap(markName)
        let marks = root.appending(path: ".digest")
        pruneMarks(in: marks, now: now)
        let runs = loadRuns()
        let newest = runs.map(\.end).max()
        switch event {
        case "SessionStart":
            if let text = stateless(runs, now: now) { print(text) }
            if let session { writeMark(newest ?? now, session, in: marks) }
        case "UserPromptSubmit":
            guard let session else { return }
            guard let mark = readMark(session, in: marks) else {
                // The session-start digest already covered the past.
                writeMark(max(now, newest ?? now), session, in: marks)
                return
            }
            if let text = since(runs, mark: mark) { print(text) }
            if let newest, newest > mark { writeMark(newest, session, in: marks) }
        default:
            return
        }
    }

    /// A session id usable as a file name, else nil (no mark is kept).
    private static func markName(_ id: String) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard !id.isEmpty, id.count <= 200, !id.hasPrefix("."),
              id.unicodeScalars.allSatisfy({ allowed.contains($0) && $0.isASCII }) else { return nil }
        return id
    }

    private static func readMark(_ session: String, in marks: URL) -> Date? {
        guard let text = try? String(contentsOf: marks.appending(path: session), encoding: .utf8) else { return nil }
        return try? Date(text.trimmingCharacters(in: .whitespacesAndNewlines), strategy: .iso8601)
    }

    private static func writeMark(_ date: Date, _ session: String, in marks: URL) {
        do {
            try FileManager.default.createDirectory(at: marks, withIntermediateDirectories: true)
            try Data((date.formatted(.iso8601) + "\n").utf8).write(to: marks.appending(path: session), options: .atomic)
        } catch {
            printError("[schedulai] digest: cannot write the mark of \(session): \(error.localizedDescription)")
        }
    }

    /// Marks of sessions untouched for 14 days.
    private static func pruneMarks(in marks: URL, now: Date) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: marks, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files {
            guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(modified) > markLifetime else { continue }
            try? fm.removeItem(at: file)
        }
    }

    private static func printError(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
