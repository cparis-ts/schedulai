import Foundation

/// `schedulai hooks install|uninstall`: the two Claude Code hooks that run
/// `schedulai digest --hook` (SessionStart and UserPromptSubmit), in
/// `~/.claude/settings.json` (`$CLAUDE_CONFIG_DIR/settings.json` when set, as
/// Claude Code reads it). Claude Code only: Codex and Gemini CLI have no such hooks.
///
/// The file is edited as ordered JSON, so every other key, hook and value keeps
/// its place and its text; the previous version is kept as `settings.json.schedulai-backup`.
enum Hooks {
    static let events = ["SessionStart", "UserPromptSubmit"]

    static var settingsURL: URL {
        let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(filePath: $0) }
            ?? URL.homeDirectory.appending(path: ".claude")
        return dir.appending(path: "settings.json")
    }

    /// This very binary: whatever runs `hooks install` knows `digest`.
    static var command: String {
        let path = (Bundle.main.executableURL ?? URL(filePath: CommandLine.arguments[0])).resolvingSymlinksInPath().path
        let quoted = path.contains(where: { " '\"$\\`".contains($0) }) ? "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'" : path
        return "\(quoted) digest --hook"
    }

    /// Ours, whatever path an earlier install wrote.
    static func isOurs(_ command: String) -> Bool {
        command.hasSuffix(" digest --hook") && command.lowercased().contains("schedulai")
    }

    static func run(_ args: [String]) -> Int32 {
        switch args {
        case ["install"]: return apply(install: true)
        case ["uninstall"]: return apply(install: false)
        default:
            printError("usage: schedulai hooks install|uninstall")
            return 2
        }
    }

    private static func apply(install: Bool) -> Int32 {
        let url = settingsURL
        let fm = FileManager.default
        var root: JSON = .object([])
        var original: Data?
        if fm.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                original = data
                if !String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    root = try JSON.parse(data)
                }
            } catch {
                printError("cannot read \(url.path): \(error) — nothing changed")
                return 1
            }
        }
        guard case .object = root else {
            printError("\(url.path) is not a JSON object — nothing changed")
            return 1
        }

        var changed = false
        var hooks = root["hooks"] ?? .object([])
        guard case .object = hooks else {
            printError("\(url.path): \"hooks\" is not an object — nothing changed")
            return 1
        }
        let wanted = command
        for event in events {
            var groups = hooks[event] ?? .array([])
            guard case .array(var list) = groups else {
                printError("\(url.path): hooks.\(event) is not an array — nothing changed")
                return 1
            }
            var found = false
            for g in list.indices {
                guard case .array(var entries)? = list[g]["hooks"] else { continue }
                var kept: [JSON] = []
                for entry in entries {
                    guard let cmd = entry["command"]?.string, isOurs(cmd) else { kept.append(entry); continue }
                    if install && !found {
                        found = true
                        if cmd != wanted || entry["timeout"]?.raw != "5" {
                            kept.append(hookEntry(wanted))
                            changed = true
                        } else {
                            kept.append(entry)
                        }
                    } else {
                        changed = true // a duplicate, or uninstalling
                    }
                }
                entries = kept
                list[g]["hooks"] = .array(entries)
            }
            // Groups we emptied go; others are left exactly as they were.
            list.removeAll { group in
                if case .array(let entries)? = group["hooks"] { return entries.isEmpty }
                return false
            }
            if install && !found {
                list.append(.object([("hooks", .array([hookEntry(wanted)]))]))
                changed = true
            }
            groups = .array(list)
            hooks[event] = list.isEmpty ? nil : groups
        }
        if case .object(let pairs) = hooks, pairs.isEmpty {
            root["hooks"] = nil
        } else {
            root["hooks"] = hooks
        }

        if changed {
            do {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let original {
                    try original.write(to: url.appendingPathExtension("schedulai-backup"), options: .atomic)
                }
                try Data((root.text() + "\n").utf8).write(to: url, options: .atomic)
            } catch {
                printError("cannot write \(url.path): \(error.localizedDescription)")
                return 1
            }
        }
        if install {
            print(changed ? "installed: SessionStart and UserPromptSubmit run `\(wanted)` (\(url.path))"
                          : "already installed (\(url.path))")
        } else {
            print(changed ? "uninstalled: the digest hooks are gone from \(url.path)" : "not installed (\(url.path))")
        }
        if changed, original != nil {
            print("backup: \(url.appendingPathExtension("schedulai-backup").path)")
        }
        if install, let other = otherDigests(root) {
            print("note: another digest hook is still there — remove it, or sessions read the digest twice: \(other)")
        }
        return 0
    }

    private static func hookEntry(_ command: String) -> JSON {
        .object([("type", .string("command")), ("command", .string(command)), ("timeout", .raw("5"))])
    }

    /// The Python prototype this command replaces (`schedulai_digest.py`).
    private static func otherDigests(_ root: JSON) -> String? {
        guard case .object(let events)? = root["hooks"] else { return nil }
        for (_, groups) in events {
            guard case .array(let list) = groups else { continue }
            for group in list {
                guard case .array(let entries)? = group["hooks"] else { continue }
                for entry in entries {
                    if let cmd = entry["command"]?.string, !isOurs(cmd), cmd.contains("schedulai_digest") { return cmd }
                }
            }
        }
        return nil
    }

    private static func printError(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}

