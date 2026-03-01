import SwiftUI

struct CodeSnippetView: View {
    let code: String
    let language: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with language tag and copy button
            if language != nil || true {
                HStack {
                    if let lang = language, !lang.isEmpty {
                        Text(lang)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color(UIColor.systemGray5), in: Capsule())
                    }
                    Spacer()
                    Button {
                        UIPasteboard.general.string = code
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copied = false
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            if copied {
                                Text("Copied")
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(copied ? .green : .secondary)
                        .animation(.easeInOut(duration: 0.2), value: copied)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }

            // Code content
            ScrollView(.horizontal, showsIndicators: false) {
                Text(highlightedCode)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
        .background(Color(UIColor.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(UIColor.separator).opacity(0.3), lineWidth: 0.5)
        )
    }

    // MARK: - Basic Syntax Highlighting

    private var highlightedCode: AttributedString {
        var result = AttributedString(code)
        let lang = language?.lowercased() ?? ""

        // Apply keyword highlighting for common languages
        let keywords = Self.keywords(for: lang)
        guard !keywords.isEmpty else { return result }

        for keyword in keywords {
            // Match whole words only
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: keyword))\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsString = code as NSString
            let matches = regex.matches(in: code, range: NSRange(location: 0, length: nsString.length))
            for match in matches {
                guard let range = Range(match.range, in: code),
                      let attrRange = Range(range, in: result) else { continue }
                result[attrRange].foregroundColor = keywordColor(for: lang)
            }
        }

        // Highlight strings
        highlightStrings(in: &result, code: code)

        // Highlight comments
        highlightComments(in: &result, code: code, lang: lang)

        return result
    }

    private func highlightStrings(in result: inout AttributedString, code: String) {
        let pattern = #"("[^"\\]*(?:\\.[^"\\]*)*"|'[^'\\]*(?:\\.[^'\\]*)*')"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let nsString = code as NSString
        let matches = regex.matches(in: code, range: NSRange(location: 0, length: nsString.length))
        for match in matches {
            guard let range = Range(match.range, in: code),
                  let attrRange = Range(range, in: result) else { continue }
            result[attrRange].foregroundColor = .green.opacity(0.8)
        }
    }

    private func highlightComments(in result: inout AttributedString, code: String, lang: String) {
        // Single-line comments
        let commentPrefix = (lang == "py" || lang == "python" || lang == "ruby" || lang == "bash" || lang == "sh" || lang == "zsh") ? "#" : "//"
        let pattern = "\(NSRegularExpression.escapedPattern(for: commentPrefix)).*$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else { return }
        let nsString = code as NSString
        let matches = regex.matches(in: code, range: NSRange(location: 0, length: nsString.length))
        for match in matches {
            guard let range = Range(match.range, in: code),
                  let attrRange = Range(range, in: result) else { continue }
            result[attrRange].foregroundColor = .gray
        }
    }

    private func keywordColor(for lang: String) -> Color {
        switch lang {
        case "swift", "go", "rust": return .pink
        case "python", "py": return .orange
        case "javascript", "js", "typescript", "ts": return .cyan
        default: return .pink
        }
    }

    private static func keywords(for lang: String) -> [String] {
        switch lang {
        case "swift":
            return ["func", "var", "let", "struct", "class", "enum", "protocol", "import",
                    "return", "if", "else", "guard", "for", "while", "switch", "case",
                    "self", "Self", "nil", "true", "false", "private", "public", "static",
                    "async", "await", "throws", "try", "catch", "some", "any", "init"]
        case "go", "golang":
            return ["func", "var", "const", "type", "struct", "interface", "package", "import",
                    "return", "if", "else", "for", "range", "switch", "case", "default",
                    "nil", "true", "false", "go", "defer", "chan", "map", "select", "break"]
        case "python", "py":
            return ["def", "class", "import", "from", "return", "if", "elif", "else",
                    "for", "while", "try", "except", "finally", "with", "as", "yield",
                    "None", "True", "False", "self", "lambda", "pass", "raise", "async", "await"]
        case "javascript", "js", "typescript", "ts":
            return ["function", "const", "let", "var", "class", "import", "export", "from",
                    "return", "if", "else", "for", "while", "switch", "case", "default",
                    "null", "undefined", "true", "false", "this", "new", "async", "await",
                    "try", "catch", "throw", "interface", "type", "enum"]
        case "rust":
            return ["fn", "let", "mut", "struct", "enum", "impl", "trait", "use", "mod",
                    "pub", "return", "if", "else", "for", "while", "match", "loop",
                    "self", "Self", "true", "false", "async", "await", "move", "where"]
        case "bash", "sh", "zsh":
            return ["if", "then", "else", "elif", "fi", "for", "do", "done", "while",
                    "case", "esac", "function", "return", "exit", "echo", "export", "local"]
        default:
            return []
        }
    }
}
