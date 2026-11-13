import AVFoundation
import Combine
import Foundation

final class AudioEngineManager: ObservableObject {
    static let shared = AudioEngineManager()

    @Published private(set) var isSpeakerOn: Bool = false
    @Published private(set) var routeDescription: String = "Beklemede"
    @Published private(set) var diagnosticLines: [String] = []
    @Published private(set) var voiceProcessingEnabled: Bool = AudioEngineManager.loadVoiceProcessingPreference()

    private let stateLock = NSLock()
    private let diagLock = NSLock()
    private let txEncodeQueue = DispatchQueue(label: "com.simbridge.audio.tx", qos: .userInteractive)
    private let routeSessionQueue = DispatchQueue(label: "com.simbridge.audio.route", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var sinkNode: AVAudioSinkNode?
    private var usingTapFallback = false
    private var activeInputSampleRate: Double = 0
    private var activeInputChannelCount: AVAudioChannelCount = 0
    private var configObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var configChangeWorkItem: DispatchWorkItem?
    private var opus: OpusWrapper?
    private var diagnosticBuffer: [String] = []

    private static let voiceProcessingPrefKey = "simbridge.voiceProcessingEnabled"
    private static let diagDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()

    private static func loadVoiceProcessingPreference() -> Bool {
        if UserDefaults.standard.object(forKey: voiceProcessingPrefKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: voiceProcessingPrefKey)
    }
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
    }

