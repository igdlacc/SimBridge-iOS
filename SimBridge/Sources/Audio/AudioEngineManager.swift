import AVFoundation
import Combine
import Foundation
import UIKit

struct AudioCallMetrics: Equatable, Sendable {
    var txPackets: Int64 = 0
    var rxPackets: Int64 = 0
    var plcFrames: Int64 = 0
    var lateDropFrames: Int64 = 0
    var queuedFrames: Int = 0

    static let empty = AudioCallMetrics()
}

final class AudioEngineManager: ObservableObject {
    static let shared = AudioEngineManager()

    @Published private(set) var isSpeakerOn: Bool = false
    @Published private(set) var isMuted: Bool = false
    @Published private(set) var routeDescription: String = "Beklemede"
    @Published private(set) var diagnosticLines: [String] = []
    @Published private(set) var voiceProcessingEnabled: Bool = AudioEngineManager.loadVoiceProcessingPreference()
    @Published private(set) var callAudioMetrics: AudioCallMetrics = .empty

    private let stateLock = NSLock()
    private let diagLock = NSLock()
    private let speakerFlagLock = NSLock()
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
    private var interruptionObserver: NSObjectProtocol?
    private var mediaResetObserver: NSObjectProtocol?
    private var mediaLostObserver: NSObjectProtocol?
    private var silenceSecondaryObserver: NSObjectProtocol?
    private var appBecomeActiveObserver: NSObjectProtocol?
    private var appWillResignObserver: NSObjectProtocol?
    private var appDidEnterBgObserver: NSObjectProtocol?
    private var configChangeWorkItem: DispatchWorkItem?
    private var recoveryWorkItem: DispatchWorkItem?
    private var metricsTimer: DispatchSourceTimer?
    private var opus: OpusWrapper?
    private var diagnosticBuffer: [String] = []
    private var lastKnownSpeakerActive = false

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
    private let txRing = RingFloatBuffer(capacity: 16_384)
    private var txScratchPcm = [Int16](repeating: 0, count: Int(OpusWrapper.frameSamples))
    private var txOpusScratch = [UInt8](repeating: 0, count: OpusWrapper.maxPacketBytes)

    private let rxRingLock = NSLock()
    private let rxRing = RingFloatBuffer(capacity: 16_384)
    private var rxScratchPcm = [Int16](repeating: 0, count: Int(OpusWrapper.frameSamples))

    private var isRunning = false
    private var isInterrupted = false
    private var speakerBeforeInterruption = false
    private var holdBounceAttemptedInEpisode = false
    private var recoveryGeneration: Int = 0
    private var probeAttemptCount: Int = 0
    private var appIsActiveCached = false
    private var isMutedLocked = false
    private var activeCallHash: Int32 = 0
    private var txSeq: UInt16 = 0
    private var txTimestamp: UInt32 = 0
    private var txPacketCount: Int64 = 0
    private var onSendAudioPacket: ((Data, UInt16, UInt32, Int32) -> Void)?

    private init() {
        stateLock.lock()
        ensureSessionObserversLocked()
        stateLock.unlock()
        refreshAppActiveStateAsync()
    }

