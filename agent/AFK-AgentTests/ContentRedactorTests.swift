import XCTest
@testable import AFK_Agent

final class ContentRedactorTests: XCTestCase {

    private var redactor: ContentRedactor!

    override func setUp() {
        super.setUp()
        redactor = ContentRedactor()
    }

    // MARK: - Secret Redaction

    func testRedactsAWSAccessKey() {
        let text = "Access key is AKIAIOSFODNN7EXAMPLE"
        let result = redactor.redact(text)
        XCTAssertTrue(result.contains("[REDACTED:AWS_ACCESS_KEY]"))
        XCTAssertFalse(result.contains("AKIAIOSFODNN7EXAMPLE"))
    }

    func testRedactsJWT() {
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        let text = "Token: \(jwt)"
        let result = redactor.redact(text)
        XCTAssertTrue(result.contains("[REDACTED:JWT]"))
        XCTAssertFalse(result.contains("eyJhbGci"))
    }

    func testRedactsGitHubToken() {
        let text = "github token: ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef"
        let result = redactor.redact(text)
        XCTAssertTrue(result.contains("[REDACTED:GIT_TOKEN]"))
        XCTAssertFalse(result.contains("ghp_"))
    }

    func testRedactsSlackToken() {
        let text = "SLACK_TOKEN=" + "xox" + "b-0000000000-FAKEFAKEFAKE""
        let result = redactor.redact(text)
        XCTAssertTrue(result.contains("[REDACTED:SLACK_TOKEN]"))
    }

    func testRedactsConnectionString() {
        let text = "DATABASE_URL=postgres://user:pass@host:5432/db"
        let result = redactor.redact(text)
        XCTAssertTrue(result.contains("[REDACTED:CONNECTION_STRING]"))
        XCTAssertFalse(result.contains("user:pass"))
    }

    func testRedactsGenericSecret() {
        let text = "api_key: sk_test_FAKEFAKEFAKEFAKEFAKEFAKE00"
        let result = redactor.redact(text)
        XCTAssertTrue(result.contains("[REDACTED:SECRET]"))
    }

    func testRedactsPassword() {
        let text = "password: \"super_secret_password123\""
        let result = redactor.redact(text)
        XCTAssertTrue(result.contains("[REDACTED:PASSWORD]"))
    }

    func testRedactsPrivateKey() {
        let text = "-----BEGIN RSA PRIVATE KEY-----\nMIIBogIB...\n-----END RSA PRIVATE KEY-----"
        let result = redactor.redact(text)
        XCTAssertTrue(result.contains("[REDACTED:PRIVATE_KEY]"))
    }

    func testPlainTextNotRedacted() {
        let text = "This is a normal log message with no secrets."
        let result = redactor.redact(text)
        XCTAssertEqual(result, text)
    }

    func testMultipleSecretsRedacted() {
        let text = "AWS=AKIAIOSFODNN7EXAMPLE token=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef"
        let result = redactor.redact(text)
        XCTAssertTrue(result.contains("[REDACTED:AWS_ACCESS_KEY]"))
        XCTAssertTrue(result.contains("[REDACTED:GIT_TOKEN]"))
    }

    // MARK: - Truncation

    func testTruncateShortText() {
        let text = "short"
        let result = redactor.truncate(text, maxLength: 100)
        XCTAssertEqual(result, "short")
    }

    func testTruncateLongText() {
        let text = String(repeating: "a", count: 3000)
        let result = redactor.truncate(text, maxLength: 2000)
        XCTAssertTrue(result.hasSuffix("… [truncated]"))
        XCTAssertLessThan(result.count, 3000)
    }

    func testTruncateExactLength() {
        let text = String(repeating: "x", count: 100)
        let result = redactor.truncate(text, maxLength: 100)
        XCTAssertEqual(result, text)
    }

    // MARK: - File Path Redaction

    func testRedactFilePathHashesDirectoryComponents() {
        let path = "/Users/alice/projects/secret/main.swift"
        let result = redactor.redactFilePath(path)
        // Filename should be preserved
        XCTAssertTrue(result.hasSuffix("/main.swift"))
        // Directory components should be hashed (8-char hex)
        XCTAssertFalse(result.contains("alice"))
        XCTAssertFalse(result.contains("projects"))
        XCTAssertFalse(result.contains("secret"))
    }

    func testRedactFilePathPreservesFilename() {
        let path = "/some/dir/MyFile.swift"
        let result = redactor.redactFilePath(path)
        XCTAssertTrue(result.hasSuffix("MyFile.swift"))
    }

    func testRedactFilePathSingleComponent() {
        let path = "standalone.txt"
        let result = redactor.redactFilePath(path)
        XCTAssertEqual(result, path)
    }

    func testRedactFilePathDisabled() {
        let config = ContentRedactor.Config(
            maxSnippetLength: 2000,
            maxToolInputLength: 2000,
            maxToolResultLength: 4000,
            hashFilePaths: false
        )
        let r = ContentRedactor(config: config)
        let path = "/Users/alice/secret/file.swift"
        let result = r.redactFilePath(path)
        XCTAssertEqual(result, path)
    }

    // MARK: - Snippet Redaction

    func testRedactSnippetCombinesRedactionAndTruncation() {
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        let text = "Token: \(jwt) " + String(repeating: "x", count: 3000)
        let result = redactor.redactSnippet(text)
        XCTAssertTrue(result.contains("[REDACTED:JWT]"))
        XCTAssertTrue(result.hasSuffix("… [truncated]"))
    }

    // MARK: - Tool Input Redaction

    func testRedactToolInput() {
        let input: [String: String] = [
            "file_path": "/Users/alice/code/app.swift",
            "content": "api_key: sk_test_FAKEFAKEFAKEFAKEFAKEFAKE00"
        ]
        let result = redactor.redactToolInput(input, toolName: "Write")
        XCTAssertTrue(result["content"]?.contains("[REDACTED:SECRET]") == true)
    }

    // MARK: - Tool Result Redaction

    func testRedactToolResult() {
        let text = "password: \"hunter2hunter2hunter2\""
        let result = redactor.redactToolResult(text)
        XCTAssertTrue(result.contains("[REDACTED:PASSWORD]"))
    }

    func testRedactToolResultTruncates() {
        let text = String(repeating: "x", count: 5000)
        let result = redactor.redactToolResult(text)
        XCTAssertTrue(result.hasSuffix("… [truncated]"))
    }

    // MARK: - Default Config

    func testDefaultConfig() {
        let config = ContentRedactor.Config.default
        XCTAssertEqual(config.maxSnippetLength, 2000)
        XCTAssertEqual(config.maxToolInputLength, 2000)
        XCTAssertEqual(config.maxToolResultLength, 4000)
        XCTAssertTrue(config.hashFilePaths)
    }
}
