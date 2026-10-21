import Foundation

/// One `StartCalendarInterval` entry. `weekday` uses launchd's numbering:
/// 0 = Sunday … 6 = Saturday; nil means every day.
struct CalendarSlot: Hashable {
    var weekday: Int?
    var hour: Int
    var minute: Int
}

struct ScheduleError: Error {
    let message: String
}

/// The `schedule:` line of a prompt.md, e.g. `08:00`, `weekdays 08:00`,
/// `mon,thu 09:30`, `08:00, 14:00`, `every 30m`, `every 2h`.
enum Schedule: Equatable {
    case calendar([CalendarSlot])
    case interval(seconds: Int)

    private static let dayNames: [String: Int] = [
        "sun": 0, "sunday": 0, "dim": 0, "dimanche": 0,
        "mon": 1, "monday": 1, "lun": 1, "lundi": 1,
        "tue": 2, "tuesday": 2, "mar": 2, "mardi": 2,
        "wed": 3, "wednesday": 3, "mer": 3, "mercredi": 3,
        "thu": 4, "thursday": 4, "jeu": 4, "jeudi": 4,
        "fri": 5, "friday": 5, "ven": 5, "vendredi": 5,
        "sat": 6, "saturday": 6, "sam": 6, "samedi": 6,
    ]
    private static var shortDayNames: [String] {
        L10n.lang == "fr" ? ["dim", "lun", "mar", "mer", "jeu", "ven", "sam"]
                          : ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    }

    static func parse(_ text: String) throws -> Schedule {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
        if lower.isEmpty {
            throw ScheduleError(message: tr("No `schedule:` line in the frontmatter."))
        }
        if lower.hasPrefix("every ") {
            let amount = lower.dropFirst("every ".count).trimmingCharacters(in: .whitespaces)
            guard let unit = amount.last, let n = Int(amount.dropLast()), n > 0,
                  unit == "m" || unit == "h" else {
                throw ScheduleError(message: tr("\"%@\": write e.g. `every 30m` or `every 2h`.", text))
            }
            return .interval(seconds: n * (unit == "h" ? 3600 : 60))
        }

        var weekdays: [Int] = []
        var times: [(hour: Int, minute: Int)] = []
        for token in lower.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init) {
            if token.contains(":") {
                let parts = token.split(separator: ":")
                guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
                      (0..<24).contains(h), (0..<60).contains(m) else {
                    throw ScheduleError(message: tr("\"%@\" is not a valid time (HH:MM).", token))
                }
                times.append((h, m))
            } else if token == "daily" || token == "everyday" {
                continue
            } else if token == "weekdays" || token == "semaine" {
                weekdays += [1, 2, 3, 4, 5]
            } else if let day = dayNames[token] {
                weekdays.append(day)
            } else {
                throw ScheduleError(message: tr("\"%@\" is neither a day nor a time.", token))
            }
        }
        if times.isEmpty {
            throw ScheduleError(message: tr("\"%@\": a time (HH:MM) is missing.", text))
        }
        let days: [Int?] = weekdays.isEmpty ? [nil] : Array(Set(weekdays)).sorted()
        return .calendar(days.flatMap { day in
            times.map { CalendarSlot(weekday: day, hour: $0.hour, minute: $0.minute) }
        })
    }

    var summary: String {
        switch self {
        case .interval(let seconds):
            return seconds % 3600 == 0 ? tr("Every %@ h", "\(seconds / 3600)") : tr("Every %@ min", "\(seconds / 60)")
        case .calendar(let slots):
            let times = Set(slots.map { String(format: "%02d:%02d", $0.hour, $0.minute) }).sorted()
            let days = Set(slots.compactMap(\.weekday)).sorted()
            let dayText: String
            if days.isEmpty {
                dayText = tr("Every day")
            } else if days == [1, 2, 3, 4, 5] {
                dayText = tr("Weekdays")
            } else {
                dayText = days.map { Self.shortDayNames[$0] }.joined(separator: ", ")
            }
            return tr("%@ at %@", dayText, times.joined(separator: ", "))
        }
    }

    /// The keys this schedule adds to the job's LaunchAgent plist.
    var launchdKeys: [String: Any] {
        switch self {
        case .interval(let seconds):
            return ["StartInterval": seconds]
        case .calendar(let slots):
            return ["StartCalendarInterval": slots.map { slot -> [String: Int] in
                var entry = ["Hour": slot.hour, "Minute": slot.minute]
                if let weekday = slot.weekday { entry["Weekday"] = weekday }
                return entry
            }]
        }
    }

    func nextRun(after date: Date, calendar: Calendar = .current) -> Date? {
        guard case .calendar(let slots) = self else { return nil }
        return slots.compactMap { slot in
            var components = DateComponents()
            components.hour = slot.hour
            components.minute = slot.minute
            // Foundation counts Sunday as 1, launchd as 0.
            if let weekday = slot.weekday { components.weekday = weekday + 1 }
            return calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime)
        }.min()
    }
}

