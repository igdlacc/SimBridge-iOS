import Foundation
import Security

struct StoredPairingConfig: Codable {
    var bridgeId: String
    var deviceName: String
    var candidateIps: [String]
    var lastWorkingIp: String?
    var wsPort: Int
    var udpPort: Int
    var keyB64: String
}

final class PairingStore {
    static let shared = PairingStore()

    private let account = "simbridge_pairing_v1"
    private let service = "com.simbridge.ios.keychain"

    private init() {}

    func save(_ config: StoredPairingConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var attrs = query
        attrs[kSecValueData as String] = data
        // Available in background when locked (after first unlock) so VoIP PushKit works cleanly!
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attrs as CFDictionary, nil)
    }

    func load() -> StoredPairingConfig? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(StoredPairingConfig.self, from: data)
    }

    func updateIps(_ ips: [String], lastWorkingIp: String? = nil) {
        guard var cfg = load() else { return }
        var merged = ips
        for old in cfg.candidateIps where !merged.contains(old) {
            merged.append(old)
        }
        cfg.candidateIps = merged
        if let lastWorkingIp { cfg.lastWorkingIp = lastWorkingIp }
        save(cfg)
    }

    func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
