import CryptoKit
import Foundation

enum BridgeCrypto {
    static func decodeBase64Url(_ str: String) -> Data? {
        var b64 = str.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = b64.count % 4
        if rem > 0 {
            b64 += String(repeating: "=", count: 4 - rem)
        }
        return Data(base64Encoded: b64)
    }

    static func deriveWsAuthToken(key: Data) -> String {
        let code = HMAC<SHA256>.authenticationCode(
            for: Data("simbridge-ws-v1".utf8),
            using: SymmetricKey(data: key)
        )
        return code.map { String(format: "%02x", $0) }.joined()
    }

    static func encryptStringGcm(_ plaintext: String, key: Data) throws -> String {
        let sealed = try AES.GCM.seal(
            Data(plaintext.utf8),
            using: SymmetricKey(data: key)
        )
        guard let combined = sealed.combined else {
            throw NSError(domain: "BridgeCrypto", code: -1)
        }
        return combined.base64EncodedString()
    }

    static func decryptStringGcm(_ b64: String, key: Data) throws -> String {
        guard let raw = Data(base64Encoded: b64.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw NSError(domain: "BridgeCrypto", code: -2)
        }
        let box = try AES.GCM.SealedBox(combined: raw)
        let plain = try AES.GCM.open(box, using: SymmetricKey(data: key))
        guard let str = String(data: plain, encoding: .utf8) else {
            throw NSError(domain: "BridgeCrypto", code: -3)
        }
        return str
    }

    static func fnv1a32(_ value: String) -> Int32 {
        var h: UInt32 = 0x811C9DC5
        for b in value.utf8 {
            h ^= UInt32(b)
            h = h &* 0x01000193
        }
        return Int32(bitPattern: h)
    }
}
