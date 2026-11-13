import AVFoundation
import CallKit
import Foundation

final class CallKitManager: NSObject, CXProviderDelegate {
    static let shared = CallKitManager()

    private let provider: CXProvider
    private let callController = CXCallController()
    private let lock = NSLock()

    private var uuidByCallId: [String: UUID] = [:]
    private var callIdByUuid: [UUID: String] = [:]
    private var numberByUuid: [UUID: String] = [:]
    private var simSlotByUuid: [UUID: Int] = [:]
    private var callCreatedAtByUuid: [UUID: Date] = [:]
    private var outgoingUuids: Set<UUID> = []
    private var reportedConnectingUuids: Set<UUID> = []
    private var reportedConnectedUuids: Set<UUID> = []
    private var pendingOutgoingUuid: UUID?
    private var activeAudioCallId: String?
    private var userHeldCallUuids: Set<UUID> = []
    private var internalHoldBounceUuids: Set<UUID> = []
    private var lastHoldBounceAt: Date = .distantPast

    #if compiler(>=6.2)
    private static let bluetoothHfpOption: AVAudioSession.CategoryOptions = .allowBluetoothHFP
    #else
    private static let bluetoothHfpOption: AVAudioSession.CategoryOptions = .allowBluetooth
    #endif

    // Coexist with secondary media apps (e.g. Instagram feed/Reels) like WhatsApp/Telegram via
    // `.mixWithOthers`, while pairing `.allowBluetoothHFP` with `.allowBluetoothA2DP` so CallKit's
    // native Speaker toggle highlight does not break (Apple Developer Forums thread/64544).
    private static let desiredCategoryOptions: AVAudioSession.CategoryOptions = [
        bluetoothHfpOption,
        .allowBluetoothA2DP,
        .mixWithOthers
    ]

    private static let disallowedCategoryOptions: AVAudioSession.CategoryOptions = [
        .defaultToSpeaker,
        .duckOthers
    ]

    private override init() {
        let cfg = CXProviderConfiguration()
        cfg.supportedHandleTypes = [.phoneNumber]
        cfg.supportsVideo = false
        cfg.maximumCallsPerCallGroup = 2
        cfg.maximumCallGroups = 1
        cfg.includesCallsInRecents = true
        cfg.ringtoneSound = nil
        provider = CXProvider(configuration: cfg)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    func reportIncomingCall(
        callId: String,
        number: String,
        contactName: String?,
        simSlot: Int,
        completion: ((Error?) -> Void)? = nil
    ) {
        let uuid: UUID
        lock.lock()
        if let existing = uuidByCallId[callId] {
            uuid = existing
        } else {
            uuid = UUID()
            uuidByCallId[callId] = uuid
            callIdByUuid[uuid] = callId
            numberByUuid[uuid] = number
            simSlotByUuid[uuid] = simSlot
            callCreatedAtByUuid[uuid] = Date()
        }
        lock.unlock()

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .phoneNumber, value: number)
        update.localizedCallerName = (contactName?.isEmpty == false ? contactName : number)
        update.hasVideo = false
        update.supportsGrouping = false
        update.supportsHolding = true
        update.supportsDTMF = true

        provider.reportNewIncomingCall(with: uuid, update: update) { err in
            if let err {
                self.removeMapping(uuid: uuid)
            }
            completion?(err)
        }
    }

