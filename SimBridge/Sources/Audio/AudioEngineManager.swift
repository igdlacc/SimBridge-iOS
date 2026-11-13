import AVFoundation
import Foundation

final class AudioEngineManager {
    static let shared = AudioEngineManager()

    private let stateLock = NSLock()
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var opus: OpusWrapper?
    private let jitterBuffer = JitterBuffer(targetDepthFrames: 3, maxDepthFrames: 10)

    private var converter: AVAudioConverter?
    private var lastInputFormat: AVAudioFormat?
    private let target48kMonoFloat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!

    private let txRingLock = NSLock()
    private var txFloatBuffer: [Float] = []

    private let rxRingLock = NSLock()
    private var rxFloatBuffer: [Float] = []
    private var rxScratchPcm = [Int16](repeating: 0, count: Int(OpusWrapper.frameSamples))

    private var isRunning = false
    private var isMuted = false
    private var activeCallHash: Int32 = 0
    private var txSeq: UInt16 = 0
    private var txTimestamp: UInt32 = 0
    private var onSendAudioPacket: ((Data, UInt16, UInt32, Int32) -> Void)?

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigChange),
            name: .AVAudioEngineConfigurationChange,
            object: nil
        )
    }

    func setMuted(_ muted: Bool) {
        stateLock.lock()
        isMuted = muted
        stateLock.unlock()
    }

    func updateCallHash(_ callId: String) {
        stateLock.lock()
        activeCallHash = BridgeCrypto.fnv1a32(callId)
        stateLock.unlock()
    }

    func start(
        callId: String,
        sendAudioPacket: @escaping (Data, UInt16, UInt32, Int32) -> Void
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }

        activeCallHash = BridgeCrypto.fnv1a32(callId)
        onSendAudioPacket = sendAudioPacket
        if isRunning { return }

        guard let codec = OpusWrapper(bitrateBps: 24_000, complexity: 6) else {
            return
        }
        opus = codec
        jitterBuffer.reset()

        txRingLock.lock()
        txFloatBuffer.removeAll(keepingCapacity: true)
        txRingLock.unlock()

        rxRingLock.lock()
        rxFloatBuffer.removeAll(keepingCapacity: true)
        rxRingLock.unlock()

        txSeq = 0
        txTimestamp = 0
        converter = nil
        lastInputFormat = nil

        let eng = AVAudioEngine()
        let inputNode = eng.inputNode
        let mainMixer = eng.mainMixerNode

        do {
            try inputNode.setVoiceProcessingEnabled(true)
        } catch {
            // Continue gracefully if voice processing is unavailable on this route.
        }

        let srcNode = AVAudioSourceNode(format: target48kMonoFloat) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let count = Int(frameCount)
            guard let ptr = abl.first?.mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            self.fillOutputSamples(dst: ptr, count: count)
            return noErr
        }

        eng.attach(srcNode)
        eng.connect(srcNode, to: mainMixer, format: target48kMonoFloat)

        let tapFmt = inputNode.outputFormat(forBus: 0)
        if tapFmt.channelCount > 0 && tapFmt.sampleRate > 0 {
            inputNode.installTap(onBus: 0, bufferSize: 960, format: nil) { [weak self] buffer, _ in
                self?.processMicInput(buffer)
            }
        }

        eng.prepare()
        do {
            try eng.start()
            engine = eng
            sourceNode = srcNode
            isRunning = true
        } catch {
            eng.inputNode.removeTap(onBus: 0)
            eng.stop()
            codec.close()
            opus = nil
        }
    }

    func onIncomingAudioPacket(seq: UInt16, payload: Data) {
        stateLock.lock()
        let running = isRunning
        stateLock.unlock()
        guard running else { return }
        jitterBuffer.push(seq: seq, payload: payload)
    }

    func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard isRunning else { return }
        isRunning = false

        if let eng = engine {
            eng.inputNode.removeTap(onBus: 0)
            eng.stop()
        }
        engine = nil
        sourceNode = nil
        converter = nil
        lastInputFormat = nil
        opus?.close()
        opus = nil
        jitterBuffer.reset()
        onSendAudioPacket = nil
    }

    @objc private func handleEngineConfigChange(_ note: Notification) {
        stateLock.lock()
        let running = isRunning
        let eng = engine
        stateLock.unlock()
        guard running, let eng else { return }

        // Restart engine safely if AirPods/speaker route shift halted AVAudioEngine.
        if !eng.isRunning {
            try? eng.start()
        }
    }

    private func processMicInput(_ buffer: AVAudioPCMBuffer) {
        stateLock.lock()
        let muted = isMuted
        let running = isRunning
        let codec = opus
        let callHash = activeCallHash
        let sender = onSendAudioPacket
        stateLock.unlock()

        guard running, let codec, let sender else { return }

        let convertedSamples: [Float]
        if buffer.format.sampleRate == 48_000,
           buffer.format.channelCount == 1,
           buffer.format.commonFormat == .pcmFormatFloat32,
           let ch0 = buffer.floatChannelData?[0] {
            let count = Int(buffer.frameLength)
            convertedSamples = Array(UnsafeBufferPointer(start: ch0, count: count))
        } else {
            if converter == nil || lastInputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: target48kMonoFloat)
                lastInputFormat = buffer.format
            }
            guard let conv = converter else { return }
            let ratio = 48_000.0 / max(8_000.0, buffer.format.sampleRate)
            let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: target48kMonoFloat, frameCapacity: cap) else { return }

            var consumed = false
            var err: NSError?
            conv.convert(to: outBuf, error: &err) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }
            guard err == nil, outBuf.frameLength > 0, let ch0 = outBuf.floatChannelData?[0] else { return }
            convertedSamples = Array(UnsafeBufferPointer(start: ch0, count: Int(outBuf.frameLength)))
        }

        let frameLen = Int(OpusWrapper.frameSamples)
        var framesToSend: [[Int16]] = []

        txRingLock.lock()
        txFloatBuffer.append(contentsOf: convertedSamples)
        while txFloatBuffer.count >= frameLen {
            var pcm = [Int16](repeating: 0, count: frameLen)
            if !muted {
                for i in 0..<frameLen {
                    let clipped = max(-1.0, min(1.0, txFloatBuffer[i]))
                    pcm[i] = Int16(clipped * 32767.0)
                }
            }
            txFloatBuffer.removeFirst(frameLen)
            framesToSend.append(pcm)
        }
        txRingLock.unlock()

        for pcm in framesToSend {
            if let encoded = codec.encode(pcm: pcm) {
                stateLock.lock()
                let seq = txSeq
                let ts = txTimestamp
                txSeq = txSeq &+ 1
                txTimestamp = txTimestamp &+ UInt32(OpusWrapper.frameSamples)
                stateLock.unlock()
                sender(encoded, seq, ts, callHash)
            }
        }
    }

    private func fillOutputSamples(dst: UnsafeMutablePointer<Float>, count: Int) {
        rxRingLock.lock()
        defer { rxRingLock.unlock() }

        let frameLen = Int(OpusWrapper.frameSamples)
        if let codec = opus {
            while rxFloatBuffer.count < count {
                let res = jitterBuffer.pop()
                switch res {
                case .frame(let payload, let useFec):
                    let decCount = codec.decode(packet: payload, pcmOut: &rxScratchPcm, decodeFec: useFec)
                    if decCount > 0 {
                        for i in 0..<Int(decCount) {
                            rxFloatBuffer.append(Float(rxScratchPcm[i]) / 32768.0)
                        }
                    } else {
                        rxFloatBuffer.append(contentsOf: repeatElement(Float(0), count: frameLen))
                    }
                case .missingPlc:
                    let decCount = codec.decode(packet: nil, pcmOut: &rxScratchPcm, decodeFec: false)
                    if decCount > 0 {
                        for i in 0..<Int(decCount) {
                            rxFloatBuffer.append(Float(rxScratchPcm[i]) / 32768.0)
                        }
                    } else {
                        rxFloatBuffer.append(contentsOf: repeatElement(Float(0), count: frameLen))
                    }
                case .underrunSilence:
                    rxFloatBuffer.append(contentsOf: repeatElement(Float(0), count: count))
                    break
                }
                if case .underrunSilence = res { break }
            }
        }

        let avail = min(count, rxFloatBuffer.count)
        for i in 0..<avail {
            dst[i] = rxFloatBuffer[i]
        }
        if avail < count {
            for i in avail..<count {
                dst[i] = 0
            }
        }
        if avail > 0 {
            rxFloatBuffer.removeFirst(avail)
        }
    }
}
