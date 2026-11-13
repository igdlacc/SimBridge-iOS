import Foundation

final class OpusWrapper {
    static let sampleRate: Int32 = 48_000
    static let channels: Int32 = 1
    static let frameSamples: Int32 = 960 // 20 ms
    static let maxPacketBytes: Int = 512

    private var enc: OpaquePointer?
    private var dec: OpaquePointer?

    init?(bitrateBps: Int32 = 24_000, complexity: Int32 = 6) {
        enc = sim_opus_encoder_create(Self.sampleRate, Self.channels, bitrateBps, complexity)
        dec = sim_opus_decoder_create(Self.sampleRate, Self.channels)
        guard enc != nil, dec != nil else {
            close()
            return nil
        }
    }

    func encode(pcm: [Int16]) -> Data? {
        guard let enc, pcm.count >= Int(Self.frameSamples) else { return nil }
        var out = Data(count: Self.maxPacketBytes)
        let written: Int32 = pcm.withUnsafeBufferPointer { pcmPtr in
            out.withUnsafeMutableBytes { outRaw in
                guard let base = outRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let src = pcmPtr.baseAddress else { return -1 }
                return sim_opus_encode(enc, src, Self.frameSamples, base, Int32(Self.maxPacketBytes))
            }
        }
        guard written > 0 else { return nil }
        out.count = Int(written)
        return out
    }

    func decode(packet: Data?, pcmOut: inout [Int16], decodeFec: Bool) -> Int32 {
        guard let dec, pcmOut.count >= Int(Self.frameSamples) else { return -1 }
        return pcmOut.withUnsafeMutableBufferPointer { dstPtr in
            guard let dst = dstPtr.baseAddress else { return -1 }
            if let packet, !packet.isEmpty {
                return packet.withUnsafeBytes { pktRaw in
                    let src = pktRaw.baseAddress?.assumingMemoryBound(to: UInt8.self)
                    return sim_opus_decode(dec, src, Int32(packet.count), dst, Self.frameSamples, decodeFec ? 1 : 0)
                }
            } else {
                return sim_opus_decode(dec, nil, 0, dst, Self.frameSamples, 0)
            }
        }
    }

    func close() {
        if let enc {
            sim_opus_encoder_destroy(enc)
            self.enc = nil
        }
        if let dec {
            sim_opus_decoder_destroy(dec)
            self.dec = nil
        }
    }

    deinit {
        close()
    }
}