/// A prompt.md: an optional `---` frontmatter of `key: value` lines, then the prompt.
struct PromptFile {
    var meta: [String: String]
    var body: String

    static func parse(_ text: String) -> PromptFile {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.indices.dropFirst().first(where: {
                  lines[$0].trimmingCharacters(in: .whitespaces) == "---"
              }) else {
            return PromptFile(meta: [:], body: text)
        }
        var meta: [String: String] = [:]
        for line in lines[1..<end] where !line.hasPrefix("#") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.first == "\"", value.last == "\"" {
                value = String(value.dropFirst().dropLast())
            }
            meta[key] = value
        }
        return PromptFile(meta: meta, body: lines[(end + 1)...].joined(separator: "\n"))
    }

    /// `text` with one frontmatter line set (or removed, for nil), the rest untouched.
    /// Adds a frontmatter when the file has none.
    static func setting(_ key: String, to value: String?, in text: String) -> String {
        let line = value.map { "\(key): \(quoted($0))" }
        var lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.indices.dropFirst().first(where: {
                  lines[$0].trimmingCharacters(in: .whitespaces) == "---"
              }) else {
            return line.map { "---\n\($0)\n---\n" + text } ?? text
        }
        if let index = lines[1..<end].firstIndex(where: {
            $0.split(separator: ":", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) == key
        }) {
            if let line { lines[index] = line } else { lines.remove(at: index) }
        } else if let line {
            // Right after `name:` when there is one, so the two read together.
            let nameIndex = lines[1..<end].firstIndex(where: { $0.hasPrefix("name:") })
            lines.insert(line, at: nameIndex.map { $0 + 1 } ?? end)
        }
        return lines.joined(separator: "\n")
    }

    /// One line, quoted when YAML-ish readers could misread it.
    private static func quoted(_ value: String) -> String {
        let flat = value.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let needsQuotes = flat.contains(":") || flat.contains("#") || flat.hasPrefix("\"") || flat.hasPrefix("'")
        return needsQuotes ? "\"\(flat.replacingOccurrences(of: "\"", with: "'"))\"" : flat
    }
}

/// What run-job.sh writes to <job dir>/status.json.
struct RunStatus: Decodable, Hashable {
    var startedAt: Date
    var endedAt: Date?
    var exitCode: Int?
    var log: String?
}

struct Job: Identifiable {
    enum State {
        case never, running, succeeded, failed
    }

    let id: String
    let dir: URL
    var name: String
    /// The frontmatter's `description:`, nil when absent or empty.
    var about: String?
    var scheduleText: String
    var schedule: Schedule?
    var scheduleError: String?
    var workdir: String
    var allowedTools: String
    var model: String?
    var prompt: String
    var enabled: Bool
    var runningPID: Int32?
    var status: RunStatus?
    /// Finished and running runs, newest first (history.jsonl, else status.json).
    var history: [RunStatus]
    var logs: [URL]

    var label: String { "com.charlesparis.schedulai.\(id)" }
    var promptURL: URL { dir.appending(path: "prompt.md") }
    var expandedWorkdir: String {
        workdir.hasPrefix("~") ? URL.homeDirectory.path + workdir.dropFirst() : workdir
    }

    var state: State {
        if runningPID != nil { return .running }
        guard let status, let exitCode = status.exitCode else { return .never }
        return exitCode == 0 ? .succeeded : .failed
    }

    var lastRunText: String {
        guard let status else { return tr("Never run") }
        let when = L10n.relative(status.startedAt)
        switch state {
        case .running: return tr("Running, started %@", when)
        case .succeeded: return tr("OK %@", when)
        case .failed: return tr("Failed (%@) %@", "\(status.exitCode ?? -1)", when)
        case .never: return tr("Interrupted %@", when)
        }
    }
}
