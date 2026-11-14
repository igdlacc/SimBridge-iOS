import CryptoKit
import Foundation

enum UdpAudioPacket {
    static let magic: [UInt8] = [0x53, 0x42, 0x41, 0x32] // "SBA2"
    static let typeAudio: UInt8 = 1
    static let typeKeepalive: UInt8 = 2
    static let typeDiscoverReq: UInt8 = 3
    static let typeDiscoverResp: UInt8 = 4
    static let dirAndroidToIos: UInt8 = 1
    static let dirIosToAndroid: UInt8 = 2

    struct Decoded {
        let type: UInt8
        let direction: UInt8
        let seq: UInt16
        let timestampSamples: UInt32
        let callHash: Int32
        let payload: Data
    }

    static func encode(
        type: UInt8,
        direction: UInt8 = dirIosToAndroid,
        seq: UInt16,
        timestampSamples: UInt32,
        callHash: Int32,
        payload: Data,
        key: Data,
        salt: UInt32,
        nonceCounter: UInt64
    ) -> Data? {
        var header = [UInt8](repeating: 0, count: 8)
        header[0] = magic[0]
        header[1] = magic[1]
        header[2] = magic[2]
        header[3] = magic[3]
        header[4] = type
        header[5] = direction
        header[6] = UInt8((seq >> 8) & 0xFF)
        header[7] = UInt8(seq & 0xFF)

        var nonceBytes = [UInt8](repeating: 0, count: 12)
        nonceBytes[0] = direction
        nonceBytes[1] = UInt8((salt >> 16) & 0xFF)
        nonceBytes[2] = UInt8((salt >> 8) & 0xFF)
        nonceBytes[3] = UInt8(salt & 0xFF)
        for i in 0..<8 {
            nonceBytes[4 + i] = UInt8((nonceCounter >> ((7 - i) * 8)) & 0xFF)
        }

        var inner = Data(count: 8 + payload.count)
        let hashBits = UInt32(bitPattern: callHash)
        inner.withUnsafeMutableBytes { raw in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            ptr[0] = UInt8((timestampSamples >> 24) & 0xFF)
            ptr[1] = UInt8((timestampSamples >> 16) & 0xFF)
            ptr[2] = UInt8((timestampSamples >> 8) & 0xFF)
            ptr[3] = UInt8(timestampSamples & 0xFF)
            ptr[4] = UInt8((hashBits >> 24) & 0xFF)
            ptr[5] = UInt8((hashBits >> 16) & 0xFF)
            ptr[6] = UInt8((hashBits >> 8) & 0xFF)
            ptr[7] = UInt8(hashBits & 0xFF)
            if !payload.isEmpty {
                payload.copyBytes(to: ptr.advanced(by: 8), count: payload.count)
            }
        }

        guard let nonce = try? AES.GCM.Nonce(data: nonceBytes),
              let sealed = try? AES.GCM.seal(
                inner,
                using: SymmetricKey(data: key),
                nonce: nonce,
                authenticating: header
              ),
              let combined = sealed.combined else {
            return nil
        }

        var out = Data(capacity: 8 + combined.count)
        out.append(contentsOf: header)
        out.append(combined)
        return out
    }

    static func decode(data: Data, key: Data) -> Decoded? {
        guard data.count >= 8 + 12 + 8 + 16 else { return nil }
        let start = data.startIndex
        guard data[start] == magic[0],
              data[start + 1] == magic[1],
              data[start + 2] == magic[2],
              data[start + 3] == magic[3] else {
            return nil
        }

        let header = data[start..<(start + 8)]
        let combined = data[(start + 8)..<data.endIndex]
        guard let box = try? AES.GCM.SealedBox(combined: combined),
              let plain = try? AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: header),
              plain.count >= 8 else {
            return nil
        }

        let type = data[start + 4]
        let direction = data[start + 5]
        let seq = (UInt16(data[start + 6]) << 8) | UInt16(data[start + 7])

        let pStart = plain.startIndex
        let ts =
            (UInt32(plain[pStart]) << 24) |
            (UInt32(plain[pStart + 1]) << 16) |
            (UInt32(plain[pStart + 2]) << 8) |
            UInt32(plain[pStart + 3])
        let hashRaw =
            (UInt32(plain[pStart + 4]) << 24) |
            (UInt32(plain[pStart + 5]) << 16) |
            (UInt32(plain[pStart + 6]) << 8) |
            UInt32(plain[pStart + 7])
        let payload = plain[(pStart + 8)..<plain.endIndex]

        return Decoded(
            type: type,
            direction: direction,
            seq: seq,
            timestampSamples: ts,
            callHash: Int32(bitPattern: hashRaw),
            payload: payload
        )
    }
}
