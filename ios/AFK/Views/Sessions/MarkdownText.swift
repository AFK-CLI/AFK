import SwiftUI

// MARK: - Block-Level Parser

enum MarkdownBlock: Identifiable {
    case paragraph(AttributedString)
    case codeBlock(language: String?, code: String)
    case heading(level: Int, text: AttributedString)
    case unorderedListItem(text: AttributedString)
    case orderedListItem(index: Int, text: AttributedString)
    case blockquote(AttributedString)
    case table(headers: [String], rows: [[String]])
    case thematicBreak

    var id: String {
        switch self {
        case .paragraph(let t): return "p-\(t.hashValue)"
        case .codeBlock(let l, let c): return "code-\(l ?? "")-\(c.hashValue)"
        case .heading(let lv, let t): return "h\(lv)-\(t.hashValue)"
        case .unorderedListItem(let t): return "ul-\(t.hashValue)"
        case .orderedListItem(let i, let t): return "ol-\(i)-\(t.hashValue)"
        case .blockquote(let t): return "bq-\(t.hashValue)"
        case .table(let h, let r): return "tbl-\(h.hashValue)-\(r.count)"
        case .thematicBreak: return "hr-\(UUID().uuidString)"
        }
    }
}

enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var i = 0

        while i < lines.count {
            let line = lines[i]

            // Fenced code block
            if line.hasPrefix("```") {
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                let lang = language.isEmpty ? nil : language
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 } // skip closing ```
                blocks.append(.codeBlock(language: lang, code: codeLines.joined(separator: "\n")))
                continue
            }

            // Thematic break
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.count >= 3 && (
                trimmed.allSatisfy({ $0 == "-" || $0 == " " }) && trimmed.contains("-") ||
                trimmed.allSatisfy({ $0 == "*" || $0 == " " }) && trimmed.contains("*") ||
                trimmed.allSatisfy({ $0 == "_" || $0 == " " }) && trimmed.contains("_")
            ) && !line.hasPrefix("#") {
                // Check it's not a list item or heading
                if !line.hasPrefix("- ") && !line.hasPrefix("* ") {
                    blocks.append(.thematicBreak)
                    i += 1
                    continue
                }
            }

            // Heading
            if let headingMatch = parseHeading(line) {
                blocks.append(.heading(level: headingMatch.0, text: inlineMarkdown(headingMatch.1)))
                i += 1
                continue
            }

            // Table — a line with pipes that is followed by a separator row
            if isTableRow(line) && i + 1 < lines.count && isTableSeparator(lines[i + 1]) {
                let headers = parseTableCells(line)
                i += 2 // skip header + separator
                var rows: [[String]] = []
                while i < lines.count && isTableRow(lines[i]) {
                    rows.append(parseTableCells(lines[i]))
                    i += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                continue
            }

            // Blockquote (group consecutive lines)
            if line.hasPrefix("> ") || line == ">" {
                var quoteLines: [String] = []
                while i < lines.count && (lines[i].hasPrefix("> ") || lines[i] == ">") {
                    let content = lines[i].hasPrefix("> ") ? String(lines[i].dropFirst(2)) : ""
                    quoteLines.append(content)
                    i += 1
                }
                blocks.append(.blockquote(inlineMarkdown(quoteLines.joined(separator: "\n"))))
                continue
            }

            // Unordered list item
            if let listText = parseUnorderedListItem(line) {
                blocks.append(.unorderedListItem(text: inlineMarkdown(listText)))
                i += 1
                continue
            }

            // Ordered list item
            if let (index, listText) = parseOrderedListItem(line) {
                blocks.append(.orderedListItem(index: index, text: inlineMarkdown(listText)))
                i += 1
                continue
            }

            // Empty line — skip
            if trimmed.isEmpty {
                i += 1
                continue
            }

            // Paragraph — group consecutive non-empty, non-special lines
            var paraLines: [String] = []
            while i < lines.count {
                let pLine = lines[i]
                let pTrimmed = pLine.trimmingCharacters(in: .whitespaces)
                if pTrimmed.isEmpty || pLine.hasPrefix("```") || pLine.hasPrefix("> ") ||
                   pLine.hasPrefix("# ") || pLine.hasPrefix("## ") || pLine.hasPrefix("### ") ||
                   parseUnorderedListItem(pLine) != nil || parseOrderedListItem(pLine) != nil ||
                   (isTableRow(pLine) && i + 1 < lines.count && isTableSeparator(lines[i + 1])) {
                    break
                }
                paraLines.append(pLine)
                i += 1
            }
            if !paraLines.isEmpty {
                blocks.append(.paragraph(inlineMarkdown(paraLines.joined(separator: "\n"))))
            }
        }

        return blocks
    }

    private static func parseHeading(_ line: String) -> (Int, String)? {
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 }
            else { break }
        }
        guard level >= 1 && level <= 6 && line.count > level && line[line.index(line.startIndex, offsetBy: level)] == " " else {
            return nil
        }
        let text = String(line.dropFirst(level + 1))
        return (level, text)
    }

    private static func parseUnorderedListItem(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .init(charactersIn: " "))
        for prefix in ["- ", "* ", "+ "] {
            if trimmed.hasPrefix(prefix) {
                return String(trimmed.dropFirst(prefix.count))
            }
        }
        return nil
    }

    private static func parseOrderedListItem(_ line: String) -> (Int, String)? {
        let trimmed = line.trimmingCharacters(in: .init(charactersIn: " "))
        guard let dotIndex = trimmed.firstIndex(of: ".") else { return nil }
        let numStr = String(trimmed[trimmed.startIndex..<dotIndex])
        guard let num = Int(numStr), trimmed.index(after: dotIndex) < trimmed.endIndex,
              trimmed[trimmed.index(after: dotIndex)] == " " else { return nil }
        let text = String(trimmed[trimmed.index(dotIndex, offsetBy: 2)...])
        return (num, text)
    }

    // MARK: - Table Helpers

    private static func isTableRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("|") && !trimmed.hasPrefix("```")
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Separator lines contain only |, -, :, and spaces
        let allowed = CharacterSet(charactersIn: "|\\-: ")
        return trimmed.contains("|") && trimmed.contains("-") &&
               trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func parseTableCells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        // Strip leading/trailing pipes
        if trimmed.hasPrefix("|") { trimmed = String(trimmed.dropFirst()) }
        if trimmed.hasSuffix("|") { trimmed = String(trimmed.dropLast()) }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Converts inline markdown to AttributedString.
    /// Handles **bold**, *italic*, `code`, [links](url), ~~strikethrough~~.
    static func inlineMarkdown(_ text: String) -> AttributedString {
        // AttributedString(markdown:) handles inline formatting
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return attributed
        }
        return AttributedString(text)
    }
}

