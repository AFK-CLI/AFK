//
//  DeviceIdentity.swift
//  AFK-Agent
//

import Foundation
import CryptoKit

struct DeviceIdentity: Sendable {
    let privateKey: Curve25519.Signing.PrivateKey
    let serverPublicKey: Data?

    var publicKeyBase64: String {
        privateKey.publicKey.rawRepresentation.base64EncodedString()
    }

    static func generate() -> DeviceIdentity {
        DeviceIdentity(privateKey: Curve25519.Signing.PrivateKey(), serverPublicKey: nil)
    }

    static func load(from keychain: KeychainStore) throws -> DeviceIdentity? {
        guard let keyData = try keychain.loadData(forKey: "device-private-key") else { return nil }
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
        let serverPubKey = try loadServerPublicKey(from: keychain)
        return DeviceIdentity(privateKey: privateKey, serverPublicKey: serverPubKey)
    }

    func save(to keychain: KeychainStore) throws {
        try keychain.saveData(privateKey.rawRepresentation, forKey: "device-private-key")
    }

    func saveServerPublicKey(_ key: Data, to keychain: KeychainStore) throws {
        try keychain.saveData(key, forKey: "serverPublicKey")
    }

    static func loadServerPublicKey(from keychain: KeychainStore) throws -> Data? {
        try keychain.loadData(forKey: "serverPublicKey")
    }

    static func deviceName() -> String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    static func systemInfo() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        let model = hardwareModel()
        if model.isEmpty {
            return "macOS \(version)"
        }
        return "macOS \(version) \(model)"
    }

    /// Returns the hardware model identifier (e.g. "MacBookPro18,1", "Macmini9,1").
    private static func hardwareModel() -> String {
        var size: Int = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }
}
