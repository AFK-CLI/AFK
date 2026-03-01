import Foundation

enum BuildEnvironment {
    #if DEBUG
    static let storageSuffix = ".debug"
    #else
    static let storageSuffix = ""
    #endif

    static let keychainServiceName = "com.afk.app" + storageSuffix
    static let userDefaults = UserDefaults(suiteName: "com.afk.app.preferences" + storageSuffix) ?? .standard
    static let swiftDataName = "AFK" + storageSuffix
}
