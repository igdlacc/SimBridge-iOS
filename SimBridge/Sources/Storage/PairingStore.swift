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
    private let lock = NSLock()
    private var cachedConfig: StoredPairingConfig?
    private var hasLoadedCache = false

    private init() {}

    func save(_ config: StoredPairingConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        lock.lock()
        SecItemDelete(query as CFDictionary)

        var attrs = query
        attrs[kSecValueData as String] = data
        // Available in background when locked (after first unlock) so VoIP PushKit works cleanly!
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status == errSecSuccess {
            cachedConfig = config
            hasLoadedCache = true
        } else {
            cachedConfig = nil
            hasLoadedCache = false
        }
        lock.unlock()
    }

    func load() -> StoredPairingConfig? {
        lock.lock()
        if hasLoadedCache {
            let hit = cachedConfig
            lock.unlock()
            return hit
        }
        lock.unlock()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            return nil
        }
        let decoded = (status == errSecSuccess ? (result as? Data) : nil)
            .flatMap { try? JSONDecoder().decode(StoredPairingConfig.self, from: $0) }
        lock.lock()
        cachedConfig = decoded
        hasLoadedCache = true
        lock.unlock()
        return decoded
    }

    func updateIps(
        _ ips: [String],
        lastWorkingIp: String? = nil,
        wsPort: Int? = nil,
        udpPort: Int? = nil
    ) {
        guard var cfg = load() else { return }
        let cleanNew = ips
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var merged: [String] = []
        if let lw = lastWorkingIp?.trimmingCharacters(in: .whitespacesAndNewlines), !lw.isEmpty {
            merged.append(lw)
        }
        for ip in cleanNew where !merged.contains(ip) {
            merged.append(ip)
        }
        for old in cfg.candidateIps where !merged.contains(old) {
            merged.append(old)
        }
        cfg.candidateIps = Array(merged.prefix(8))
        if let lw = lastWorkingIp?.trimmingCharacters(in: .whitespacesAndNewlines), !lw.isEmpty {
            cfg.lastWorkingIp = lw
        }
        if let wsPort, wsPort > 0 { cfg.wsPort = wsPort }
        if let udpPort, udpPort > 0 { cfg.udpPort = udpPort }
        save(cfg)
    }

    func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        lock.lock()
        SecItemDelete(query as CFDictionary)
        cachedConfig = nil
        hasLoadedCache = true
        lock.unlock()
    }
}