    func startOutgoingCall(number: String, contactName: String? = nil, simSlot: Int = 0) {
        let allowed = CharacterSet(charactersIn: "0123456789+*#- ()")
        let clean = String(number.unicodeScalars.filter { allowed.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasDialableChars = clean.contains { $0.isNumber || $0 == "+" || $0 == "*" || $0 == "#" }
        guard hasDialableChars else { return }

        guard PairingStore.shared.load() != nil else {
            Task { @MainActor in
                BridgeClient.shared.reportUiError("Önce Ayarlar'dan Android ile eşleştirin")
            }
            return
        }

        let liveSystemCalls = callController.callObserver.calls.filter { !$0.hasEnded }
        let now = Date()

        lock.lock()
        if liveSystemCalls.isEmpty {
            // Self-heal any orphaned local call mappings if CallKit reports no active calls.
            clearAllMappingsLocked()
        } else {
            if let pend = pendingOutgoingUuid,
               let started = callCreatedAtByUuid[pend],
               now.timeIntervalSince(started) < 2.5 {
                // Ignore accidental double-tap while an outgoing request is already in flight.
                lock.unlock()
                return
            }
            lock.unlock()
            Task { @MainActor in
                BridgeClient.shared.reportUiError("Önce mevcut aramayı sonlandırın")
            }
            return
        }

        let uuid = UUID()
        let callId = uuid.uuidString
        pendingOutgoingUuid = uuid
        uuidByCallId[callId] = uuid
        callIdByUuid[uuid] = callId
        numberByUuid[uuid] = clean
        simSlotByUuid[uuid] = simSlot
        callCreatedAtByUuid[uuid] = now
        outgoingUuids.insert(uuid)
        lock.unlock()

        let handle = CXHandle(type: .phoneNumber, value: clean)
        let action = CXStartCallAction(call: uuid, handle: handle)
        action.contactIdentifier = contactName
        action.isVideo = false
        callController.request(CXTransaction(action: action)) { err in
            if let err {
                self.removeMapping(uuid: uuid)
                Task { @MainActor in
                    BridgeClient.shared.reportUiError("Arama başlatılamadı: \(err.localizedDescription)")
                }
            }
        }
    }

    func endCall(callId: String) {
        lock.lock()
        let uuid = uuidByCallId[callId]
        lock.unlock()
        guard let uuid else { return }
        callController.request(CXTransaction(action: CXEndCallAction(call: uuid))) { _ in }
    }

    func sendDtmf(callId: String, digits: String) {
        lock.lock()
        let uuid = uuidByCallId[callId]
        lock.unlock()
        guard let uuid else { return }
        let action = CXPlayDTMFCallAction(call: uuid, digits: digits, type: .singleTone)
        callController.request(CXTransaction(action: action)) { _ in }
    }

    @MainActor
    func handleRemoteCallState(_ dto: CallStateDto) {
        lock.lock()
        var uuid = uuidByCallId[dto.callId]
        if uuid == nil && dto.direction == "outgoing", let pend = pendingOutgoingUuid {
            uuid = pend
            uuidByCallId[dto.callId] = pend
            callIdByUuid[pend] = dto.callId
            if activeAudioCallId == pend.uuidString || activeAudioCallId == nil {
                activeAudioCallId = dto.callId
            }
            pendingOutgoingUuid = nil
            AudioEngineManager.shared.updateCallHash(dto.callId)
        }
        lock.unlock()

        switch dto.state {
        case "ringing":
            if uuid == nil {
                let resolvedName = dto.contactName ?? ContactsHelper.shared.resolveName(for: dto.number)
                reportIncomingCall(
                    callId: dto.callId,
                    number: dto.number,
                    contactName: resolvedName,
                    simSlot: dto.simSlot
                )
            }
        case "dialing":
            if let uuid, dto.direction == "outgoing" {
                var shouldReport = false
                lock.lock()
                if outgoingUuids.contains(uuid), !reportedConnectingUuids.contains(uuid) {
                    reportedConnectingUuids.insert(uuid)
                    shouldReport = true
                }
                lock.unlock()
                if shouldReport {
                    provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())
                }
            }
        case "active":
            if let uuid, dto.direction == "outgoing" {
                var shouldReport = false
                lock.lock()
                if outgoingUuids.contains(uuid), !reportedConnectedUuids.contains(uuid) {
                    reportedConnectedUuids.insert(uuid)
                    shouldReport = true
                }
                lock.unlock()
                if shouldReport {
                    provider.reportOutgoingCall(with: uuid, connectedAt: Date())
                }
            }
        case "disconnected":
            if let uuid {
                let reason: CXCallEndedReason = (dto.connectedAtMs == 0 && dto.disconnectReason != nil)
                    ? .failed
                    : .remoteEnded
                provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
                removeMapping(uuid: uuid)
            }
            lock.lock()
            let emptyAfterRemove = callIdByUuid.isEmpty
            lock.unlock()
            if emptyAfterRemove {
                AudioEngineManager.shared.stop()
                BridgeClient.shared.stopUdpSession()
            }
        default:
            break
        }
    }

    @MainActor
    func reconcileActiveCalls(_ remoteCalls: [CallStateDto]) {
        let remoteIds = Set(remoteCalls.map(\.callId))
        let now = Date()
        var staleUuids: [UUID] = []

        lock.lock()
        for (uuid, cid) in callIdByUuid {
            if !remoteIds.contains(cid) {
                let age = callCreatedAtByUuid[uuid].map { now.timeIntervalSince($0) } ?? 999
                if age > 8.0 {
                    staleUuids.append(uuid)
                }
            }
        }
        lock.unlock()

        for uuid in staleUuids {
            provider.reportCall(with: uuid, endedAt: now, reason: .remoteEnded)
            removeMapping(uuid: uuid)
        }
        if !staleUuids.isEmpty {
            lock.lock()
            let emptyAfterRemove = callIdByUuid.isEmpty
            lock.unlock()
            if emptyAfterRemove {
                AudioEngineManager.shared.stop()
                BridgeClient.shared.stopUdpSession()
            }
        }
    }

    func failCallIfStillTracked(uuid: UUID) {
        lock.lock()
        let tracked = callIdByUuid[uuid] != nil
        lock.unlock()
        guard tracked else { return }

        provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
        removeMapping(uuid: uuid)

        lock.lock()
        let emptyAfterRemove = callIdByUuid.isEmpty
        lock.unlock()
        if emptyAfterRemove {
            AudioEngineManager.shared.stop()
            Task { @MainActor in
                BridgeClient.shared.stopUdpSession()
            }
        }
    }

    // MARK: - CXProviderDelegate

    func providerDidReset(_ provider: CXProvider) {
        AudioEngineManager.shared.recordDiagnostic("CallKit providerDidReset")
        AudioEngineManager.shared.stop()
        AudioEngineManager.shared.clearCallRouteState()
        Task { @MainActor in
            BridgeClient.shared.stopUdpSession()
        }
        lock.lock()
        clearAllMappingsLocked()
        lock.unlock()
    }

    func hasExternalActiveCall() -> Bool {
        lock.lock()
        let tracked = Set(callIdByUuid.keys)
        lock.unlock()
        return callController.callObserver.calls.contains { !$0.hasEnded && !tracked.contains($0.uuid) }
    }

    /// Reclaims CallKit audio activation in background (e.g., after third-party app interruption
    /// triggers MissingEntitlement `1701737535`) via a rate-limited internal hold-bounce that does
    /// not forward `set_hold` to Android.
    @discardableResult
    func reclaimAudioActivationIfNeeded(source: String) -> Bool {
        lock.lock()
        let tracked = Set(callIdByUuid.keys)
        let targetUuid = activeAudioCallId.flatMap { uuidByCallId[$0] } ?? callIdByUuid.keys.first
        guard let uuid = targetUuid,
              !userHeldCallUuids.contains(uuid),
              !internalHoldBounceUuids.contains(uuid),
              Date().timeIntervalSince(lastHoldBounceAt) >= 10.0 else {
            lock.unlock()
            return false
        }
        lock.unlock()

        let systemCalls = callController.callObserver.calls
        if systemCalls.contains(where: { !$0.hasEnded && !tracked.contains($0.uuid) }) {
            AudioEngineManager.shared.recordDiagnostic("CallKit hold-bounce skipped: external call active")
            return false
        }
        guard let sysCall = systemCalls.first(where: { $0.uuid == uuid && !$0.hasEnded }) else {
            AudioEngineManager.shared.recordDiagnostic("CallKit hold-bounce skipped: no live CallKit call")
            return false
        }

        lock.lock()
        guard callIdByUuid[uuid] != nil,
              !userHeldCallUuids.contains(uuid),
              !internalHoldBounceUuids.contains(uuid) else {
            lock.unlock()
            return false
        }
        internalHoldBounceUuids.insert(uuid)
        lastHoldBounceAt = Date()
        lock.unlock()

        let alreadyHeld = sysCall.isOnHold
        AudioEngineManager.shared.recordDiagnostic(
            "CallKit hold-bounce start src=\(source) alreadyHeld=\(alreadyHeld)"
        )

        let finishBounce: (UUID) -> Void = { [weak self] bounceUuid in
            guard let self else { return }
            self.lock.lock()
            self.internalHoldBounceUuids.remove(bounceUuid)
            self.lock.unlock()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(450)) {
                AudioEngineManager.shared.checkRecoveryAfterUnhold()
            }
        }

        let sendUnhold = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillActive = self.callIdByUuid[uuid] != nil && self.internalHoldBounceUuids.contains(uuid)
            self.lock.unlock()
            guard stillActive else {
                finishBounce(uuid)
                return
            }
            let unhold = CXSetHeldCallAction(call: uuid, onHold: false)
            self.callController.request(CXTransaction(action: unhold)) { err in
                if let err {
                    let nsErr = err as NSError
                    AudioEngineManager.shared.recordDiagnostic(
                        "CallKit hold-bounce unhold ERR domain=\(nsErr.domain) code=\(nsErr.code)"
                    )
                }
                finishBounce(uuid)
            }
        }

