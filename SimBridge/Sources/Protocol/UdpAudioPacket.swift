import CryptoKit
import Foundation

enum UdpAudioPacket {
    static let magic: [UInt8] = [0x53, 0x42, 0x41, 0x32] // "SBA2"
    static let typeAudio: UInt8 = 1
    static let typeKeepalive: UInt8 = 2
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
        var header = Data(capacity: 8)
        header.append(contentsOf: magic)
        header.append(type)
        header.append(direction)
        var seqBE = seq.bigEndian
        header.append(Data(bytes: &seqBE, count: 2))

        var nonceData = Data(capacity: 12)
        nonceData.append(direction)
        nonceData.append(UInt8((salt >> 16) & 0xFF))
        nonceData.append(UInt8((salt >> 8) & 0xFF))
        nonceData.append(UInt8(salt & 0xFF))
        var cntBE = nonceCounter.bigEndian
        nonceData.append(Data(bytes: &cntBE, count: 8))

        var inner = Data(capacity: 8 + payload.count)
        var tsBE = timestampSamples.bigEndian
        var hashBE = UInt32(bitPattern: callHash).bigEndian
        inner.append(Data(bytes: &tsBE, count: 4))
        inner.append(Data(bytes: &hashBE, count: 4))
        inner.append(payload)

        guard let nonce = try? AES.GCM.Nonce(data: nonceData),
              let sealed = try? AES.GCM.seal(
                inner,
                using: SymmetricKey(data: key),
                nonce: nonce,
                authenticating: header
              ),
              let combined = sealed.combined else {
            return nil
        }

        var out = Data(capacity: header.count + combined.count)
        out.append(header)
        out.append(combined)
        return out
    }

    static func decode(data: Data, key: Data) -> Decoded? {
        guard data.count >= 8 + 12 + 8 + 16 else { return nil }
        guard data[0] == magic[0], data[1] == magic[1], data[2] == magic[2], data[3] == magic[3] else {
            return nil
        }

        let header = data.subdata(in: 0..<8)
        let combined = data.subdata(in: 8..<data.count)
        guard let box = try? AES.GCM.SealedBox(combined: combined),
              let plain = try? AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: header),
              plain.count >= 8 else {
            return nil
        }

        let type = header[4]
        let direction = header[5]
        let seq = (UInt16(header[6]) << 8) | UInt16(header[7])

        let ts = plain.subdata(in: 0..<4).withUnsafeBytes {
            UInt32(bigEndian: $0.load(as: UInt32.self))
        }
        let hashRaw = plain.subdata(in: 4..<8).withUnsafeBytes {
            UInt32(bigEndian: $0.load(as: UInt32.self))
        }
        let payload = plain.subdata(in: 8..<plain.count)

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