/// JSON that keeps its key order and the source text of its scalars, so that
/// rewriting a file changes only what was edited. Printed two-space indented,
/// as Claude Code writes settings.json.
indirect enum JSON {
    case object([(String, JSON)])
    case array([JSON])
    /// A number, true, false, null or a string, exactly as written (strings with their quotes).
    case raw(String)

    static func string(_ value: String) -> JSON {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return .raw(out + "\"")
    }

    var raw: String? { if case .raw(let text) = self { return text } else { return nil } }

    /// The decoded value of a string scalar.
    var string: String? {
        guard let raw, raw.hasPrefix("\"") else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed)) as? String
    }

    subscript(key: String) -> JSON? {
        get {
            guard case .object(let pairs) = self else { return nil }
            return pairs.first { $0.0 == key }?.1
        }
        set {
            guard case .object(var pairs) = self else { return }
            if let index = pairs.firstIndex(where: { $0.0 == key }) {
                if let newValue { pairs[index].1 = newValue } else { pairs.remove(at: index) }
            } else if let newValue {
                pairs.append((key, newValue))
            }
            self = .object(pairs)
        }
    }

    func text(_ indent: String = "") -> String {
        let inner = indent + "  "
        switch self {
        case .raw(let text): return text
        case .array(let items):
            if items.isEmpty { return "[]" }
            return "[\n" + items.map { inner + $0.text(inner) }.joined(separator: ",\n") + "\n\(indent)]"
        case .object(let pairs):
            if pairs.isEmpty { return "{}" }
            return "{\n" + pairs.map { "\(inner)\(JSON.string($0.0).raw!): \($0.1.text(inner))" }.joined(separator: ",\n") + "\n\(indent)}"
        }
    }

    struct ParseError: Error, CustomStringConvertible {
        let description: String
    }

    static func parse(_ data: Data) throws -> JSON {
        // Validates the whole document first: the parser below can then trust its input.
        _ = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        var parser = Parser(bytes: Array(data))
        let value = try parser.value()
        parser.skipSpace()
        guard parser.index == parser.bytes.count else { throw ParseError(description: "trailing characters") }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[index]) { index += 1 }
        }

        mutating func value() throws -> JSON {
            skipSpace()
            guard index < bytes.count else { throw ParseError(description: "unexpected end") }
            switch bytes[index] {
            case UInt8(ascii: "{"):
                index += 1
                var pairs: [(String, JSON)] = []
                skipSpace()
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(pairs) }
                while true {
                    skipSpace()
                    let key = try stringToken()
                    guard let name = JSON.raw(key).string else { throw ParseError(description: "bad key \(key)") }
                    skipSpace()
                    index += 1 // ':'
                    pairs.append((name, try value()))
                    skipSpace()
                    let separator = bytes[index]
                    index += 1
                    if separator == UInt8(ascii: "}") { return .object(pairs) }
                }
            case UInt8(ascii: "["):
                index += 1
                var items: [JSON] = []
                skipSpace()
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                while true {
                    items.append(try value())
                    skipSpace()
                    let separator = bytes[index]
                    index += 1
                    if separator == UInt8(ascii: "]") { return .array(items) }
                }
            case UInt8(ascii: "\""):
                return .raw(try stringToken())
            default:
                let start = index
                while index < bytes.count, !",]} \n\r\t".utf8.contains(bytes[index]) { index += 1 }
                return .raw(String(decoding: bytes[start..<index], as: UTF8.self))
            }
        }

        mutating func stringToken() throws -> String {
            let start = index
            index += 1
            while index < bytes.count, bytes[index] != UInt8(ascii: "\"") {
                index += bytes[index] == UInt8(ascii: "\\") ? 2 : 1
            }
            guard index < bytes.count else { throw ParseError(description: "unterminated string") }
            index += 1
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }
    }
}
