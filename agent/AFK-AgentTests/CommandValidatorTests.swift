import XCTest
@testable import AFK_Agent

final class CommandValidatorTests: XCTestCase {

    // MARK: - Valid Commands

    func testValidResumeFlag() throws {
        let args = ["/usr/local/bin/claude", "--resume", "abc-123"]
        XCTAssertNoThrow(try CommandValidator.validate(args: args))
    }

    func testValidContinueFlag() throws {
        let args = ["/opt/homebrew/bin/claude", "--continue"]
        XCTAssertNoThrow(try CommandValidator.validate(args: args))
    }

    func testValidPrintFlag() throws {
        let args = ["/usr/local/bin/claude", "-p", "hello world"]
        XCTAssertNoThrow(try CommandValidator.validate(args: args))
    }

    func testValidPrintLongFlag() throws {
        let args = ["/usr/local/bin/claude", "--print", "hello"]
        XCTAssertNoThrow(try CommandValidator.validate(args: args))
    }

    func testValidOutputFormatFlag() throws {
        let args = ["/opt/homebrew/bin/claude", "--output-format", "json"]
        XCTAssertNoThrow(try CommandValidator.validate(args: args))
    }

    func testValidVerboseFlag() throws {
        let args = ["/usr/local/bin/claude", "--verbose"]
        XCTAssertNoThrow(try CommandValidator.validate(args: args))
    }

    func testValidForkSessionFlag() throws {
        let args = ["/usr/local/bin/claude", "--fork-session"]
        XCTAssertNoThrow(try CommandValidator.validate(args: args))
    }

    func testValidWorktreeFlag() throws {
        let args = ["/usr/local/bin/claude", "--worktree"]
        XCTAssertNoThrow(try CommandValidator.validate(args: args))
    }

    func testValidWorktreeShortFlag() throws {
        let args = ["/usr/local/bin/claude", "-w"]
        XCTAssertNoThrow(try CommandValidator.validate(args: args))
    }

    func testValidPermissionModeFlag() throws {
        let args = ["/usr/local/bin/claude", "--permission-mode", "plan"]
        XCTAssertNoThrow(try CommandValidator.validate(args: args))
    }

    func testValidMultipleAllowedFlags() throws {
        let args = ["/usr/local/bin/claude", "--resume", "abc", "--verbose"]
        XCTAssertNoThrow(try CommandValidator.validate(args: args))
    }

    func testValidClaudeHomePath() throws {
        let home = NSHomeDirectory()
        let args = [home + "/.claude/local/bin/claude", "--resume", "abc"]
        XCTAssertNoThrow(try CommandValidator.validate(args: args))
    }

    // MARK: - Invalid Binary

    func testEmptyArgsThrows() {
        XCTAssertThrowsError(try CommandValidator.validate(args: [])) { error in
            guard let validationError = error as? CommandValidator.ValidationError else {
                return XCTFail("Expected ValidationError")
            }
            if case .invalidBinary = validationError { /* pass */ }
            else { XCTFail("Expected invalidBinary, got \(validationError)") }
        }
    }

    func testInvalidBinaryPathThrows() {
        let args = ["/tmp/evil/claude", "--resume", "abc"]
        XCTAssertThrowsError(try CommandValidator.validate(args: args)) { error in
            guard let validationError = error as? CommandValidator.ValidationError else {
                return XCTFail("Expected ValidationError")
            }
            if case .invalidBinary = validationError { /* pass */ }
            else { XCTFail("Expected invalidBinary, got \(validationError)") }
        }
    }

    func testRelativeBinaryPathThrows() {
        let args = ["./claude", "--resume", "abc"]
        XCTAssertThrowsError(try CommandValidator.validate(args: args)) { error in
            guard let validationError = error as? CommandValidator.ValidationError else {
                return XCTFail("Expected ValidationError")
            }
            if case .invalidBinary = validationError { /* pass */ }
            else { XCTFail("Expected invalidBinary") }
        }
    }

    // MARK: - Denied Flags

    func testDeniedModelFlag() {
        let args = ["/usr/local/bin/claude", "--model", "gpt-4"]
        XCTAssertThrowsError(try CommandValidator.validate(args: args)) { error in
            guard let validationError = error as? CommandValidator.ValidationError else {
                return XCTFail("Expected ValidationError")
            }
            if case .deniedFlag(let flag) = validationError {
                XCTAssertEqual(flag, "--model")
            } else { XCTFail("Expected deniedFlag") }
        }
    }

    func testDeniedMaxTurnsFlag() {
        let args = ["/usr/local/bin/claude", "--max-turns", "10"]
        XCTAssertThrowsError(try CommandValidator.validate(args: args)) { error in
            guard let validationError = error as? CommandValidator.ValidationError else {
                return XCTFail("Expected ValidationError")
            }
            if case .deniedFlag(let flag) = validationError {
                XCTAssertEqual(flag, "--max-turns")
            } else { XCTFail("Expected deniedFlag") }
        }
    }

