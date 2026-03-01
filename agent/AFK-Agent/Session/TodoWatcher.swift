//
//  TodoWatcher.swift
//  AFK-Agent
//

import Foundation
import CryptoKit

actor TodoWatcher {
    private let sessionIndex: SessionIndex
    private let onChange: @Sendable (String, String, String, [TodoItem]) async -> Void
    private var lastHashes: [String: String] = [:]
    private var isRunning = false

    /// - Parameters:
    ///   - sessionIndex: Used to discover project paths.
    ///   - onChange: Called when a todo.md changes. Parameters: projectPath, contentHash, rawContent, items.
    init(sessionIndex: SessionIndex,
         onChange: @escaping @Sendable (String, String, String, [TodoItem]) async -> Void) {
        self.sessionIndex = sessionIndex
        self.onChange = onChange
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        print("[TodoWatcher] Started scanning for todo.md changes")

        Task { [weak self] in
            while let self, await self.isRunning {
                await self.scan()
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
            }
        }
    }

    func stop() {
        isRunning = false
    }

    private func scan() async {
        let projectPaths = await sessionIndex.allProjectPaths()

        for projectPath in projectPaths {
            let todoPath = (projectPath as NSString).appendingPathComponent("todo.md")
            let fm = FileManager.default

            guard fm.fileExists(atPath: todoPath),
                  let data = fm.contents(atPath: todoPath) else {
                continue
            }

            let hash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()

            if lastHashes[projectPath] != hash {
                lastHashes[projectPath] = hash
                let content = String(data: data, encoding: .utf8) ?? ""
                let items = TodoParser.parse(content)
                print("[TodoWatcher] Change detected in \(projectPath)/todo.md (\(items.count) items)")
                await onChange(projectPath, hash, content, items)
            }
        }
    }
}