// MARK: - Markdown Rendering View

struct MarkdownText: View {
    let text: String
    var maxBlocks: Int? = nil

    private var blocks: [MarkdownBlock] {
        let all = MarkdownParser.parse(text)
        if let max = maxBlocks {
            return Array(all.prefix(max))
        }
        return all
    }

    private var isTruncated: Bool {
        if let max = maxBlocks {
            return MarkdownParser.parse(text).count > max
        }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { _, block in
                blockView(block)
            }
            if isTruncated {
                Text("\u{2026}")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(text)
                .font(.body)
                .textSelection(.enabled)

        case .codeBlock(let language, let code):
            CodeSnippetView(code: code, language: language)

        case .heading(let level, let text):
            Text(text)
                .font(headingFont(level))
                .fontWeight(level <= 2 ? .bold : .semibold)
                .textSelection(.enabled)
                .padding(.top, level <= 2 ? 4 : 2)

        case .unorderedListItem(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\u{2022}")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
            }
            .padding(.leading, 4)

        case .orderedListItem(let index, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(index).")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 20, alignment: .trailing)
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
            }
            .padding(.leading, 4)

        case .blockquote(let text):
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor.opacity(0.4))
                    .frame(width: 3)
                Text(text)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 10)
            }
            .padding(.vertical, 2)

        case .table(let headers, let rows):
            MarkdownTableView(headers: headers, rows: rows)

        case .thematicBreak:
            Divider()
                .padding(.vertical, 4)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2
        case 2: return .title3
        case 3: return .headline
        case 4: return .subheadline
        default: return .callout
        }
    }
}

// MARK: - Table View

private struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]

    private var columnCount: Int { headers.count }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                // Header row
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { col in
                        Text(MarkdownParser.inlineMarkdown(headers[col]))
                            .font(.subheadline.weight(.semibold))
                            .textSelection(.enabled)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .background(Color(UIColor.tertiarySystemGroupedBackground))

                Divider()

                // Data rows
                ForEach(0..<rows.count, id: \.self) { rowIdx in
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { col in
                            let cell = col < rows[rowIdx].count ? rows[rowIdx][col] : ""
                            Text(MarkdownParser.inlineMarkdown(cell))
                                .font(.subheadline)
                                .textSelection(.enabled)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if rowIdx < rows.count - 1 {
                        Divider()
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(UIColor.separator).opacity(0.3), lineWidth: 0.5)
            )
        }
    }
}
