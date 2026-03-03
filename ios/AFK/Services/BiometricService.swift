import Foundation
import LocalAuthentication

actor BiometricService {
    enum BiometricError: Error {
        case notAvailable
        case authenticationFailed(String)
    }

    /// Tracks whether the user has authenticated in this app session.
    /// Cleared when the app enters background.
    private static var lastAuthenticatedAt: Date?

    static var isSessionAuthenticated: Bool {
        lastAuthenticatedAt != nil
    }

    static func resetSession() {
        lastAuthenticatedAt = nil
    }

    static var isAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    static var biometricType: String {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return "Passcode"
        }
        switch context.biometryType {
        case .none: return "Passcode"
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        @unknown default: return "Biometric"
        }
    }

    func authenticate(reason: String) async throws {
        // Skip biometric if already authenticated this session
        if Self.isSessionAuthenticated { return }

        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw BiometricError.notAvailable
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
            if !success {
                throw BiometricError.authenticationFailed("Authentication denied")
            }
        } catch let laError as LAError {
            switch laError.code {
            case .userCancel, .appCancel:
                throw BiometricError.authenticationFailed("Cancelled")
            case .userFallback:
                // User tapped "Enter Password" — allow through
                break
            default:
                throw BiometricError.authenticationFailed(laError.localizedDescription)
            }
        }

        Self.lastAuthenticatedAt = Date()
    }
}
