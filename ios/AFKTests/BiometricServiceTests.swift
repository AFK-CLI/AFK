import XCTest
@testable import AFK

final class BiometricServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Reset session state before each test
        BiometricService.resetSession()
    }

    // MARK: - Session Authentication State

    func testInitiallyNotAuthenticated() {
        XCTAssertFalse(BiometricService.isSessionAuthenticated)
    }

    func testResetSessionClearsAuthentication() {
        // Even if we can't actually authenticate (no biometrics in tests),
        // we can verify that resetSession clears the state
        BiometricService.resetSession()
        XCTAssertFalse(BiometricService.isSessionAuthenticated)
    }

    func testResetSessionIsIdempotent() {
        BiometricService.resetSession()
        BiometricService.resetSession()
        XCTAssertFalse(BiometricService.isSessionAuthenticated)
    }

    // MARK: - Biometric Type

    func testBiometricTypeReturnsString() {
        // In a test/simulator environment, this should return a valid string
        let type = BiometricService.biometricType
        XCTAssertFalse(type.isEmpty)
        let validTypes = ["Face ID", "Touch ID", "Optic ID", "Passcode", "Biometric"]
        XCTAssertTrue(validTypes.contains(type), "Unexpected biometric type: \(type)")
    }
}