    func setVoiceProcessingPreference(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.voiceProcessingPrefKey)
        DispatchQueue.main.async {
            self.voiceProcessingEnabled = enabled
        }
        recordDiagnostic("pref voiceProcessing=\(enabled)")
        stateLock.lock()
        let active = isRunning
        if active {
            teardownEngineLocked()
            converter = nil
            lastInputFormat = nil
            _ = buildAndStartEngineLocked()
        }
        stateLock.unlock()
    }

    func setSpeakerEnabled(_ enabled: Bool) {
        routeSessionQueue.async { [weak self] in
            guard let self else { return }
            let session = AVAudioSession.sharedInstance()
            do {
                try session.overrideOutputAudioPort(enabled ? .speaker : .none)
                self.recordDiagnostic(
                    "overrideOutputAudioPort(\(enabled ? "speaker" : "none")) ok -> [\(Self.describeRoute(session.currentRoute))]"
                )
            } catch {
                let nsErr = error as NSError
                self.recordDiagnostic(
                    "overrideOutputAudioPort(\(enabled ? "speaker" : "none")) ERR domain=\(nsErr.domain) code=\(nsErr.code): \(nsErr.localizedDescription)"
                )
            }
            self.refreshRouteSnapshot(session: session)
        }
    }

    func recordDiagnostic(_ message: String) {
        let line = "[\(Self.diagDateFormatter.string(from: Date()))] \(message)"
        diagLock.lock()
        diagnosticBuffer.append(line)
        if diagnosticBuffer.count > 40 {
            diagnosticBuffer.removeFirst(diagnosticBuffer.count - 40)
        }
        let snapshot = diagnosticBuffer
        diagLock.unlock()
        DispatchQueue.main.async {
            self.diagnosticLines = snapshot
        }
    }

    func copyableDiagnosticsText() -> String {
        let session = AVAudioSession.sharedInstance()
        let header = "cat=\(session.category.rawValue) mode=\(session.mode.rawValue) opts=\(session.categoryOptions.rawValue) sr=\(Int(session.sampleRate))Hz vpPref=\(Self.loadVoiceProcessingPreference()) route=[\(Self.describeRoute(session.currentRoute))]"
        diagLock.lock()
        let lines = diagnosticBuffer
        diagLock.unlock()
        return ([header] + lines).joined(separator: "\n")
    }

    func refreshRouteSnapshot(session: AVAudioSession = AVAudioSession.sharedInstance()) {
        let route = session.currentRoute
        let speaker = route.outputs.contains { $0.portType == .builtInSpeaker }
        let label = Self.shortRouteLabel(route)
        DispatchQueue.main.async {
            self.isSpeakerOn = speaker
            self.routeDescription = label
        }
    }

    func clearCallRouteState() {
        DispatchQueue.main.async {
            self.isSpeakerOn = false
            self.routeDescription = "Beklemede"
        }
    }

    static func describeRoute(_ route: AVAudioSessionRouteDescription?) -> String {
        guard let route else { return "none" }
        let ins = route.inputs.map { "\($0.portType.rawValue)(\($0.portName))" }.joined(separator: ",")
        let outs = route.outputs.map { "\($0.portType.rawValue)(\($0.portName))" }.joined(separator: ",")
        return "in:[\(ins)] out:[\(outs)]"
    }

    private static func shortRouteLabel(_ route: AVAudioSessionRouteDescription) -> String {
        guard let firstOut = route.outputs.first else { return "Bilinmiyor" }
        switch firstOut.portType {
        case .builtInSpeaker:
            return "Hoparlör"
        case .builtInReceiver:
            return "Ahize"
        case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE:
            return "Bluetooth (\(firstOut.portName))"
        case .headphones, .headsetMic, .usbAudio:
            return "Kulaklık (\(firstOut.portName))"
        case .airPlay:
            return "AirPlay"
        default:
            return firstOut.portName
        }
    }

    private static func describeRouteChangeReason(_ raw: UInt?) -> String {
        guard let raw, let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else {
            return "unknown"
        }
        switch reason {
        case .unknown: return "unknown"
        case .newDeviceAvailable: return "newDevice"
        case .oldDeviceUnavailable: return "oldDeviceGone"
        case .categoryChange: return "categoryChange"
        case .override: return "override"
        case .wakeFromSleep: return "wakeFromSleep"
        case .noSuitableRouteForCategory: return "noSuitableRoute"
        case .routeConfigurationChange: return "routeConfigChange"
        @unknown default: return "other(\(raw))"
        }
    }

    private func startRouteObservationLocked() {
        guard routeObserver == nil else { return }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            let session = AVAudioSession.sharedInstance()
            let reasonRaw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let prev = notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
            let reasonName = Self.describeRouteChangeReason(reasonRaw)
            self.recordDiagnostic(
                "routeChange \(reasonName)(\(reasonRaw ?? 999)) prev=[\(Self.describeRoute(prev))] now=[\(Self.describeRoute(session.currentRoute))] cat=\(session.category.rawValue) mode=\(session.mode.rawValue)"
            )
            self.refreshRouteSnapshot(session: session)
        }
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

        if buildAndStartEngineLocked() {
            isRunning = true
        } else {
            codec.close()
            opus = nil
        }
    }

    private func buildAndStartEngineLocked() -> Bool {
        startRouteObservationLocked()
        let eng = AVAudioEngine()
        let inputNode = eng.inputNode
        let outputNode = eng.outputNode
        let mainMixer = eng.mainMixerNode

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
        eng.connect(mainMixer, to: outputNode, format: nil)

        if Self.loadVoiceProcessingPreference() {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
            } catch {
                let nsErr = error as NSError
                recordDiagnostic("VP input enable ERR domain=\(nsErr.domain) code=\(nsErr.code): \(nsErr.localizedDescription)")
            }
            if !outputNode.isVoiceProcessingEnabled {
                do {
                    try outputNode.setVoiceProcessingEnabled(true)
                } catch {
                    let nsErr = error as NSError
                    recordDiagnostic("VP output enable ERR domain=\(nsErr.domain) code=\(nsErr.code): \(nsErr.localizedDescription)")
                }
            }
        } else {
            recordDiagnostic("VP disabled by preference")
        }

        var attachedSink: AVAudioSinkNode?
        let tapUsed = false
        let tapFmt = inputNode.outputFormat(forBus: 0)
        activeInputSampleRate = tapFmt.sampleRate
        activeInputChannelCount = tapFmt.channelCount

        if tapFmt.channelCount > 0 && tapFmt.sampleRate > 0 {
            let sink = AVAudioSinkNode { [weak self] _, frameCount, audioBufferList -> OSStatus in
                self?.handleSinkInput(frameCount: frameCount, audioBufferList: audioBufferList, format: tapFmt)
                return noErr
            }
            eng.attach(sink)
            eng.connect(inputNode, to: sink, format: tapFmt)
            attachedSink = sink
        }

        eng.prepare()
        do {
            try eng.start()
            engine = eng
            sourceNode = srcNode
            sinkNode = attachedSink
            usingTapFallback = tapUsed
            observeConfigChanges(for: eng)
            let session = AVAudioSession.sharedInstance()
            recordDiagnostic(
                "engine started vpIn=\(inputNode.isVoiceProcessingEnabled) vpOut=\(outputNode.isVoiceProcessingEnabled) tap=\(Int(tapFmt.sampleRate))Hz/\(tapFmt.channelCount)ch cat=\(session.category.rawValue) mode=\(session.mode.rawValue) route=[\(Self.describeRoute(session.currentRoute))]"
            )
            refreshRouteSnapshot(session: session)
            return true
        } catch {
            // Fallback to installTap if a specific iOS route disallows AVAudioSinkNode connection.
            if let sink = attachedSink {
                eng.disconnectNodeInput(sink)
                eng.detach(sink)
                attachedSink = nil
            }
            if tapFmt.channelCount > 0 && tapFmt.sampleRate > 0 {
                inputNode.installTap(onBus: 0, bufferSize: 960, format: nil) { [weak self] buffer, _ in
                    self?.txEncodeQueue.async {
                        self?.processMicInput(buffer)
                    }
                }
                tapUsed = true
            }
            eng.prepare()
            do {
                try eng.start()
                engine = eng
                sourceNode = srcNode
                sinkNode = nil
                usingTapFallback = tapUsed
                observeConfigChanges(for: eng)
                return true
            } catch {
                if tapUsed { eng.inputNode.removeTap(onBus: 0) }
                eng.stop()
                return false
            }
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

        teardownEngineLocked()
        converter = nil
        lastInputFormat = nil
        opus?.close()
        opus = nil
        jitterBuffer.reset()
        onSendAudioPacket = nil
    }

    private func teardownEngineLocked() {
        configChangeWorkItem?.cancel()
        configChangeWorkItem = nil
        if let obs = configObserver {
            NotificationCenter.default.removeObserver(obs)
            configObserver = nil
        }
        if let routeObs = routeObserver {
            NotificationCenter.default.removeObserver(routeObs)
            routeObserver = nil
        }
        if let eng = engine {
            if usingTapFallback {
                eng.inputNode.removeTap(onBus: 0)
            }
            if let sink = sinkNode {
                eng.disconnectNodeInput(sink)
                eng.detach(sink)
            }
            if let src = sourceNode {
                eng.disconnectNodeOutput(src)
                eng.detach(src)
            }
            if eng.isRunning {
                eng.stop()
            }
            if eng.inputNode.isVoiceProcessingEnabled {
                do {
                    try eng.inputNode.setVoiceProcessingEnabled(false)
                } catch {
                    let nsErr = error as NSError
                    recordDiagnostic("VP input disable ERR domain=\(nsErr.domain) code=\(nsErr.code)")
                }
            }
            if eng.outputNode.isVoiceProcessingEnabled {
                try? eng.outputNode.setVoiceProcessingEnabled(false)
            }
        }
        engine = nil
        sourceNode = nil
        sinkNode = nil
        usingTapFallback = false
        activeInputSampleRate = 0
        activeInputChannelCount = 0
    }

    private func observeConfigChanges(for eng: AVAudioEngine) {
        if let obs = configObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: eng,
            queue: nil
        ) { [weak self] _ in
            self?.scheduleEngineConfigRecovery()
        }
    }

    private func scheduleEngineConfigRecovery() {
        stateLock.lock()
        guard isRunning else {
            stateLock.unlock()
            return
        }
        configChangeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.recoverEngineAfterConfigChange()
        }
        configChangeWorkItem = work
        stateLock.unlock()
        // Wait 120ms for bursty iOS route notifications to settle so CallKit speaker toggles aren't reset.
        txEncodeQueue.asyncAfter(deadline: .now() + .milliseconds(120), execute: work)
    }

    private func recoverEngineAfterConfigChange() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isRunning, let eng = engine else { return }

        let currentFmt = eng.inputNode.outputFormat(forBus: 0)
        let sameFormat =
            currentFmt.sampleRate > 0 &&
            currentFmt.sampleRate == activeInputSampleRate &&
            currentFmt.channelCount == activeInputChannelCount

        recordDiagnostic(
            "configChange engRunning=\(eng.isRunning) old=\(Int(activeInputSampleRate))Hz/\(activeInputChannelCount)ch new=\(Int(currentFmt.sampleRate))Hz/\(currentFmt.channelCount)ch route=[\(Self.describeRoute(AVAudioSession.sharedInstance().currentRoute))]"
        )
        refreshRouteSnapshot()

        if eng.isRunning && sameFormat {
            return
        }

        // For Earpiece <-> Speaker toggles where sampleRate/channels stay unchanged, restart the
        // existing engine in place without re-initializing VoiceProcessingIO (which resets CallKit speaker UI).
        if !eng.isRunning && sameFormat {
            eng.prepare()
            do {
                try eng.start()
                recordDiagnostic("configChange in-place restart ok")
                return
            } catch {
                let nsErr = error as NSError
                recordDiagnostic("configChange in-place restart ERR domain=\(nsErr.domain) code=\(nsErr.code): \(nsErr.localizedDescription)")
            }
        }

        recordDiagnostic("configChange rebuilding engine")
        teardownEngineLocked()
        converter = nil
        lastInputFormat = nil
        _ = buildAndStartEngineLocked()
    }

    private func handleSinkInput(
        frameCount: AVAudioFrameCount,
        audioBufferList: UnsafePointer<AudioBufferList>,
        format: AVAudioFormat
    ) {
        let frames = Int(frameCount)
        guard frames > 0 else { return }
        let mCount = Int(audioBufferList.pointee.mNumberBuffers)
        guard mCount > 0 else { return }

        var copied: [Data] = []
        copied.reserveCapacity(mCount)
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        for i in 0..<abl.count {
            let buf = abl[i]
            let byteCount = Int(buf.mDataByteSize)
            if let mData = buf.mData, byteCount > 0 {
                copied.append(Data(bytes: mData, count: byteCount))
            }
        }
        guard !copied.isEmpty else { return }

        txEncodeQueue.async { [weak self] in
            guard let self,
                  let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
            pcm.frameLength = frameCount
            let dstAbl = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
            let count = min(copied.count, dstAbl.count)
            for i in 0..<count {
                copied[i].withUnsafeBytes { raw in
                    guard let base = raw.baseAddress, let dst = dstAbl[i].mData else { return }
                    let nBytes = min(raw.count, Int(dstAbl[i].mDataByteSize))
                    memcpy(dst, base, nBytes)
                }
            }
            self.processMicInput(pcm)
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
            let needsNewConverter: Bool
            if let prev = lastInputFormat {
                needsNewConverter =
                    prev.sampleRate != buffer.format.sampleRate ||
                    prev.channelCount != buffer.format.channelCount ||
                    prev.commonFormat != buffer.format.commonFormat ||
                    prev.isInterleaved != buffer.format.isInterleaved
            } else {
                needsNewConverter = true
            }
            if converter == nil || needsNewConverter {
                converter = AVAudioConverter(from: buffer.format, to: target48kMonoFloat)
                lastInputFormat = buffer.format
            }
            guard let conv = converter else { return }
            let ratio = 48_000.0 / max(8_000.0, buffer.format.sampleRate)
            let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: target48kMonoFloat, frameCapacity: cap) else { return }

            var consumed = false
            var err: NSError?
            let status = conv.convert(to: outBuf, error: &err) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }
            if status == .error || err != nil {
                converter?.reset()
                converter = nil
                return
            }
            guard outBuf.frameLength > 0, let ch0 = outBuf.floatChannelData?[0] else { return }
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