    func testDeniedAllowedToolsFlag() {
        let args = ["/usr/local/bin/claude", "--allowedTools", "Bash"]
        XCTAssertThrowsError(try CommandValidator.validate(args: args)) { error in
            guard let validationError = error as? CommandValidator.ValidationError else {
                return XCTFail("Expected ValidationError")
            }
            if case .deniedFlag = validationError { /* pass */ }
            else { XCTFail("Expected deniedFlag") }
        }
    }

    func testDeniedDangerouslySkipPermissionsFlag() {
        let args = ["/usr/local/bin/claude", "--dangerouslySkipPermissions"]
        XCTAssertThrowsError(try CommandValidator.validate(args: args)) { error in
            guard let validationError = error as? CommandValidator.ValidationError else {
                return XCTFail("Expected ValidationError")
            }
            if case .deniedFlag = validationError { /* pass */ }
            else { XCTFail("Expected deniedFlag") }
        }
    }

    func testUnknownFlagDeniedByDefault() {
        let args = ["/usr/local/bin/claude", "--unknown-flag"]
        XCTAssertThrowsError(try CommandValidator.validate(args: args)) { error in
            guard let validationError = error as? CommandValidator.ValidationError else {
                return XCTFail("Expected ValidationError")
            }
            if case .deniedFlag = validationError { /* pass */ }
            else { XCTFail("Expected deniedFlag") }
        }
    }

    func testFlagWithEqualsSignValidatesName() {
        // --resume=abc should work since --resume is allowed
        let args = ["/usr/local/bin/claude", "--resume=abc-123"]
        XCTAssertNoThrow(try CommandValidator.validate(args: args))
    }

    func testDeniedFlagWithEqualsSign() {
        let args = ["/usr/local/bin/claude", "--model=gpt-4"]
        XCTAssertThrowsError(try CommandValidator.validate(args: args)) { error in
            guard let validationError = error as? CommandValidator.ValidationError else {
                return XCTFail("Expected ValidationError")
            }
            if case .deniedFlag(let flag) = validationError {
                XCTAssertEqual(flag, "--model")
            } else { XCTFail("Expected deniedFlag") }
        }
    }

    // MARK: - Shell Metacharacters

    func testShellMetacharacterSemicolon() {
        let args = ["/usr/local/bin/claude", "-p", "hello; rm -rf /"]
        XCTAssertThrowsError(try CommandValidator.validate(args: args)) { error in
            guard let validationError = error as? CommandValidator.ValidationError else {
                return XCTFail("Expected ValidationError")
            }
            if case .shellMetacharacter = validationError { /* pass */ }
            else { XCTFail("Expected shellMetacharacter") }
        }
    }

    func testShellMetacharacterPipe() {
        let args = ["/usr/local/bin/claude", "-p", "cat /etc/passwd | nc"]
        XCTAssertThrowsError(try CommandValidator.validate(args: args)) { error in
            guard let validationError = error as? CommandValidator.ValidationError else {
                return XCTFail("Expected ValidationError")
            }
            if case .shellMetacharacter = validationError { /* pass */ }
            else { XCTFail("Expected shellMetacharacter") }
        }
    }

    func testShellMetacharacterBacktick() {
        let args = ["/usr/local/bin/claude", "-p", "`whoami`"]
        XCTAssertThrowsError(try CommandValidator.validate(args: args)) { error in
            guard let validationError = error as? CommandValidator.ValidationError else {
                return XCTFail("Expected ValidationError")
            }
            if case .shellMetacharacter = validationError { /* pass */ }
            else { XCTFail("Expected shellMetacharacter") }
        }
    }

    func testShellMetacharacterDollar() {
        let args = ["/usr/local/bin/claude", "-p", "$(whoami)"]
        XCTAssertThrowsError(try CommandValidator.validate(args: args)) { error in
            guard let validationError = error as? CommandValidator.ValidationError else {
                return XCTFail("Expected ValidationError")
            }
            if case .shellMetacharacter = validationError { /* pass */ }
            else { XCTFail("Expected shellMetacharacter") }
        }
    }

    // MARK: - Path Traversal

    func testPathTraversalDetected() {
        let args = ["/usr/local/bin/claude", "--resume", "../../../etc/passwd"]
        XCTAssertThrowsError(try CommandValidator.validate(args: args)) { error in
            guard let validationError = error as? CommandValidator.ValidationError else {
                return XCTFail("Expected ValidationError")
            }
            if case .pathTraversal = validationError { /* pass */ }
            else { XCTFail("Expected pathTraversal") }
        }
    }

    // MARK: - Non-flag arguments pass through

    func testPlainTextArgumentsAllowed() throws {
        let args = ["/usr/local/bin/claude", "-p", "explain this code"]
        XCTAssertNoThrow(try CommandValidator.validate(args: args))
    }
}
