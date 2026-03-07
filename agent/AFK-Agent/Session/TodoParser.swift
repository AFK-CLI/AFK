//
//  TodoParser.swift
//  AFK-Agent
//

import Foundation

struct TodoItem: Sendable {
    let text: String
    let checked: Bool
    let inProgress: Bool
    let line: Int
}

struct TodoParser {
    /// Parse todo.md content into structured items.
    /// Recognized formats:
    ///   - [ ] text  (unchecked)
    ///   - [x] text  (checked, case-insensitive)
    ///   - text      (plain list item, treated as unchecked)
    static func parse(_ content: String) -> [TodoItem] {
        var items: [TodoItem] = []
        let lines = content.components(separatedBy: .newlines)

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Must start with "- "
            guard trimmed.hasPrefix("- ") else { continue }
            let afterDash = String(trimmed.dropFirst(2))

            if afterDash.hasPrefix("[ ] ") {
                let text = String(afterDash.dropFirst(4))
                if !text.isEmpty {
                    items.append(TodoItem(text: text, checked: false, inProgress: false, line: index + 1))
                }
            } else if afterDash.hasPrefix("[*] ") {
                let text = String(afterDash.dropFirst(4))
                if !text.isEmpty {
                    items.append(TodoItem(text: text, checked: false, inProgress: true, line: index + 1))
                }
            } else if afterDash.hasPrefix("[x] ") || afterDash.hasPrefix("[X] ") {
                let text = String(afterDash.dropFirst(4))
                if !text.isEmpty {
                    items.append(TodoItem(text: text, checked: true, inProgress: false, line: index + 1))
                }
            } else {
                // Plain list item with no checkbox
                let text = afterDash
                if !text.isEmpty {
                    items.append(TodoItem(text: text, checked: false, inProgress: false, line: index + 1))
                }
            }
        }

        return items
    }
}
