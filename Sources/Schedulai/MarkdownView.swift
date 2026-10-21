import SwiftUI

/// A run's report, which `claude -p` writes in Markdown: headings, lists,
/// tables, code blocks and paragraphs as blocks, the rest as inline Markdown.
/// Anything it does not recognise stays a plain paragraph.
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    enum Block {
        case heading(Int, String)
        case paragraph(String)
        case bullets([String])
        case table([[String]])
        case code(String)
        case rule
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Self.inline(text)
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, 4)
        case .paragraph(let text):
            Self.inline(text)
                .fixedSize(horizontal: false, vertical: true)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(Color.brand).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
                        Self.inline(item).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .table(let rows):
            table(rows)
        case .code(let code):
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.primary.opacity(0.06), in: .rect(cornerRadius: 8))
        case .rule:
            Divider()
        }
    }

    private func table(_ rows: [[String]]) -> some View {
        let columns = rows.map(\.count).max() ?? 0
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 7) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        Self.inline(column < row.count ? row[column] : "")
                            .fontWeight(index == 0 ? .semibold : .regular)
                            .foregroundStyle(index == 0 ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if index == 0 {
                    Divider().gridCellUnsizedAxes(.horizontal)
                }
            }
        }
        .padding(12)
        .background(.primary.opacity(0.04), in: .rect(cornerRadius: 10))
    }

    static func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: text, options: options) {
            return Text(attributed)
        }
        return Text(text)
    }

    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var tableRows: [[String]] = []
        var code: [String]?

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !bullets.isEmpty { blocks.append(.bullets(bullets)); bullets = [] }
            if !tableRows.isEmpty { blocks.append(.table(tableRows)); tableRows = [] }
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(rawLine)
                continue
            }
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("|") {
                if !bullets.isEmpty || !paragraph.isEmpty { flush() }
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                // The |---|---| line under the header.
                if cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-:".contains($0) } }) { continue }
                tableRows.append(cells)
            } else if let level = line.firstIndex(where: { $0 != "#" }).map({ line.distance(from: line.startIndex, to: $0) }),
                      (1...4).contains(level), line.dropFirst(level).first == " " {
                flush()
                blocks.append(.heading(level, String(line.dropFirst(level + 1))))
            } else if line == "---" || line == "***" {
                flush()
                blocks.append(.rule)
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                if !paragraph.isEmpty || !tableRows.isEmpty { flush() }
                bullets.append(String(line.dropFirst(2)))
            } else {
                if !bullets.isEmpty || !tableRows.isEmpty { flush() }
                paragraph.append(line)
            }
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }
}
