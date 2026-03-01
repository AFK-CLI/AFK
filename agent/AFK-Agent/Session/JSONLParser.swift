//
//  JSONLParser.swift
//  AFK-Agent
//

import Foundation

actor JSONLParser {
    private var fileOffsets: [String: UInt64] = [:]

    func parseNewEntries(at path: String) throws -> [RawJSONLEntry] {
        let fileURL = URL(fileURLWithPath: path)
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let offset = fileOffsets[path] ?? 0
        try handle.seek(toOffset: offset)

        let data = handle.readDataToEndOfFile()
        let newOffset = offset + UInt64(data.count)
        fileOffsets[path] = newOffset

        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return []
        }

        let decoder = JSONDecoder()
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let lineData = String(line).data(using: .utf8) else { return nil }
            return try? decoder.decode(RawJSONLEntry.self, from: lineData)
        }
    }

    /// Fast-forward offset to end of file so only new appends are parsed.
    func fastForwardToEnd(_ path: String) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64 else { return }
        fileOffsets[path] = size
    }

    func currentOffset(for path: String) -> UInt64 {
        fileOffsets[path] ?? 0
    }

    /// Restore a previously saved byte offset (for restart recovery).
    func setOffset(for path: String, to offset: UInt64) {
        fileOffsets[path] = offset
    }
}
