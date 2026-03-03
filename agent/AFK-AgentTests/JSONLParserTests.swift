import XCTest
@testable import AFK_Agent

final class JSONLParserTests: XCTestCase {

    private var parser: JSONLParser!
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        parser = JSONLParser()
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        try await super.tearDown()
    }

    private func writeTempFile(_ content: String, named: String = "test.jsonl") -> String {
        let url = tmpDir.appendingPathComponent(named)
        try! content.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    // MARK: - Basic Parsing

    func testParseSingleLine() async throws {
        let json = #"{"type":"user","uuid":"abc"}"#
        let path = writeTempFile(json + "\n")

        let entries = try await parser.parseNewEntries(at: path)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].type, "user")
        XCTAssertEqual(entries[0].uuid, "abc")
    }

    func testParseMultipleLines() async throws {
        let lines = [
            #"{"type":"user","uuid":"1"}"#,
            #"{"type":"assistant","uuid":"2"}"#,
            #"{"type":"system","uuid":"3"}"#,
        ]
        let path = writeTempFile(lines.joined(separator: "\n") + "\n")

        let entries = try await parser.parseNewEntries(at: path)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].type, "user")
        XCTAssertEqual(entries[1].type, "assistant")
        XCTAssertEqual(entries[2].type, "system")
    }

    func testEmptyFileReturnsEmpty() async throws {
        let path = writeTempFile("")
        let entries = try await parser.parseNewEntries(at: path)
        XCTAssertTrue(entries.isEmpty)
    }

    func testMalformedLineSkipped() async throws {
        let lines = [
            #"{"type":"user","uuid":"1"}"#,
            "not json at all",
            #"{"type":"assistant","uuid":"2"}"#,
        ]
        let path = writeTempFile(lines.joined(separator: "\n") + "\n")

        let entries = try await parser.parseNewEntries(at: path)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].type, "user")
        XCTAssertEqual(entries[1].type, "assistant")
    }

    // MARK: - Offset / Incremental Parsing

    func testIncrementalParsing() async throws {
        let line1 = #"{"type":"user","uuid":"1"}"# + "\n"
        let url = tmpDir.appendingPathComponent("incremental.jsonl")
        try line1.write(to: url, atomically: true, encoding: .utf8)
        let path = url.path

        // First read
        let entries1 = try await parser.parseNewEntries(at: path)
        XCTAssertEqual(entries1.count, 1)

        // Append more data
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        let line2 = #"{"type":"assistant","uuid":"2"}"# + "\n"
        handle.write(line2.data(using: .utf8)!)
        try handle.close()

        // Second read should only return new data
        let entries2 = try await parser.parseNewEntries(at: path)
        XCTAssertEqual(entries2.count, 1)
        XCTAssertEqual(entries2[0].type, "assistant")
    }

    func testCurrentOffset() async throws {
        let path = writeTempFile("")
        let offset = await parser.currentOffset(for: path)
        XCTAssertEqual(offset, 0)
    }

    func testSetOffset() async throws {
        let path = "dummy/path.jsonl"
        await parser.setOffset(for: path, to: 42)
        let offset = await parser.currentOffset(for: path)
        XCTAssertEqual(offset, 42)
    }

    // MARK: - Fast Forward

    func testFastForwardToEnd() async throws {
        let content = #"{"type":"user","uuid":"1"}"# + "\n" + #"{"type":"user","uuid":"2"}"# + "\n"
        let path = writeTempFile(content)

        // Fast-forward past all existing content
        await parser.fastForwardToEnd(path)

        // Parsing should return nothing
        let entries = try await parser.parseNewEntries(at: path)
        XCTAssertTrue(entries.isEmpty)
    }

    func testFastForwardThenNewData() async throws {
        let content = #"{"type":"user","uuid":"1"}"# + "\n"
        let url = tmpDir.appendingPathComponent("ff.jsonl")
        try content.write(to: url, atomically: true, encoding: .utf8)
        let path = url.path

        // Fast-forward
        await parser.fastForwardToEnd(path)

        // Append new data
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        let newLine = #"{"type":"assistant","uuid":"2"}"# + "\n"
        handle.write(newLine.data(using: .utf8)!)
        try handle.close()

        // Should only get the new line
        let entries = try await parser.parseNewEntries(at: path)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].type, "assistant")
    }

    // MARK: - Rich Fields

    func testParseEntryWithAllFields() async throws {
        let json = """
        {"type":"user","uuid":"u1","parentUuid":"p1","sessionId":"s1","timestamp":"2024-01-01T00:00:00Z","cwd":"/tmp","version":"1.0"}
        """
        let path = writeTempFile(json + "\n")

        let entries = try await parser.parseNewEntries(at: path)
        XCTAssertEqual(entries.count, 1)
        let entry = entries[0]
        XCTAssertEqual(entry.type, "user")
        XCTAssertEqual(entry.uuid, "u1")
        XCTAssertEqual(entry.parentUuid, "p1")
        XCTAssertEqual(entry.sessionId, "s1")
        XCTAssertEqual(entry.timestamp, "2024-01-01T00:00:00Z")
        XCTAssertEqual(entry.cwd, "/tmp")
        XCTAssertEqual(entry.version, "1.0")
    }
}