        if alreadyHeld {
            sendUnhold()
        } else {
            let hold = CXSetHeldCallAction(call: uuid, onHold: true)
            callController.request(CXTransaction(action: hold)) { err in
                if let err {
                    let nsErr = err as NSError
                    AudioEngineManager.shared.recordDiagnostic(
                        "CallKit hold-bounce hold ERR domain=\(nsErr.domain) code=\(nsErr.code)"
                    )
                    finishBounce(uuid)
                    return
                }
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(250)) {
                    sendUnhold()
                }
            }
        }
        return true
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        configureAudioSession(source: "start_action")
        lock.lock()
        let number = numberByUuid[action.callUUID] ?? action.handle.value
        let simSlot = simSlotByUuid[action.callUUID] ?? 0
        let cid = callIdByUuid[action.callUUID] ?? action.callUUID.uuidString
        outgoingUuids.insert(action.callUUID)
        activeAudioCallId = cid
        lock.unlock()

        action.fulfill()
        let update = CXCallUpdate()
        update.supportsHolding = true
        update.supportsGrouping = false
        update.supportsDTMF = true
        update.hasVideo = false
        provider.reportCall(with: action.callUUID, updated: update)

        Task { @MainActor in
            let msg = BridgeWsMessage(type: "place_call", callId: cid, number: number, simSlot: simSlot)
            BridgeClient.shared.sendPlaceCall(msg) { ok in
                if ok {
                    BridgeClient.shared.startUdpSession(callId: cid)
                } else {
                    BridgeClient.shared.reportUiError("Android'e bağlanılamadı, arama iptal edildi")
                    self.failCallIfStillTracked(uuid: action.callUUID)
                }
            }
        }
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        configureAudioSession(source: "answer_action")
        lock.lock()
        let callId = callIdByUuid[action.callUUID]
        activeAudioCallId = callId
        lock.unlock()

        if let callId {
            Task { @MainActor in
                BridgeClient.shared.sendCommand(BridgeWsMessage(type: "answer_call", callId: callId))
                BridgeClient.shared.startUdpSession(callId: callId)
            }
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        lock.lock()
        let callId = callIdByUuid[action.callUUID]
        lock.unlock()
        removeMapping(uuid: action.callUUID)

        AudioEngineManager.shared.stop()
        Task { @MainActor in
            BridgeClient.shared.sendCommand(BridgeWsMessage(type: "reject_or_hangup", callId: callId))
            BridgeClient.shared.stopUdpSession()
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        AudioEngineManager.shared.setMuted(action.isMuted)
        lock.lock()
        let callId = callIdByUuid[action.callUUID]
        lock.unlock()
        Task { @MainActor in
            BridgeClient.shared.sendCommand(
                BridgeWsMessage(type: "set_mute", callId: callId, muted: action.isMuted)
            )
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        lock.lock()
        let callId = callIdByUuid[action.callUUID]
        let isInternalBounce = internalHoldBounceUuids.contains(action.callUUID)
        if !isInternalBounce {
            if action.isOnHold {
                userHeldCallUuids.insert(action.callUUID)
            } else {
                userHeldCallUuids.remove(action.callUUID)
            }
        }
        lock.unlock()

        AudioEngineManager.shared.recordDiagnostic(
            "CallKit setHeld held=\(action.isOnHold) internal=\(isInternalBounce)"
        )

        if !action.isOnHold {
            configureAudioSession(source: isInternalBounce ? "bounce_unhold" : "unhold_action")
        }
        if !isInternalBounce {
            Task { @MainActor in
                BridgeClient.shared.sendCommand(
                    BridgeWsMessage(type: "set_hold", callId: callId, held: action.isOnHold)
                )
            }
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        lock.lock()
        let callId = callIdByUuid[action.callUUID]
        lock.unlock()
        Task { @MainActor in
            for ch in action.digits {
                BridgeClient.shared.sendCommand(
                    BridgeWsMessage(type: "send_dtmf", callId: callId, digit: String(ch))
                )
            }
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        let audio = AudioEngineManager.shared
        audio.recordDiagnostic(
            "CallKit didActivate cat=\(audioSession.category.rawValue) mode=\(audioSession.mode.rawValue) opts=\(audioSession.categoryOptions.rawValue) sr=\(Int(audioSession.sampleRate))Hz route=[\(AudioEngineManager.describeRoute(audioSession.currentRoute))]"
        )
        configureAudioSession(on: audioSession, source: "didActivate_verify")

        lock.lock()
        let cid = activeAudioCallId ?? callIdByUuid.values.first ?? "call-active"
        lock.unlock()

        audio.start(callId: cid) { encoded, seq, ts, callHash in
            BridgeClient.shared.sendOpusFrame(encoded: encoded, seq: seq, ts: ts, callHash: callHash)
        }
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        lock.lock()
        let hasActiveCalls = !callIdByUuid.isEmpty
        let isBounce = !internalHoldBounceUuids.isEmpty
        lock.unlock()

        AudioEngineManager.shared.recordDiagnostic(
            "CallKit didDeactivate hasCalls=\(hasActiveCalls) bounce=\(isBounce)"
        )
        AudioEngineManager.shared.pauseForCallKitDeactivation(preserveRecoveryState: isBounce)
        if !hasActiveCalls {
            AudioEngineManager.shared.clearCallRouteState()
            Task { @MainActor in
                BridgeClient.shared.stopUdpSession()
            }
        }
    }

    func configureAudioSession(
        on session: AVAudioSession = AVAudioSession.sharedInstance(),
        source: String = "default"
    ) {
        let audio = AudioEngineManager.shared
        var changed: [String] = []

        // Configure category and mode in two steps, only when they differ, and re-verify
        // categoryOptions afterward because `setMode(.voiceChat)` can strip `.mixWithOthers` or
        // `.allowBluetoothA2DP` (Telegram-iOS / GetStream CallKit pattern). Keeping `.allowBluetoothHFP`
        // paired with `.allowBluetoothA2DP` preserves CallKit's Speaker toggle state.
        let needsCategory =
            session.category != .playAndRecord ||
            !session.categoryOptions.contains(Self.desiredCategoryOptions) ||
            !session.categoryOptions.isDisjoint(with: Self.disallowedCategoryOptions)
        let needsMode = session.mode != .voiceChat

        if needsCategory {
            do {
                try session.setCategory(.playAndRecord, options: Self.desiredCategoryOptions)
                changed.append("cat")
            } catch {
                let nsErr = error as NSError
                audio.recordDiagnostic(
                    "setCategory(\(source)) ERR domain=\(nsErr.domain) code=\(nsErr.code): \(nsErr.localizedDescription)"
                )
            }
        }
        if needsMode {
            do {
                try session.setMode(.voiceChat)
                changed.append("mode")
            } catch {
                let nsErr = error as NSError
                audio.recordDiagnostic(
                    "setMode(\(source)) ERR domain=\(nsErr.domain) code=\(nsErr.code): \(nsErr.localizedDescription)"
                )
            }
        }
        if (needsCategory || needsMode) &&
            (!session.categoryOptions.contains(Self.desiredCategoryOptions) ||
             !session.categoryOptions.isDisjoint(with: Self.disallowedCategoryOptions)) {
            do {
                try session.setCategory(.playAndRecord, options: Self.desiredCategoryOptions)
                changed.append("cat_reapply")
            } catch {
                let nsErr = error as NSError
                audio.recordDiagnostic(
                    "setCategoryReapply(\(source)) ERR domain=\(nsErr.domain) code=\(nsErr.code): \(nsErr.localizedDescription)"
                )
            }
        }
        if abs(session.preferredIOBufferDuration - 0.02) > 0.002 {
            do {
                try session.setPreferredIOBufferDuration(0.02)
                changed.append("ioBuf")
            } catch {
                let nsErr = error as NSError
                audio.recordDiagnostic(
                    "setPreferredIOBufferDuration(\(source)) ERR domain=\(nsErr.domain) code=\(nsErr.code)"
                )
            }
        }
        if !session.prefersNoInterruptionsFromSystemAlerts {
            try? session.setPrefersNoInterruptionsFromSystemAlerts(true)
        }

        if !changed.isEmpty {
            audio.recordDiagnostic(
                "audioCfg(\(source)) updated=[\(changed.joined(separator: ","))] cat=\(session.category.rawValue) mode=\(session.mode.rawValue) opts=\(session.categoryOptions.rawValue) route=[\(AudioEngineManager.describeRoute(session.currentRoute))]"
            )
        } else {
            audio.recordDiagnostic(
                "audioCfg(\(source)) ok opts=\(session.categoryOptions.rawValue) route=[\(AudioEngineManager.describeRoute(session.currentRoute))]"
            )
        }
    }

    private func removeMapping(uuid: UUID) {
        lock.lock()
        if let cid = callIdByUuid.removeValue(forKey: uuid) {
            uuidByCallId.removeValue(forKey: cid)
            if activeAudioCallId == cid { activeAudioCallId = nil }
        }
        numberByUuid.removeValue(forKey: uuid)
        simSlotByUuid.removeValue(forKey: uuid)
        callCreatedAtByUuid.removeValue(forKey: uuid)
        outgoingUuids.remove(uuid)
        reportedConnectingUuids.remove(uuid)
        reportedConnectedUuids.remove(uuid)
        userHeldCallUuids.remove(uuid)
        internalHoldBounceUuids.remove(uuid)
        if pendingOutgoingUuid == uuid { pendingOutgoingUuid = nil }
        lock.unlock()
    }

    private func clearAllMappingsLocked() {
        uuidByCallId.removeAll()
        callIdByUuid.removeAll()
        numberByUuid.removeAll()
        simSlotByUuid.removeAll()
        callCreatedAtByUuid.removeAll()
        outgoingUuids.removeAll()
        reportedConnectingUuids.removeAll()
        reportedConnectedUuids.removeAll()
        userHeldCallUuids.removeAll()
        internalHoldBounceUuids.removeAll()
        pendingOutgoingUuid = nil
        activeAudioCallId = nil
    }
}
