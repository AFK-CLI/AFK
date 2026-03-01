import Foundation

enum BuildEnvironment {
    #if DEBUG
    static let isDebug = true
    #else
    static let isDebug = false
    #endif

    static let keychainServiceName = "com.afk.agent" + (isDebug ? ".debug" : "")
    static let configDirectoryName = ".afk-agent" + (isDebug ? "-debug" : "")

    static var configDirectoryPath: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/" + configDirectoryName
    }
}