    func setVoiceProcessingPreference(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.voiceProcessingPrefKey)
        DispatchQueue.main.async {
            self.voiceProcessingEnabled = enabled
        }
        recordDiagnostic("pref voiceProcessing=\(enabled)")
        stateLock.lock()
        let active = isRunning && !isInterrupted
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
        if diagnosticBuffer.count > 80 {
            diagnosticBuffer.removeFirst(diagnosticBuffer.count - 80)
        }
        let snapshot = diagnosticBuffer
        diagLock.unlock()
        DispatchQueue.main.async {
            self.diagnosticLines = snapshot
        }
    }

    func copyableDiagnosticsText() -> String {
        let session = AVAudioSession.sharedInstance()
        let jbStats = jitterBuffer.statsSnapshot()
        stateLock.lock()
        let txCnt = txPacketCount
        stateLock.unlock()
        let header = "cat=\(session.category.rawValue) mode=\(session.mode.rawValue) opts=\(session.categoryOptions.rawValue) sr=\(Int(session.sampleRate))Hz vpPref=\(Self.loadVoiceProcessingPreference()) otherAudio=\(session.isOtherAudioPlaying) tx=\(txCnt) rx=\(jbStats.receivedFrames) plc=\(jbStats.plcFrames) late=\(jbStats.lateDropFrames) ovf=\(jbStats.overflowDropFrames) route=[\(Self.describeRoute(session.currentRoute))]"
        diagLock.lock()
        let lines = diagnosticBuffer
        diagLock.unlock()
        return ([header] + lines).joined(separator: "\n")
    }

    func refreshRouteSnapshot(session: AVAudioSession = AVAudioSession.sharedInstance()) {
        let route = session.currentRoute
        let speaker = route.outputs.contains { $0.portType == .builtInSpeaker }
        let label = Self.shortRouteLabel(route)
        speakerFlagLock.lock()
        lastKnownSpeakerActive = speaker && !Self.hasExternalOutputPort(route)
        speakerFlagLock.unlock()
        DispatchQueue.main.async {
            self.isSpeakerOn = speaker
            self.routeDescription = label
        }
    }

    func clearCallRouteState() {
        speakerFlagLock.lock()
        lastKnownSpeakerActive = false
        speakerFlagLock.unlock()
        DispatchQueue.main.async {
            self.isSpeakerOn = false
            self.routeDescription = "Beklemede"
        }
    }

    private static func isSpeakerRoute(_ route: AVAudioSessionRouteDescription?) -> Bool {
        guard let route else { return false }
        return route.outputs.contains { $0.portType == .builtInSpeaker }
    }

    private static func hasExternalOutputPort(_ route: AVAudioSessionRouteDescription?) -> Bool {
        guard let route else { return false }
        return route.outputs.contains {
            $0.portType != .builtInSpeaker && $0.portType != .builtInReceiver
        }
    }

    private static func describeInterruptionReason(_ raw: UInt?) -> String {
        guard let raw else { return "none" }
        switch raw {
        case 0: return "default(0)"
        case 1: return "appWasSuspended(1)"
        case 2: return "builtInMicMuted(2)"
        case 4: return "routeDisconnected(4)"
        default: return "other(\(raw))"
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

    private func refreshAppActiveStateAsync() {
        Task { @MainActor [weak self] in
            self?.setAppActiveState(UIApplication.shared.applicationState == .active)
        }
    }

    private func setAppActiveState(_ active: Bool) {
        stateLock.lock()
        let prev = appIsActiveCached
        appIsActiveCached = active
        if active && isRunning && (isInterrupted || engine?.isRunning != true) {
            holdBounceAttemptedInEpisode = false
            probeAttemptCount = 0
            if !prev {
                recordDiagnostic("app didBecomeActive while call audio needs recovery")
            }
            scheduleRecoveryLocked(delayMs: 80, allowHoldBounce: true, reason: "app_active", fromProbe: false)
        }
        stateLock.unlock()
    }

    private func ensureSessionObserversLocked() {
        let nc = NotificationCenter.default
        if routeObserver == nil {
            routeObserver = nc.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                self?.handleRouteChange(notification)
            }
        }
        if interruptionObserver == nil {
            interruptionObserver = nc.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                self?.handleAudioInterruption(notification)
            }
        }
        if mediaResetObserver == nil {
            mediaResetObserver = nc.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.handleMediaServicesReset()
            }
        }
        if mediaLostObserver == nil {
            mediaLostObserver = nc.addObserver(
                forName: AVAudioSession.mediaServicesWereLostNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.handleMediaServicesLost()
            }
        }
        if silenceSecondaryObserver == nil {
            silenceSecondaryObserver = nc.addObserver(
                forName: AVAudioSession.silenceSecondaryAudioHintNotification,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                self?.handleSilenceSecondaryAudioHint(notification)
            }
        }
        if appBecomeActiveObserver == nil {
            appBecomeActiveObserver = nc.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.setAppActiveState(true)
            }
        }
        if appWillResignObserver == nil {
            appWillResignObserver = nc.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.refreshAppActiveStateAsync()
            }
        }
        if appDidEnterBgObserver == nil {
            appDidEnterBgObserver = nc.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.setAppActiveState(false)
            }
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        let session = AVAudioSession.sharedInstance()
        let reasonRaw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        let prev = notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
        let reasonName = Self.describeRouteChangeReason(reasonRaw)
        let currentRoute = session.currentRoute

        recordDiagnostic(
            "routeChange \(reasonName)(\(reasonRaw ?? 999)) prev=[\(Self.describeRoute(prev))] now=[\(Self.describeRoute(currentRoute))] cat=\(session.category.rawValue) mode=\(session.mode.rawValue)"
        )
        refreshRouteSnapshot(session: session)

        stateLock.lock()
        if isRunning {
            if currentRoute.inputs.isEmpty {
                let newlyInterrupted = enterInterruptedStateLocked(
                    reason: "route_no_input",
                    prevRoute: prev,
                    currentRoute: currentRoute
                )
                if newlyInterrupted {
                    scheduleRecoveryLocked(delayMs: 1200, allowHoldBounce: false, reason: "route_probe", fromProbe: true)
                }
            } else if isInterrupted || engine?.isRunning != true {
                scheduleRecoveryLocked(delayMs: 150, allowHoldBounce: false, reason: "route_input_restored", fromProbe: false)
            }
        }
        stateLock.unlock()
    }

    private func handleAudioInterruption(_ notification: Notification) {
        let info = notification.userInfo
        let typeRaw = info?[AVAudioSessionInterruptionTypeKey] as? UInt
        let reasonRaw = info?[AVAudioSessionInterruptionReasonKey] as? UInt
        let optionsRaw = info?[AVAudioSessionInterruptionOptionKey] as? UInt
        let session = AVAudioSession.sharedInstance()

        guard let typeRaw, let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else {
            recordDiagnostic("interruption unknown typeRaw=\(typeRaw.map(String.init) ?? "nil")")
            return
        }

        let reasonDesc = Self.describeInterruptionReason(reasonRaw)
        switch type {
        case .began:
            recordDiagnostic(
                "interruption BEGAN reason=\(reasonDesc) otherAudio=\(session.isOtherAudioPlaying) silenceHint=\(session.secondaryAudioShouldBeSilencedHint) route=[\(Self.describeRoute(session.currentRoute))]"
            )
            stateLock.lock()
            if isRunning {
                let newlyInterrupted = enterInterruptedStateLocked(
                    reason: "interruption_began",
                    prevRoute: nil,
                    currentRoute: session.currentRoute
                )
                if newlyInterrupted {
                    scheduleRecoveryLocked(delayMs: 1200, allowHoldBounce: false, reason: "began_probe", fromProbe: true)
                }
            }
            stateLock.unlock()

        case .ended:
            let opts = optionsRaw.map { AVAudioSession.InterruptionOptions(rawValue: $0) } ?? []
            let shouldResume = opts.contains(.shouldResume)
            recordDiagnostic(
                "interruption ENDED shouldResume=\(shouldResume) reason=\(reasonDesc) otherAudio=\(session.isOtherAudioPlaying) silenceHint=\(session.secondaryAudioShouldBeSilencedHint) route=[\(Self.describeRoute(session.currentRoute))]"
            )
            stateLock.lock()
            if isRunning {
                scheduleRecoveryLocked(delayMs: 150, allowHoldBounce: true, reason: "interruption_ended", fromProbe: false)
            }
            stateLock.unlock()

        @unknown default:
            recordDiagnostic("interruption OTHER(\(typeRaw))")
        }
    }

    private func handleMediaServicesLost() {
        let session = AVAudioSession.sharedInstance()
        recordDiagnostic("mediaServicesWereLost")
        stateLock.lock()
        if isRunning {
            _ = enterInterruptedStateLocked(
                reason: "media_lost",
                prevRoute: nil,
                currentRoute: session.currentRoute
            )
        }
        stateLock.unlock()
    }

    private func handleMediaServicesReset() {
        let session = AVAudioSession.sharedInstance()
        recordDiagnostic("mediaServicesWereReset route=[\(Self.describeRoute(session.currentRoute))]")
        stateLock.lock()
        if isRunning {
            isInterrupted = true
            holdBounceAttemptedInEpisode = false
            probeAttemptCount = 0
            recoveryGeneration &+= 1
            teardownEngineLocked()
            converter = nil
            lastInputFormat = nil
            scheduleRecoveryLocked(delayMs: 300, allowHoldBounce: true, reason: "media_reset", fromProbe: false)
        }
        stateLock.unlock()
    }

    private func handleSilenceSecondaryAudioHint(_ notification: Notification) {
        let typeRaw = notification.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt
        let hintType = typeRaw.flatMap { AVAudioSession.SilenceSecondaryAudioHintType(rawValue: $0) }
        switch hintType {
        case .begin:
            recordDiagnostic("silenceSecondaryHint BEGAN")
        case .end:
            recordDiagnostic("silenceSecondaryHint ENDED")
            stateLock.lock()
            if isRunning && (isInterrupted || engine?.isRunning != true) {
                scheduleRecoveryLocked(delayMs: 250, allowHoldBounce: true, reason: "silence_hint_end", fromProbe: false)
            }
            stateLock.unlock()
        case .none:
            break
        @unknown default:
            break
        }
    }

    /// Transitions an active call into interrupted state and tears down the audio engine while
    /// preserving `isRunning`, `opus`, and the speaker state before the interruption.
    private func enterInterruptedStateLocked(
        reason: String,
        prevRoute: AVAudioSessionRouteDescription?,
        currentRoute: AVAudioSessionRouteDescription
    ) -> Bool {
        guard isRunning, !isInterrupted else { return false }

        isInterrupted = true
        holdBounceAttemptedInEpisode = false
        probeAttemptCount = 0
        recoveryGeneration &+= 1

        speakerFlagLock.lock()
        let cachedSpeaker = lastKnownSpeakerActive
        speakerFlagLock.unlock()

        let speakerFromPrev = prevRoute.map { !Self.hasExternalOutputPort($0) && Self.isSpeakerRoute($0) }
        let speakerFromNow = !currentRoute.outputs.isEmpty
            ? (!Self.hasExternalOutputPort(currentRoute) && Self.isSpeakerRoute(currentRoute))
            : cachedSpeaker
        speakerBeforeInterruption = speakerFromPrev ?? speakerFromNow

        teardownEngineLocked()
        converter = nil
        lastInputFormat = nil
        refreshRouteSnapshot(session: AVAudioSession.sharedInstance())
        recordDiagnostic("audio paused (\(reason)) speakerBefore=\(speakerBeforeInterruption)")
        return true
    }

    private func scheduleRecoveryLocked(delayMs: Int, allowHoldBounce: Bool, reason: String, fromProbe: Bool) {
        guard isRunning else { return }
        recoveryWorkItem?.cancel()
        let expectedGen = recoveryGeneration
        let work = DispatchWorkItem { [weak self] in
            self?.attemptRecovery(
                generation: expectedGen,
                reason: reason,
                allowHoldBounce: allowHoldBounce,
                fromProbe: fromProbe
            )
        }
        recoveryWorkItem = work
        if delayMs <= 0 {
            routeSessionQueue.async(execute: work)
        } else {
            routeSessionQueue.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: work)
        }
    }

    private func scheduleNextInterruptedProbeIfNeeded(expectedGen: Int) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isRunning,
              expectedGen == recoveryGeneration,
              (isInterrupted || engine?.isRunning != true),
              probeAttemptCount < 450 else {
            return
        }
        let delayMs: Int
        switch probeAttemptCount {
        case 0: delayMs = 1200
        case 1: delayMs = 2200
        default: delayMs = 3500
        }
        scheduleRecoveryLocked(
            delayMs: delayMs,
            allowHoldBounce: true,
            reason: "probe_\(probeAttemptCount + 1)",
            fromProbe: true
        )
    }

    private func attemptRecovery(generation: Int, reason: String, allowHoldBounce: Bool, fromProbe: Bool) {
        stateLock.lock()
        guard isRunning, generation == recoveryGeneration else {
            stateLock.unlock()
            return
        }
        let stillNeedsRecovery = isInterrupted || (engine?.isRunning != true)
        guard stillNeedsRecovery else {
            stateLock.unlock()
            return
        }
        let isForeground = appIsActiveCached
        if fromProbe {
            probeAttemptCount += 1
        }
        let currentProbeCount = probeAttemptCount
        stateLock.unlock()

        if CallKitManager.shared.hasExternalActiveCall() {
            recordDiagnostic("recovery skipped (\(reason)): external CallKit call active")
            return
        }

        let session = AVAudioSession.sharedInstance()
        if !isForeground && (fromProbe || reason == "interruption_ended") {
            // With `.mixWithOthers`, `isOtherAudioPlaying` is true while peacefully coexisting with
            // apps like Instagram; only defer when iOS explicitly signals exclusive audio takeover.
            if session.secondaryAudioShouldBeSilencedHint {
                if !fromProbe || currentProbeCount <= 2 {
                    recordDiagnostic(
                        "recovery deferred (\(reason)): otherAudio=\(session.isOtherAudioPlaying) silenceHint=\(session.secondaryAudioShouldBeSilencedHint)"
                    )
                }
                scheduleNextInterruptedProbeIfNeeded(expectedGen: generation)
                return
            }
        }

        // Layer 1: Reconfigure category/mode and reactivate the audio session directly.
        CallKitManager.shared.configureAudioSession(on: session, source: "rec_\(reason)")
        do {
            try session.setActive(true)
            let route = session.currentRoute
            if !route.inputs.isEmpty {
                var rebuilt = false
                var restoreSpeaker = false
                stateLock.lock()
                if isRunning && generation == recoveryGeneration {
                    teardownEngineLocked()
                    converter = nil
                    lastInputFormat = nil
                    rxRingLock.lock()
                    rxRing.removeAll()
                    rxRingLock.unlock()
                    txRingLock.lock()
                    txRing.removeAll()
                    txRingLock.unlock()
                    jitterBuffer.reset()
                    isInterrupted = false
                    holdBounceAttemptedInEpisode = false
                    probeAttemptCount = 0
                    rebuilt = buildAndStartEngineLocked()
                    if rebuilt {
                        recoveryGeneration &+= 1
                        restoreSpeaker = speakerBeforeInterruption && !Self.hasExternalOutputPort(session.currentRoute)
                        speakerBeforeInterruption = false
                    } else {
                        isInterrupted = true
                    }
                }
                stateLock.unlock()

                if rebuilt {
                    recordDiagnostic("recovery OK (\(reason)) restoreSpeaker=\(restoreSpeaker)")
                    if restoreSpeaker {
                        routeSessionQueue.asyncAfter(deadline: .now() + .milliseconds(120)) { [weak self] in
                            self?.setSpeakerEnabled(true)
                        }
                    }
                    return
                }
            } else {
                recordDiagnostic("recovery setActive ok but inputs still empty (\(reason))")
            }
        } catch {
            let nsErr = error as NSError
            recordDiagnostic(
                "recovery setActive ERR (\(reason)) domain=\(nsErr.domain) code=\(nsErr.code) fg=\(isForeground)"
            )
        }

        // Layer 2: Background CallKit entitlement block (e.g. MissingEntitlement 1701737535) or empty input route.
        let effectiveBounceAllowed = allowHoldBounce && (!fromProbe || currentProbeCount >= 2)
        if effectiveBounceAllowed {
            var shouldBounce = false
            stateLock.lock()
            if isRunning && generation == recoveryGeneration && !holdBounceAttemptedInEpisode {
                holdBounceAttemptedInEpisode = true
                shouldBounce = true
            }
            stateLock.unlock()

            if shouldBounce && CallKitManager.shared.reclaimAudioActivationIfNeeded(source: reason) {
                return
            }
        }

        scheduleNextInterruptedProbeIfNeeded(expectedGen: generation)
    }

    func checkRecoveryAfterUnhold() {
        stateLock.lock()
        let needsProbe = isRunning && (isInterrupted || engine?.isRunning != true)
        if needsProbe {
            recordDiagnostic("post-unhold still needs recovery -> Layer 1 probe")
            scheduleRecoveryLocked(delayMs: 100, allowHoldBounce: false, reason: "post_unhold", fromProbe: false)
        }
        stateLock.unlock()
    }

    var isSessionRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isRunning
    }

    func needsCallAudioRecovery() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !isRunning || isInterrupted || (engine?.isRunning != true)
    }

    func triggerRecoveryIfNeeded(reason: String) {
        stateLock.lock()
        if isRunning && (isInterrupted || engine?.isRunning != true) {
            recordDiagnostic("triggerRecoveryIfNeeded(\(reason))")
            scheduleRecoveryLocked(delayMs: 80, allowHoldBounce: true, reason: reason, fromProbe: false)
        }
        stateLock.unlock()
    }

    func forceRecoverActiveCall() {
        stateLock.lock()
        guard isRunning else {
            stateLock.unlock()
            return
        }
        recordDiagnostic("forceRecoverActiveCall")
        holdBounceAttemptedInEpisode = false
        probeAttemptCount = 0
        isInterrupted = true
        recoveryGeneration &+= 1
        teardownEngineLocked()
        converter = nil
        lastInputFormat = nil
        scheduleRecoveryLocked(delayMs: 60, allowHoldBounce: true, reason: "manual_refresh", fromProbe: false)
        stateLock.unlock()
    }

    func setMuted(_ muted: Bool) {
        stateLock.lock()
        isMutedLocked = muted
        stateLock.unlock()
        DispatchQueue.main.async {
            if self.isMuted != muted {
                self.isMuted = muted
            }
        }
    }

    private func startMetricsTimerLocked() {
        metricsTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: routeSessionQueue)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.publishAudioMetrics()
        }
        metricsTimer = timer
        timer.resume()
    }

    private func stopMetricsTimerLocked() {
        metricsTimer?.cancel()
        metricsTimer = nil
    }

    private func publishAudioMetrics() {
        stateLock.lock()
        let running = isRunning
        let txCnt = txPacketCount
        stateLock.unlock()

        let snapshot: AudioCallMetrics
        if running {
            let jb = jitterBuffer.statsSnapshot()
            snapshot = AudioCallMetrics(
                txPackets: txCnt,
                rxPackets: jb.receivedFrames,
                plcFrames: jb.plcFrames,
                lateDropFrames: jb.lateDropFrames,
                queuedFrames: jb.queuedFrames
            )
        } else {
            snapshot = .empty
        }
        DispatchQueue.main.async {
            if self.callAudioMetrics != snapshot {
                self.callAudioMetrics = snapshot
            }
        }
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

        ensureSessionObserversLocked()
        activeCallHash = BridgeCrypto.fnv1a32(callId)
        onSendAudioPacket = sendAudioPacket

        let session = AVAudioSession.sharedInstance()
        let inputsReady = !session.currentRoute.inputs.isEmpty
        if isRunning && !isInterrupted && engine?.isRunning == true && inputsReady {
            return
        }

        recoveryWorkItem?.cancel()
        recoveryWorkItem = nil
        teardownEngineLocked()

        let shouldRestoreSpeaker = speakerBeforeInterruption && !Self.hasExternalOutputPort(session.currentRoute)
        speakerBeforeInterruption = false
        probeAttemptCount = 0
        recoveryGeneration &+= 1

        if opus == nil {
            guard let codec = OpusWrapper(bitrateBps: 32_000, complexity: 7) else {
                isRunning = false
                return
            }
            opus = codec
        }
        if !isRunning {
            jitterBuffer.resetAllStats()
            txSeq = 0
            txTimestamp = 0
            txPacketCount = 0
            isMutedLocked = false
            DispatchQueue.main.async {
                self.isMuted = false
                self.callAudioMetrics = .empty
            }
        } else {
            jitterBuffer.reset()
        }

        txRingLock.lock()
        txRing.removeAll()
        txRingLock.unlock()

        rxRingLock.lock()
        rxRing.removeAll()
        rxRingLock.unlock()

        converter = nil
        lastInputFormat = nil

        isRunning = true
        holdBounceAttemptedInEpisode = false
        startMetricsTimerLocked()

        if !inputsReady {
            isInterrupted = true
            speakerBeforeInterruption = shouldRestoreSpeaker
            recordDiagnostic("start deferred: no input route")
            scheduleRecoveryLocked(delayMs: 800, allowHoldBounce: false, reason: "start_no_input", fromProbe: true)
            return
        }

        isInterrupted = false
        if buildAndStartEngineLocked() {
            if shouldRestoreSpeaker {
                recordDiagnostic("start restoring speaker after interruption")
                routeSessionQueue.asyncAfter(deadline: .now() + .milliseconds(120)) { [weak self] in
                    self?.setSpeakerEnabled(true)
                }
            }
        } else {
            isInterrupted = true
            speakerBeforeInterruption = shouldRestoreSpeaker
            scheduleRecoveryLocked(delayMs: 250, allowHoldBounce: false, reason: "start_failed", fromProbe: true)
        }
    }

    private func buildAndStartEngineLocked() -> Bool {
        ensureSessionObserversLocked()
        let session = AVAudioSession.sharedInstance()
        if session.currentRoute.inputs.isEmpty {
            recordDiagnostic("engine build deferred: no active input route cat=\(session.category.rawValue) mode=\(session.mode.rawValue)")
            isInterrupted = true
            refreshRouteSnapshot(session: session)
            return false
        }

        let eng = AVAudioEngine()
        let inputNode = eng.inputNode
        let outputNode = eng.outputNode
        let mainMixer = eng.mainMixerNode
        let renderCodec = self.opus

        let srcNode = AVAudioSourceNode(format: target48kMonoFloat) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let count = Int(frameCount)
            guard let ptr = abl.first?.mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            self.fillOutputSamples(dst: ptr, count: count, codec: renderCodec)
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
        var tapUsed = false
        let tapFmt = inputNode.outputFormat(forBus: 0)
        activeInputSampleRate = tapFmt.sampleRate
        activeInputChannelCount = tapFmt.channelCount

        guard tapFmt.channelCount > 0 && tapFmt.sampleRate > 0 else {
            recordDiagnostic("engine build aborted: invalid input fmt \(Int(tapFmt.sampleRate))Hz/\(tapFmt.channelCount)ch")
            destroyEngineInstanceLocked(eng, srcNode: srcNode, sinkNode: nil, tapUsed: false)
            isInterrupted = true
            return false
        }

        let sink = AVAudioSinkNode { [weak self] _, frameCount, audioBufferList -> OSStatus in
            self?.handleSinkInput(frameCount: frameCount, audioBufferList: audioBufferList, format: tapFmt)
            return noErr
        }
        eng.attach(sink)
        eng.connect(inputNode, to: sink, format: tapFmt)
        attachedSink = sink

        eng.prepare()
        do {
            try eng.start()
            jitterBuffer.trimToTarget()
            engine = eng
            sourceNode = srcNode
            sinkNode = attachedSink
            usingTapFallback = tapUsed
            observeConfigChanges(for: eng)
            recordDiagnostic(
                "engine started vpIn=\(inputNode.isVoiceProcessingEnabled) vpOut=\(outputNode.isVoiceProcessingEnabled) tap=\(Int(tapFmt.sampleRate))Hz/\(tapFmt.channelCount)ch cat=\(session.category.rawValue) mode=\(session.mode.rawValue) route=[\(Self.describeRoute(session.currentRoute))]"
            )
            refreshRouteSnapshot(session: session)
            return true
        } catch {
            let primaryErr = error as NSError
            recordDiagnostic("engine start primary ERR domain=\(primaryErr.domain) code=\(primaryErr.code)")
            // Fallback to installTap if a specific iOS route disallows AVAudioSinkNode connection.
            if let sink = attachedSink {
                eng.disconnectNodeInput(sink)
                eng.detach(sink)
                attachedSink = nil
            }
            inputNode.installTap(onBus: 0, bufferSize: 960, format: nil) { [weak self] buffer, _ in
                self?.txEncodeQueue.async {
                    self?.processMicInput(buffer)
                }
            }
            tapUsed = true
            eng.prepare()
            do {
                try eng.start()
                jitterBuffer.trimToTarget()
                engine = eng
                sourceNode = srcNode
                sinkNode = nil
                usingTapFallback = tapUsed
                observeConfigChanges(for: eng)
                recordDiagnostic(
                    "engine started (tapFallback) vpIn=\(inputNode.isVoiceProcessingEnabled) tap=\(Int(tapFmt.sampleRate))Hz/\(tapFmt.channelCount)ch route=[\(Self.describeRoute(session.currentRoute))]"
                )
                refreshRouteSnapshot(session: session)
                return true
            } catch {
                let nsErr = error as NSError
                recordDiagnostic("engine start fallback ERR domain=\(nsErr.domain) code=\(nsErr.code)")
                destroyEngineInstanceLocked(eng, srcNode: srcNode, sinkNode: nil, tapUsed: tapUsed)
                return false
            }
        }
    }

    func onIncomingAudioPacket(seq: UInt16, payload: Data) {
        stateLock.lock()
        let active = isRunning && !isInterrupted
        stateLock.unlock()
        guard active else { return }
        jitterBuffer.push(seq: seq, payload: payload)
    }

    func pauseForCallKitDeactivation(preserveRecoveryState: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }

        recoveryWorkItem?.cancel()
        recoveryWorkItem = nil
        recoveryGeneration &+= 1
        teardownEngineLocked()
        converter = nil
        lastInputFormat = nil

        if preserveRecoveryState && isRunning {
            isInterrupted = true
            return
        }

        stopMetricsTimerLocked()
        isRunning = false
        isInterrupted = false
        isMutedLocked = false
        speakerBeforeInterruption = false
        holdBounceAttemptedInEpisode = false
        probeAttemptCount = 0
        opus?.close()
        opus = nil
        jitterBuffer.reset()
        onSendAudioPacket = nil
        DispatchQueue.main.async {
            self.isMuted = false
            self.callAudioMetrics = .empty
        }
    }

    func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }

        recoveryWorkItem?.cancel()
        recoveryWorkItem = nil
        recoveryGeneration &+= 1
        stopMetricsTimerLocked()

        let wasActive = isRunning || engine != nil || opus != nil
        isRunning = false
        isInterrupted = false
        isMutedLocked = false
        speakerBeforeInterruption = false
        holdBounceAttemptedInEpisode = false
        probeAttemptCount = 0
        DispatchQueue.main.async {
            self.isMuted = false
            self.callAudioMetrics = .empty
        }

        guard wasActive else { return }

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
        if let eng = engine {
            destroyEngineInstanceLocked(eng, srcNode: sourceNode, sinkNode: sinkNode, tapUsed: usingTapFallback)
        }
        engine = nil
        sourceNode = nil
        sinkNode = nil
        usingTapFallback = false
        activeInputSampleRate = 0
        activeInputChannelCount = 0
    }

    private func destroyEngineInstanceLocked(
        _ eng: AVAudioEngine,
        srcNode: AVAudioNode?,
        sinkNode: AVAudioNode?,
        tapUsed: Bool
    ) {
        eng.stop()
        if tapUsed {
            eng.inputNode.removeTap(onBus: 0)
        }
        if let sink = sinkNode {
            eng.disconnectNodeInput(sink)
            eng.detach(sink)
        }
        if let src = srcNode {
            eng.disconnectNodeOutput(src)
            eng.detach(src)
        }
        eng.reset()
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
        guard isRunning else { return }

        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        if route.inputs.isEmpty {
            recordDiagnostic("configChange deferred: no input route=[\(Self.describeRoute(route))]")
            let newlyInterrupted = enterInterruptedStateLocked(
                reason: "config_no_input",
                prevRoute: nil,
                currentRoute: route
            )
            if newlyInterrupted {
                scheduleRecoveryLocked(delayMs: 1200, allowHoldBounce: false, reason: "config_probe", fromProbe: true)
            }
            return
        }

        guard !isInterrupted, let eng = engine else { return }

        let currentFmt = eng.inputNode.outputFormat(forBus: 0)
        let sameFormat =
            currentFmt.sampleRate > 0 &&
            currentFmt.sampleRate == activeInputSampleRate &&
            currentFmt.channelCount == activeInputChannelCount

        recordDiagnostic(
            "configChange engRunning=\(eng.isRunning) old=\(Int(activeInputSampleRate))Hz/\(activeInputChannelCount)ch new=\(Int(currentFmt.sampleRate))Hz/\(currentFmt.channelCount)ch route=[\(Self.describeRoute(route))]"
        )
        refreshRouteSnapshot(session: session)

        if eng.isRunning && sameFormat {
            return
        }

        // For Earpiece <-> Speaker toggles where sampleRate/channels stay unchanged, restart the
        // existing engine in place without re-initializing VoiceProcessingIO (which resets CallKit speaker UI).
        if !eng.isRunning && sameFormat {
            eng.prepare()
            do {
                try eng.start()
                jitterBuffer.trimToTarget()
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
        if !buildAndStartEngineLocked() {
            isInterrupted = true
            scheduleRecoveryLocked(delayMs: 250, allowHoldBounce: false, reason: "config_rebuild_failed", fromProbe: true)
        }
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

        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        if mCount == 1,
           format.sampleRate == 48_000,
           format.channelCount == 1,
           format.commonFormat == .pcmFormatFloat32,
           let buf = abl.first,
           let mData = buf.mData,
           buf.mDataByteSize > 0 {
            let expectedBytes = min(Int(buf.mDataByteSize), frames * MemoryLayout<Float>.size)
            guard expectedBytes >= MemoryLayout<Float>.size else { return }
            let rawCopy = Data(bytes: mData, count: expectedBytes)
            txEncodeQueue.async { [weak self] in
                guard let self else { return }
                let sampleCount = rawCopy.count / MemoryLayout<Float>.size
                rawCopy.withUnsafeBytes { raw in
                    guard let floatPtr = raw.bindMemory(to: Float.self).baseAddress else { return }
                    self.pushConvertedSamplesAndEncode(floatPtr, sampleCount: sampleCount)
                }
            }
            return
        }

        var copied: [Data] = []
        copied.reserveCapacity(mCount)
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
        if buffer.format.sampleRate == 48_000,
           buffer.format.channelCount == 1,
           buffer.format.commonFormat == .pcmFormatFloat32,
           let ch0 = buffer.floatChannelData?[0] {
            pushConvertedSamplesAndEncode(ch0, sampleCount: Int(buffer.frameLength))
            return
        }

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
        pushConvertedSamplesAndEncode(ch0, sampleCount: Int(outBuf.frameLength))
    }

    private func pushConvertedSamplesAndEncode(_ samples: UnsafePointer<Float>, sampleCount: Int) {
        guard sampleCount > 0 else { return }

        stateLock.lock()
        let muted = isMutedLocked
        let running = isRunning
        let codec = opus
        let callHash = activeCallHash
        let sender = onSendAudioPacket
        stateLock.unlock()

        guard running, let codec, let sender else { return }

        let frameLen = Int(OpusWrapper.frameSamples)
        txRingLock.lock()
        txRing.push(samples, count: sampleCount)
        while true {
            let popped = txScratchPcm.withUnsafeMutableBufferPointer { ptr -> Bool in
                guard let base = ptr.baseAddress else { return false }
                return txRing.popFrameAsInt16(into: base, count: frameLen, muted: muted)
            }
            if !popped { break }
            txRingLock.unlock()

            let encoded = txScratchPcm.withUnsafeBufferPointer { pcmPtr -> Data? in
                guard let base = pcmPtr.baseAddress else { return nil }
                return codec.encode(pcm: base, sampleCount: frameLen, scratchOut: &txOpusScratch)
            }
            if let encoded {
                stateLock.lock()
                let seq = txSeq
                let ts = txTimestamp
                txSeq = txSeq &+ 1
                txTimestamp = txTimestamp &+ UInt32(OpusWrapper.frameSamples)
                txPacketCount += 1
                stateLock.unlock()
                sender(encoded, seq, ts, callHash)
            }
            txRingLock.lock()
        }
        txRingLock.unlock()
    }

    private func fillOutputSamples(dst: UnsafeMutablePointer<Float>, count: Int, codec: OpusWrapper?) {
        rxRingLock.lock()
        defer { rxRingLock.unlock() }

        let frameLen = Int(OpusWrapper.frameSamples)
        // Guard against unbounded latency buildup after audio route/BT stalls (cap at ~160ms).
        if rxRing.count > 7680 {
            rxRing.dropOldest(rxRing.count - 3840)
        }

        if let codec {
            while rxRing.count < count {
                let res = jitterBuffer.pop()
                switch res {
                case .frame(let payload, let useFec):
                    let decCount = codec.decode(packet: payload, pcmOut: &rxScratchPcm, decodeFec: useFec)
                    if decCount > 0 {
                        rxScratchPcm.withUnsafeBufferPointer { ptr in
                            if let base = ptr.baseAddress {
                                rxRing.pushInt16Scaled(base, count: Int(decCount))
                            }
                        }
                    } else {
                        rxRing.pushZeros(count: frameLen)
                    }
                case .missingPlc:
                    let decCount = codec.decode(packet: nil, pcmOut: &rxScratchPcm, decodeFec: false)
                    if decCount > 0 {
                        rxScratchPcm.withUnsafeBufferPointer { ptr in
                            if let base = ptr.baseAddress {
                                rxRing.pushInt16Scaled(base, count: Int(decCount))
                            }
                        }
                    } else {
                        rxRing.pushZeros(count: frameLen)
                    }
                case .underrunSilence:
                    // Zero-fill only the remaining samples directly in `dst` instead of queuing excess silence.
                    let avail = rxRing.pop(into: dst, count: count)
                    if avail < count {
                        dst.advanced(by: avail).update(repeating: 0, count: count - avail)
                    }
                    return
                }
            }
        }

        let avail = rxRing.pop(into: dst, count: count)
        if avail < count {
            dst.advanced(by: avail).update(repeating: 0, count: count - avail)
        }
    }
}
