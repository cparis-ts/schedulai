import Foundation

/// The prompts' versions: ~/.claude/scheduled is a git repository of the
/// prompt.md files alone. The app commits its own edits; run-job.sh commits
/// any other before a run, so each run names the version it ran.
enum PromptHistory {
    struct Version: Identifiable, Hashable {
        let rev: String
        let date: Date
        let message: String
        var id: String { rev }
    }

    /// git needs the Command Line Tools; without them /usr/bin/git opens an install dialog.
    static let available: Bool = {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }()

    /// Commits the job's prompt.md when it changed (a deleted one too).
    static func commit(_ job: Job, _ message: String) {
        guard available else { return }
        let root = job.dir.deletingLastPathComponent()
        let path = "\(job.id)/prompt.md"
        if !FileManager.default.fileExists(atPath: root.appending(path: ".git").path) {
            guard git(root, "init", "-q") != nil else { return }
            try? "*\n!*/\n!*/prompt.md\n!.gitignore\n".write(to: root.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
            _ = git(root, "add", ".gitignore")
        }
        let tracked = !(git(root, "ls-files", "--", path) ?? "").isEmpty
        _ = git(root, "add", "-A", "--", path)
        if git(root, "diff", "--cached", "--quiet", "--", path) == nil {
            _ = git(root, "commit", "-q", "-m", "\(job.id): \(tracked ? message : "first version")", "--", path, ".gitignore")
        }
    }

    /// Newest first.
    static func versions(_ job: Job, limit: Int = 30) -> [Version] {
        guard available, let output = git(job.dir.deletingLastPathComponent(), "log", "-n", "\(limit)",
                                          "--format=%h%x09%cI%x09%s", "--", "\(job.id)/prompt.md") else { return [] }
        let formatter = ISO8601DateFormatter()
        return output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard fields.count == 3, let date = formatter.date(from: fields[1]) else { return nil }
            return Version(rev: fields[0], date: date, message: fields[2])
        }
    }

    static func text(_ job: Job, at rev: String) -> String? {
        git(job.dir.deletingLastPathComponent(), "show", "\(rev):\(job.id)/prompt.md")
    }

    /// The command's output, or nil when it failed.
    @discardableResult
    private static func git(_ root: URL, _ args: String...) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "-c", "user.name=SchedulAI", "-c", "user.email=schedulai@localhost",
                             "-c", "commit.gpgsign=false"] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
