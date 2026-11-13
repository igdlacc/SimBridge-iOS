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
    private var pendingOutgoingUuid: UUID?
    private var activeAudioCallId: String?

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
        let clean = number.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        let uuid = UUID()
        lock.lock()
        pendingOutgoingUuid = uuid
        numberByUuid[uuid] = clean
        simSlotByUuid[uuid] = simSlot
        lock.unlock()

        let handle = CXHandle(type: .phoneNumber, value: clean)
        let action = CXStartCallAction(call: uuid, handle: handle)
        action.contactIdentifier = contactName
        action.isVideo = false
        callController.request(CXTransaction(action: action)) { err in
            if err != nil {
                self.removeMapping(uuid: uuid)
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
            if let uuid {
                provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())
            }
        case "active":
            if let uuid {
                provider.reportOutgoingCall(with: uuid, connectedAt: Date())
            }
        case "disconnected":
            if let uuid {
                provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
                removeMapping(uuid: uuid)
            }
            AudioEngineManager.shared.stop()
            BridgeClient.shared.stopUdpSession()
        default:
            break
        }
    }

    // MARK: - CXProviderDelegate

    func providerDidReset(_ provider: CXProvider) {
        AudioEngineManager.shared.stop()
        Task { @MainActor in
            BridgeClient.shared.stopUdpSession()
        }
        lock.lock()
        uuidByCallId.removeAll()
        callIdByUuid.removeAll()
        numberByUuid.removeAll()
        simSlotByUuid.removeAll()
        pendingOutgoingUuid = nil
        activeAudioCallId = nil
        lock.unlock()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        configureAudioSession()
        lock.lock()
        let number = numberByUuid[action.callUUID] ?? action.handle.value
        let simSlot = simSlotByUuid[action.callUUID] ?? 0
        let cid = callIdByUuid[action.callUUID] ?? action.callUUID.uuidString
        activeAudioCallId = cid
        lock.unlock()

        Task { @MainActor in
            BridgeClient.shared.sendCommand(
                BridgeWsMessage(type: "place_call", number: number, simSlot: simSlot)
            )
            BridgeClient.shared.startUdpSession(callId: cid)
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        configureAudioSession()
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
        lock.unlock()
        Task { @MainActor in
            BridgeClient.shared.sendCommand(
                BridgeWsMessage(type: "set_hold", callId: callId, held: action.isOnHold)
            )
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
        lock.lock()
        let cid = activeAudioCallId ?? callIdByUuid.values.first ?? "call-active"
        lock.unlock()

        AudioEngineManager.shared.start(callId: cid) { encoded, seq, ts, callHash in
            BridgeClient.shared.sendOpusFrame(encoded: encoded, seq: seq, ts: ts, callHash: callHash)
        }
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        AudioEngineManager.shared.stop()
        Task { @MainActor in
            BridgeClient.shared.stopUdpSession()
        }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetooth]
            )
            try session.setPreferredSampleRate(48_000)
            try session.setPreferredIOBufferDuration(0.02)
        } catch {
            // AudioSession setup may log warnings under simulator or background state transitions.
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
        if pendingOutgoingUuid == uuid { pendingOutgoingUuid = nil }
        lock.unlock()
    }
}
