import Foundation
import Network
import UIKit

/// Off-MainActor real-time UDP audio transport so CoreAudio/Opus threads never contend on @MainActor.
final class UdpAudioTransport: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.simbridge.udp", qos: .userInteractive)
    private let lock = NSLock()
    private var connection: NWConnection?
    private var keepaliveTimer: DispatchSourceTimer?
    private var activeHost: String?
    private var activePort: Int = 0
    private var activeCallHash: Int32 = 0
    private var isConnectionFailed = false
    private var key: Data?
    private let salt: UInt32 = UInt32.random(in: 1...UInt32.max)
    private var nonceCounter: UInt64 = 1

    func start(host: String, port: Int, callId: String, key: Data) {
        queue.async { [weak self] in
            guard let self, let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return }
            let hash = BridgeCrypto.fnv1a32(callId)
            self.lock.lock()
            let sameTarget = (
                self.connection != nil &&
                !self.isConnectionFailed &&
                self.activeHost == host &&
                self.activePort == port &&
                self.key == key
            )
            if sameTarget {
                self.activeCallHash = hash
                self.lock.unlock()
                self.sendPacket(
                    type: UdpAudioPacket.typeKeepalive,
                    seq: 0,
                    timestampSamples: 0,
                    callHash: hash,
                    payload: Data()
                )
                return
            }

            self.connection?.cancel()
            self.keepaliveTimer?.cancel()
            self.keepaliveTimer = nil
            self.activeHost = host
            self.activePort = port
            self.activeCallHash = hash
            self.isConnectionFailed = false
            self.key = key

            let params = NWParameters.udp
            params.serviceClass = .interactiveVoice
            let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
            self.connection = conn
            self.lock.unlock()

            conn.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.lock.lock()
                    let curHash = self.activeCallHash
                    self.lock.unlock()
                    self.sendPacket(
                        type: UdpAudioPacket.typeKeepalive,
                        seq: 0,
                        timestampSamples: 0,
                        callHash: curHash,
                        payload: Data()
                    )
                case .failed, .cancelled:
                    self.lock.lock()
                    if self.connection === conn {
                        self.isConnectionFailed = true
                    }
                    self.lock.unlock()
                default:
                    break
                }
            }
            conn.start(queue: self.queue)
            self.receiveLoop(conn: conn, key: key, consecutiveErrors: 0)

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + .milliseconds(1500), repeating: .milliseconds(1500))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let hasConn = (self.connection != nil && !self.isConnectionFailed)
                let curHash = self.activeCallHash
                self.lock.unlock()
                guard hasConn else { return }
                self.sendPacket(
                    type: UdpAudioPacket.typeKeepalive,
                    seq: 0,
                    timestampSamples: 0,
                    callHash: curHash,
                    payload: Data()
                )
            }
            self.keepaliveTimer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let conn = self.connection
            let timer = self.keepaliveTimer
            self.connection = nil
            self.keepaliveTimer = nil
            self.activeHost = nil
            self.activePort = 0
            self.isConnectionFailed = false
            self.lock.unlock()
            timer?.cancel()
            conn?.cancel()
        }
    }

    func sendPacket(
        type: UInt8,
        seq: UInt16,
        timestampSamples: UInt32,
        callHash: Int32,
        payload: Data
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let conn = self.connection
            let activeKey = self.key
            self.nonceCounter &+= 1
            let ctr = self.nonceCounter
            self.lock.unlock()

            guard let conn, let activeKey,
                  let wire = UdpAudioPacket.encode(
                    type: type,
                    seq: seq,
                    timestampSamples: timestampSamples,
                    callHash: callHash,
                    payload: payload,
                    key: activeKey,
                    salt: self.salt,
                    nonceCounter: ctr
                  ) else { return }

            conn.send(content: wire, completion: .contentProcessed { _ in })
        }
    }

    private func receiveLoop(conn: NWConnection, key: Data, consecutiveErrors: Int) {
        conn.receiveMessage { [weak self] content, _, _, error in
            guard let self else { return }
            self.lock.lock()
            let stillCurrent = (self.connection === conn && !self.isConnectionFailed)
            self.lock.unlock()
            guard stillCurrent else { return }
            switch conn.state {
            case .cancelled, .failed:
                return
            default:
                break
            }

            if let error {
                _ = error
                let nextErrs = consecutiveErrors + 1
                guard nextErrs < 10 else {
                    self.lock.lock()
                    if self.connection === conn {
                        self.isConnectionFailed = true
                    }
                    self.lock.unlock()
                    return
                }
                self.queue.asyncAfter(deadline: .now() + .milliseconds(80)) { [weak self] in
                    self?.receiveLoop(conn: conn, key: key, consecutiveErrors: nextErrs)
                }
                return
            }

            if let data = content,
               let decoded = UdpAudioPacket.decode(data: data, key: key),
               decoded.type == UdpAudioPacket.typeAudio {
                AudioEngineManager.shared.onIncomingAudioPacket(seq: decoded.seq, payload: decoded.payload)
            }
            if conn.state != .cancelled && conn.state != .failed {
                self.receiveLoop(conn: conn, key: key, consecutiveErrors: 0)
            }
        }
    }
}

private struct BridgeHealthResponse: Decodable, Sendable {
    let ok: Bool
    let wsPort: Int?
    let udpPort: Int?
}

enum PendingSmsStatus: Equatable {
    case sending
    case sent
    case delivered
    case failed(String)

    var label: String {
        switch self {
        case .sending: return "Gönderiliyor..."
        case .sent: return "Gönderildi ✓"
        case .delivered: return "İletildi ✓✓"
        case .failed: return "Gönderilemedi ✕"
        }
    }
}

struct PendingSmsMessage: Identifiable, Equatable {
    let id: String
    let address: String
    let body: String
    let simSlot: Int
    let timestampMs: Int64
    var status: PendingSmsStatus
}

private struct CachedBridgeSnapshot: Codable {
    let recentCalls: [RecentCallDto]
    let smsMessages: [SmsMessageDto]
    let sims: [SimSlotDto]?
    let deviceName: String?
    let savedAtMs: Int64
}

@MainActor
final class BridgeClient: ObservableObject {
    static let shared = BridgeClient()

    @Published private(set) var isPaired: Bool = false
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var connectedHost: String?
    @Published private(set) var pairingDeviceName: String = ""
    @Published private(set) var activeCalls: [CallStateDto] = []
    @Published private(set) var recentCalls: [RecentCallDto] = []
    @Published private(set) var smsMessages: [SmsMessageDto] = []
    @Published private(set) var pendingSms: [PendingSmsMessage] = []
    @Published private(set) var deviceStatus: DeviceStatusDto?
    @Published private(set) var cachedSims: [SimSlotDto] = []
    @Published private(set) var statusBanner: String = "Eşleştirme bekleniyor"
    @Published private(set) var lastCallError: String?
    @Published private(set) var pingLatencyMs: Int?
    @Published private(set) var lastSyncAt: Date?

    private let urlSession: URLSession
    private var wsTask: URLSessionWebSocketTask?
    private nonisolated static let audioTransport = UdpAudioTransport()
    private nonisolated var udpTransport: UdpAudioTransport { Self.audioTransport }
    private var bonjourBrowser: NWBrowser?
    private var pathMonitor: NWPathMonitor?
    private var foregroundObserver: NSObjectProtocol?
    private let discoveryQueue = DispatchQueue(label: "com.simbridge.discovery", qos: .utility)

    private var cachedVoipToken: String?
    private var cachedAlertToken: String?
    private var isConnecting = false
    private var lastLanSignature: String = LanDiscovery.currentLanSignature()
    private var retryAttemptCount = 0
    private var lastAttemptedIps: Set<String> = []
    private var reconnectTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var keepaliveTimer: Task<Void, Never>?
    private var errorClearTask: Task<Void, Never>?
    private var cacheSaveTask: Task<Void, Never>?

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = false
        // Keepalive runs every 10s, so use a generous idle timeout to avoid spurious WS drops.
        cfg.timeoutIntervalForRequest = 45
        urlSession = URLSession(configuration: cfg)

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleAppBecameActive()
            }
        }
        startNetworkMonitor()

        if let stored = PairingStore.shared.load() {
            isPaired = true
            pairingDeviceName = stored.deviceName
            statusBanner = "Android bekleniyor..."
            loadEncryptedCacheIfAvailable(stored: stored)
            startDiscovery()
            connectNow(candidateIps: stored.candidateIps, wsPort: stored.wsPort, udpPort: stored.udpPort)
        }
    }

    func applyQrPayload(_ rawJson: String) -> Bool {
        guard let data = rawJson.data(using: .utf8),
              let qr = try? JSONDecoder().decode(PairingQrPayload.self, from: data),
              BridgeCrypto.decodeBase64Url(qr.keyB64)?.count == 32 else {
            return false
        }

        let stored = StoredPairingConfig(
            bridgeId: qr.bridgeId,
            deviceName: qr.deviceName,
            candidateIps: qr.ips,
            lastWorkingIp: qr.ips.first,
            wsPort: qr.wsPort,
            udpPort: qr.udpPort,
            keyB64: qr.keyB64
        )
        PairingStore.shared.save(stored)
        isPaired = true
        pairingDeviceName = qr.deviceName
        statusBanner = "Bağlanılıyor: \(qr.ips.first ?? "")"
        startDiscovery()
        connectNow(candidateIps: qr.ips, wsPort: qr.wsPort, udpPort: qr.udpPort)
        return true
    }

    func unpair() {
        disconnect()
        bonjourBrowser?.cancel()
        bonjourBrowser = nil
        retryAttemptCount = 0
        lastAttemptedIps = []
        PairingStore.shared.clear()
        clearEncryptedCache()
        isPaired = false
        isConnected = false
        connectedHost = nil
        activeCalls = []
        recentCalls = []
        smsMessages = []
        pendingSms = []
        cachedSims = []
        deviceStatus = nil
        pingLatencyMs = nil
        lastSyncAt = nil
        statusBanner = "Eşleştirme kaldırıldı"
    }

    var availableSims: [SimSlotDto] {
        deviceStatus?.sims ?? cachedSims
    }

    func validatedSimSlot(_ preferred: Int) -> Int {
        let sims = availableSims
        guard !sims.isEmpty else { return max(0, preferred) }
        if sims.contains(where: { $0.simSlot == preferred }) {
            return preferred
        }
        return sims.first?.simSlot ?? 0
    }

    func handleLocalCallEnded(callId: String?) {
        if let callId {
            activeCalls.removeAll { $0.callId == callId }
        } else {
            activeCalls.removeAll()
        }
    }

    func updateLocalCallMuteState(callId: String?, muted: Bool) {
        if let callId, let idx = activeCalls.firstIndex(where: { $0.callId == callId }) {
            activeCalls[idx].muted = muted
        } else if !activeCalls.isEmpty {
            activeCalls[0].muted = muted
        }
    }

    func updateLocalCallHoldState(callId: String?, held: Bool) {
        if let callId, let idx = activeCalls.firstIndex(where: { $0.callId == callId }) {
            activeCalls[idx].onHold = held
            activeCalls[idx].state = held ? "holding" : "active"
        } else if !activeCalls.isEmpty {
            activeCalls[0].onHold = held
            activeCalls[0].state = held ? "holding" : "active"
        }
    }

    func sendSms(address: String, body: String, simSlot: Int) {
        let trimmedAddr = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddr.isEmpty, !trimmedBody.isEmpty else { return }

        let clientMsgId = UUID().uuidString
        let targetSim = validatedSimSlot(simSlot)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        let optimistic = PendingSmsMessage(
            id: clientMsgId,
            address: trimmedAddr,
            body: trimmedBody,
            simSlot: targetSim,
            timestampMs: nowMs,
            status: .sending
        )
        pendingSms.append(optimistic)

        let msg = BridgeWsMessage(
            type: "send_sms",
            simSlot: targetSim,
            clientMsgId: clientMsgId,
            address: trimmedAddr,
            body: trimmedBody
        )
        guard let task = wsTask, isConnected, let envStr = encodeWsEnvelope(msg) else {
            if let idx = pendingSms.firstIndex(where: { $0.id == clientMsgId }) {
                pendingSms[idx].status = .failed("Android bağlantısı yok")
            }
            reportUiError("SMS gönderilemedi: Android bağlantısı yok")
            return
        }

        task.send(.string(envStr)) { [weak self] err in
            guard let err else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      let idx = self.pendingSms.firstIndex(where: { $0.id == clientMsgId }) else { return }
                self.pendingSms[idx].status = .failed(err.localizedDescription)
                self.reportUiError("SMS gönderilemedi")
            }
        }
    }

    func retryPendingSms(id: String) {
        guard let item = pendingSms.first(where: { $0.id == id }) else { return }
        pendingSms.removeAll { $0.id == id }
        sendSms(address: item.address, body: item.body, simSlot: item.simSlot)
    }

    func dismissPendingSms(id: String) {
        pendingSms.removeAll { $0.id == id }
    }

    func updatePushTokens(voipToken: String? = nil, alertToken: String? = nil) {
        if let voipToken, !voipToken.isEmpty { cachedVoipToken = voipToken }
        if let alertToken, !alertToken.isEmpty { cachedAlertToken = alertToken }
        if isConnected {
            sendHello()
        }
    }

    func connectNow(
        candidateIps: [String]? = nil,
        wsPort: Int? = nil,
        udpPort: Int? = nil,
        force: Bool = false,
        sweepSubnet: Bool = false
    ) {
        if candidateIps != nil || wsPort != nil || udpPort != nil {
            PairingStore.shared.updateIps(candidateIps ?? [], wsPort: wsPort, udpPort: udpPort)
        }
        guard let stored = PairingStore.shared.load(),
              let key = BridgeCrypto.decodeBase64Url(stored.keyB64) else {
            return
        }

        let freshIps = (candidateIps ?? []).filter { !$0.isEmpty }
        let hostMismatch = isConnected && !freshIps.isEmpty && !freshIps.contains(connectedHost ?? "")
        let hasUnseenCandidate = freshIps.contains { !lastAttemptedIps.contains($0) }
        if !force && !hostMismatch && (isConnected || (isConnecting && !hasUnseenCandidate)) {
            return
        }

        var ips: [String] = []
        for ip in (candidateIps ?? []) where !ip.isEmpty && !ips.contains(ip) { ips.append(ip) }
        if let last = stored.lastWorkingIp, !last.isEmpty, !ips.contains(last) { ips.append(last) }
        for ip in stored.candidateIps where !ip.isEmpty && !ips.contains(ip) { ips.append(ip) }

        let targetWsPort = (wsPort ?? 0) > 0 ? (wsPort ?? stored.wsPort) : stored.wsPort
        let targetUdpPort = (udpPort ?? 0) > 0 ? (udpPort ?? stored.udpPort) : stored.udpPort
        let shouldSweep = sweepSubnet || retryAttemptCount >= 1
        lastAttemptedIps = Set(ips)

        reconnectTask?.cancel()
        isConnecting = true
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isConnecting = false }
            await self.raceAndConnect(
                ips: ips,
                wsPort: targetWsPort,
                udpPort: targetUdpPort,
                bridgeId: stored.bridgeId,
                key: key,
                sweepSubnet: shouldSweep
            )
        }
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        retryTask?.cancel()
        retryTask = nil
        isConnecting = false
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
        udpTransport.stop()
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
        pingLatencyMs = nil
        isConnected = false
    }

    func reportUiError(_ message: String) {
        errorClearTask?.cancel()
        lastCallError = message
        errorClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.lastCallError = nil
        }
    }

    func handleAppBecameActive() {
        guard isPaired else { return }
        if !isConnected {
            retryAttemptCount = 0
            startDiscovery()
            connectNow(force: true, sweepSubnet: true)
            return
        }
        guard let task = wsTask else {
            isConnected = false
            connectNow(force: true)
            return
        }
        // Probe sockets that iOS silently tore down while suspended in background.
        task.sendPing { [weak self] err in
            Task { @MainActor in
                guard let self else { return }
                if err != nil {
                    if self.wsTask === task {
                        task.cancel(with: .goingAway, reason: nil)
                        self.wsTask = nil
                        self.isConnected = false
                    }
                    self.connectNow(force: true)
                } else {
                    self.sendCommand(BridgeWsMessage(type: "sync_request"))
                }
            }
        }
    }

    func startUdpSession(callId: String) {
        guard let host = connectedHost ?? PairingStore.shared.load()?.lastWorkingIp,
              let stored = PairingStore.shared.load(),
              let key = BridgeCrypto.decodeBase64Url(stored.keyB64) else {
            return
        }
        udpTransport.start(host: host, port: stored.udpPort, callId: callId, key: key)
    }

    nonisolated func stopUdpSession() {
        udpTransport.stop()
    }

    nonisolated static func sendOpusFrame(encoded: Data, seq: UInt16, ts: UInt32, callHash: Int32) {
        audioTransport.sendPacket(
            type: UdpAudioPacket.typeAudio,
            seq: seq,
            timestampSamples: ts,
            callHash: callHash,
            payload: encoded
        )
    }

    nonisolated func sendOpusFrame(encoded: Data, seq: UInt16, ts: UInt32, callHash: Int32) {
        Self.sendOpusFrame(encoded: encoded, seq: seq, ts: ts, callHash: callHash)
    }

    private func encodeWsEnvelope(_ message: BridgeWsMessage) -> String? {
        guard let stored = PairingStore.shared.load(),
              let key = BridgeCrypto.decodeBase64Url(stored.keyB64),
              let jsonData = try? JSONEncoder().encode(message),
              let plainStr = String(data: jsonData, encoding: .utf8),
              let encB64 = try? BridgeCrypto.encryptStringGcm(plainStr, key: key),
              let envData = try? JSONEncoder().encode(EncryptedWsEnvelope(enc: encB64)),
              let envStr = String(data: envData, encoding: .utf8) else {
            return nil
        }
        return envStr
    }

    private func sendEnvelope(_ envStr: String, on task: URLSessionWebSocketTask) async -> Bool {
        await withCheckedContinuation { cont in
            task.send(.string(envStr)) { err in
                cont.resume(returning: err == nil)
            }
        }
    }

    func sendCommand(_ message: BridgeWsMessage) {
        guard let task = wsTask, let envStr = encodeWsEnvelope(message) else {
            return
        }
        task.send(.string(envStr)) { _ in }
    }

    /// Sends `place_call` reliably: probes/reconnects automatically if the WebSocket dropped in background.
    func sendPlaceCall(_ message: BridgeWsMessage, completion: @escaping (Bool) -> Void) {
        guard let envStr = encodeWsEnvelope(message) else {
            completion(false)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else {
                completion(false)
                return
            }
            if self.isConnected, let task = self.wsTask {
                if await self.sendEnvelope(envStr, on: task) {
                    completion(true)
                    return
                }
                if self.wsTask === task {
                    task.cancel(with: .goingAway, reason: nil)
                    self.wsTask = nil
                    self.isConnected = false
                }
            }

            if !self.isConnecting {
                self.connectNow()
            }
            for _ in 0..<45 {
                if self.isConnected, let task = self.wsTask {
                    let ok = await self.sendEnvelope(envStr, on: task)
                    completion(ok)
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            completion(false)
        }
    }

    private func sendHello() {
        sendCommand(
            BridgeWsMessage(
                type: "hello",
                voipToken: cachedVoipToken,
                alertToken: cachedAlertToken,
                clientName: UIDevice.current.name
            )
        )
    }

    private struct ConnectOutcome: @unchecked Sendable {
        let ip: String
        let wsPort: Int
        let udpPort: Int?
        let task: URLSessionWebSocketTask
        let firstMsg: URLSessionWebSocketTask.Message
    }

    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if fired { return false }
            fired = true
            return true
        }
    }

    nonisolated private static func extractIpv4(_ host: NWEndpoint.Host) -> String? {
        let raw = "\(host)"
            .components(separatedBy: "%")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty, !raw.contains(":") else { return nil }
        return raw
    }

    nonisolated private func connectWithTimeout(
        url: URL,
        helloEnvStr: String,
        timeoutNs: UInt64 = 2_000_000_000
    ) async throws -> (URLSessionWebSocketTask, URLSessionWebSocketTask.Message) {
        var req = URLRequest(url: url)
        req.timeoutInterval = 2.5
        let task = urlSession.webSocketTask(with: req)
        task.resume()
        do {
            let firstMsg = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
                group.addTask {
                    try await task.send(.string(helloEnvStr))
                    return try await task.receive()
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNs)
                    throw URLError(.timedOut)
                }
                guard let first = try await group.next() else {
                    throw URLError(.unknown)
                }
                group.cancelAll()
                return first
            }
            return (task, firstMsg)
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            throw error
        }
    }

    nonisolated private func probeHealth(
        ip: String,
        wsPort: Int,
        timeoutNs: UInt64 = 1_200_000_000
    ) async -> (String, Int, Int?)? {
        let clean = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains(":"), wsPort > 0,
              let url = URL(string: "http://\(clean):\(wsPort)/health") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.5
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            return try await withThrowingTaskGroup(of: (String, Int, Int?)?.self) { group in
                group.addTask { [self] in
                    let (data, response) = try await self.urlSession.data(for: req)
                    guard let http = response as? HTTPURLResponse,
                          http.statusCode == 200,
                          let health = try? JSONDecoder().decode(BridgeHealthResponse.self, from: data),
                          health.ok else {
                        return nil
                    }
                    return (clean, health.wsPort ?? wsPort, health.udpPort)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNs)
                    throw URLError(.timedOut)
                }
                guard let candidate = try await group.next() else {
                    return nil
                }
                group.cancelAll()
                return candidate
            }
        } catch {
            return nil
        }
    }

    nonisolated private func raceHealthyHost(
        ips: [String],
        wsPort: Int,
        timeoutNs: UInt64
    ) async -> (String, Int, Int?)? {
        var uniqueIps: [String] = []
        for ip in ips {
            let clean = ip.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty && !clean.contains(":") && !uniqueIps.contains(clean) {
                uniqueIps.append(clean)
            }
        }
        guard !uniqueIps.isEmpty else { return nil }

        return await withTaskGroup(of: (String, Int, Int?)?.self) { group in
            for ip in uniqueIps.prefix(8) {
                group.addTask { [self] in
                    guard !Task.isCancelled else { return nil }
                    return await self.probeHealth(ip: ip, wsPort: wsPort, timeoutNs: timeoutNs)
                }
            }
            for await hit in group {
                if let win = hit {
                    group.cancelAll()
                    return win
                }
            }
            return nil
        }
    }

    private func raceAndConnect(
        ips: [String],
        wsPort: Int,
        udpPort: Int,
        bridgeId: String,
        key: Data,
        sweepSubnet: Bool
    ) async {
        retryTask?.cancel()
        retryTask = nil
        let authToken = BridgeCrypto.deriveWsAuthToken(key: key)
        wsTask?.cancel(with: .normalClosure, reason: nil)
        wsTask = nil
        isConnected = false

        let hello = BridgeWsMessage(
            type: "hello",
            voipToken: cachedVoipToken,
            alertToken: cachedAlertToken,
            clientName: UIDevice.current.name
        )
        guard let plainData = try? JSONEncoder().encode(hello),
              let plain = String(data: plainData, encoding: .utf8),
              let encB64 = try? BridgeCrypto.encryptStringGcm(plain, key: key),
              let envData = try? JSONEncoder().encode(EncryptedWsEnvelope(enc: encB64)),
              let envStr = String(data: envData, encoding: .utf8) else {
            return
        }

        // Probe /health and encrypted UDP discovery first so only ONE winning socket ever opens /ws and sends hello.
        let winningEndpoint = await withTaskGroup(of: (String, Int, Int?)?.self) { group -> (String, Int, Int?)? in
            if !ips.isEmpty {
                group.addTask { [self] in
                    await self.raceHealthyHost(
                        ips: ips,
                        wsPort: wsPort,
                        timeoutNs: 1_200_000_000
                    )
                }
            }
            group.addTask { [self] in
                let found = await LanDiscovery.probe(
                    bridgeId: bridgeId,
                    udpPort: udpPort,
                    key: key,
                    includeSubnetSweep: sweepSubnet,
                    hintIps: ips
                )
                guard !Task.isCancelled, !found.ips.isEmpty else { return nil }
                let targetWs = found.wsPort ?? wsPort
                await MainActor.run {
                    PairingStore.shared.updateIps(found.ips, wsPort: found.wsPort, udpPort: found.udpPort)
                }
                return await self.raceHealthyHost(
                    ips: found.ips,
                    wsPort: targetWs,
                    timeoutNs: 1_200_000_000
                )
            }

            var picked: (String, Int, Int?)?
            for await endpoint in group {
                if let win = endpoint {
                    picked = win
                    group.cancelAll()
                    break
                }
            }
            return picked
        }

        if Task.isCancelled {
            return
        }

        var winner: ConnectOutcome?
        if let (targetIp, targetWsPort, targetUdpPort) = winningEndpoint,
           let url = URL(string: "ws://\(targetIp):\(targetWsPort)/ws?auth=\(authToken)") {
            if let (task, firstMsg) = try? await connectWithTimeout(
                url: url,
                helloEnvStr: envStr,
                timeoutNs: 2_000_000_000
            ) {
                if Task.isCancelled {
                    task.cancel(with: .goingAway, reason: nil)
                    return
                }
                winner = ConnectOutcome(ip: targetIp, wsPort: targetWsPort, udpPort: targetUdpPort, task: task, firstMsg: firstMsg)
            }
        }

        if Task.isCancelled {
            winner?.task.cancel(with: .goingAway, reason: nil)
            return
        }

        if let win = winner {
            self.retryAttemptCount = 0
            self.wsTask = win.task
            self.isConnected = true
            self.connectedHost = win.ip
            self.statusBanner = "Bağlı (\(win.ip))"
            PairingStore.shared.updateIps([win.ip], lastWorkingIp: win.ip, wsPort: win.wsPort, udpPort: win.udpPort)
            await self.handleWebSocketMessage(win.firstMsg, key: key)
            if let liveCall = self.activeCalls.first(where: { $0.state == "active" || $0.state == "dialing" }) {
                self.startUdpSession(callId: liveCall.callId)
            }
            self.listenLoop(task: win.task, key: key)
            self.startKeepaliveLoop()
            return
        }

        isConnected = false
        pingLatencyMs = nil
        retryAttemptCount += 1
        statusBanner = "Android bekleniyor (yeniden deneniyor...)"
        scheduleAutoRetry()
    }

    private func scheduleAutoRetry() {
        retryTask?.cancel()
        let delayNs: UInt64 = retryAttemptCount <= 3 ? 1_200_000_000 : 2_500_000_000
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNs)
            guard !Task.isCancelled, let self, self.isPaired, !self.isConnected, !self.isConnecting else {
                return
            }
            self.connectNow()
        }
    }

    private func listenLoop(task: URLSessionWebSocketTask, key: Data) {
        Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.wsTask === task {
                do {
                    let raw = try await task.receive()
                    await self.handleWebSocketMessage(raw, key: key)
                } catch {
                    guard self.wsTask === task else { return }
                    self.wsTask = nil
                    self.isConnected = false
                    self.pingLatencyMs = nil
                    self.statusBanner = "Bağlantı koptu, yeniden deneniyor..."
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    guard !Task.isCancelled, !self.isConnected, !self.isConnecting, self.wsTask == nil else {
                        return
                    }
                    self.connectNow()
                    return
                }
            }
        }
    }

    private func handleWebSocketMessage(_ msg: URLSessionWebSocketTask.Message, key: Data) async {
        guard case .string(let text) = msg,
              let envData = text.data(using: .utf8),
              let env = try? JSONDecoder().decode(EncryptedWsEnvelope.self, from: envData),
              let plain = try? BridgeCrypto.decryptStringGcm(env.enc, key: key),
              let plainData = plain.data(using: .utf8),
              let wsMsg = try? JSONDecoder().decode(BridgeWsMessage.self, from: plainData) else {
            return
        }

        switch wsMsg.type {
        case "snapshot":
            lastSyncAt = Date()
            if let calls = wsMsg.activeCalls {
                activeCalls = calls
                CallKitManager.shared.reconcileActiveCalls(calls)
            }
            if let recents = wsMsg.recentCalls { recentCalls = recents }
            if let sms = wsMsg.smsList {
                smsMessages = sms
                reconcilePendingSms(with: sms)
            }
            if let st = wsMsg.status {
                deviceStatus = st
                cachedSims = st.sims
            }
            scheduleEncryptedCacheSave()
        case "device_status":
            if let st = wsMsg.status {
                deviceStatus = st
                cachedSims = st.sims
            }
        case "call_state":
            if let c = wsMsg.call {
                CallKitManager.shared.handleRemoteCallState(c)
                if c.state == "disconnected" {
                    activeCalls.removeAll { $0.callId == c.callId }
                    sendCommand(BridgeWsMessage(type: "sync_request"))
                } else {
                    if let idx = activeCalls.firstIndex(where: { $0.callId == c.callId }) {
                        activeCalls[idx] = c
                    } else {
                        activeCalls.append(c)
                    }
                    if c.state == "active" || c.state == "dialing" {
                        startUdpSession(callId: c.callId)
                    }
                }
            }
        case "sms_received":
            if let sms = wsMsg.sms {
                if !smsMessages.contains(where: { $0.id == sms.id }) {
                    smsMessages.insert(sms, at: 0)
                    scheduleEncryptedCacheSave()
                }
            }
        case "sms_sent_status":
            let statusStr = wsMsg.smsStatus ?? ""
            if let cid = wsMsg.clientMsgId,
               let idx = pendingSms.firstIndex(where: { $0.id == cid }) {
                switch statusStr {
                case "sent":
                    pendingSms[idx].status = .sent
                case "delivered":
                    pendingSms[idx].status = .delivered
                case "failed":
                    let errMsg = wsMsg.error ?? "Bilinmeyen SMS hatası"
                    pendingSms[idx].status = .failed(errMsg)
                    reportUiError("SMS gönderilemedi: \(errMsg)")
                default:
                    break
                }
            } else if statusStr == "failed" {
                reportUiError("SMS gönderilemedi: \(wsMsg.error ?? "Bilinmeyen hata")")
            }
            if statusStr == "sent" || statusStr == "delivered" {
                sendCommand(BridgeWsMessage(type: "sync_request"))
            }
        default:
            break
        }
    }

    private func startKeepaliveLoop() {
        keepaliveTimer?.cancel()
        keepaliveTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, self.isConnected, let task = self.wsTask else { return }

                let sentAt = Date()
                let alive = await self.probeNativeWsPing(task: task, timeoutNs: 3_500_000_000)
                guard !Task.isCancelled else { return }
                if alive {
                    self.pingLatencyMs = max(1, Int(Date().timeIntervalSince(sentAt) * 1000))
                } else {
                    if self.wsTask === task {
                        task.cancel(with: .goingAway, reason: nil)
                        self.wsTask = nil
                        self.isConnected = false
                        self.pingLatencyMs = nil
                        self.statusBanner = "Bağlantı zaman aşımı, yeniden bağlanılıyor..."
                        self.connectNow(force: true)
                    }
                    return
                }
            }
        }
    }

    private func probeNativeWsPing(task: URLSessionWebSocketTask, timeoutNs: UInt64) async -> Bool {
        let once = OnceFlag()
        return await withCheckedContinuation { cont in
            let timerTask = Task {
                try? await Task.sleep(nanoseconds: timeoutNs)
                if once.claim() {
                    cont.resume(returning: false)
                }
            }
            task.sendPing { err in
                timerTask.cancel()
                if once.claim() {
                    cont.resume(returning: err == nil)
                }
            }
        }
    }

    private func reconcilePendingSms(with serverList: [SmsMessageDto]) {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        pendingSms.removeAll { pending in
            if case .failed = pending.status {
                return false
            }
            let normPending = ContactsHelper.normalizeSuffix(pending.address)
            let trimmedBody = pending.body.trimmingCharacters(in: .whitespacesAndNewlines)
            let matched = serverList.contains { srv in
                guard srv.isOutgoing else { return false }
                let timeDiff = abs(srv.timestampMs - pending.timestampMs)
                guard timeDiff <= 120_000 else { return false }
                let normSrv = ContactsHelper.normalizeSuffix(srv.address)
                let sameAddr = (!normPending.isEmpty && normPending == normSrv) || srv.address == pending.address
                return sameAddr && srv.body.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedBody
            }
            if matched { return true }
            return (nowMs - pending.timestampMs) > 180_000
        }
    }

    nonisolated private static var encryptedCacheUrl: URL? {
        guard let appSup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSup.appendingPathComponent("SimBridge", isDirectory: true)
            .appendingPathComponent("snapshot_cache_v1.enc")
    }

    private func loadEncryptedCacheIfAvailable(stored: StoredPairingConfig) {
        guard let url = Self.encryptedCacheUrl,
              let cipherB64 = try? String(contentsOf: url, encoding: .utf8),
              let key = BridgeCrypto.decodeBase64Url(stored.keyB64),
              let plain = try? BridgeCrypto.decryptStringGcm(cipherB64, key: key),
              let data = plain.data(using: .utf8),
              let snap = try? JSONDecoder().decode(CachedBridgeSnapshot.self, from: data) else {
            return
        }
        recentCalls = snap.recentCalls
        smsMessages = snap.smsMessages
        if let sims = snap.sims { cachedSims = sims }
        if snap.savedAtMs > 0 {
            lastSyncAt = Date(timeIntervalSince1970: Double(snap.savedAtMs) / 1000.0)
        }
    }

    private func scheduleEncryptedCacheSave() {
        cacheSaveTask?.cancel()
        guard let stored = PairingStore.shared.load(),
              let key = BridgeCrypto.decodeBase64Url(stored.keyB64) else {
            return
        }
        let snapshot = CachedBridgeSnapshot(
            recentCalls: Array(recentCalls.prefix(80)),
            smsMessages: Array(smsMessages.prefix(160)),
            sims: deviceStatus?.sims ?? (cachedSims.isEmpty ? nil : cachedSims),
            deviceName: deviceStatus?.deviceName ?? pairingDeviceName,
            savedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
        cacheSaveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled,
                  let url = Self.encryptedCacheUrl,
                  let jsonData = try? JSONEncoder().encode(snapshot),
                  let jsonStr = String(data: jsonData, encoding: .utf8),
                  let enc = try? BridgeCrypto.encryptStringGcm(jsonStr, key: key) else {
                return
            }
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? enc.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func clearEncryptedCache() {
        cacheSaveTask?.cancel()
        cacheSaveTask = nil
        if let url = Self.encryptedCacheUrl {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func startDiscovery() {
        bonjourBrowser?.cancel()
        let pairedBridgeId = PairingStore.shared.load()?.bridgeId
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_simbridge._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            for r in results {
                var txtBridgeId: String?
                if case .bonjour(let txt) = r.metadata,
                   let entry = txt.getEntry(for: "bridgeId") {
                    switch entry {
                    case .string(let s): txtBridgeId = s
                    case .data(let d): txtBridgeId = String(data: d, encoding: .utf8)
                    default: break
                    }
                }
                if let expectedId = pairedBridgeId {
                    if let txtBridgeId, !txtBridgeId.isEmpty, txtBridgeId != expectedId {
                        continue
                    }
                    if txtBridgeId == nil,
                       case .service(let name, _, _, _) = r.endpoint,
                       name.hasPrefix("SimBridge-"),
                       !name.hasPrefix("SimBridge-\(expectedId.prefix(6))") {
                        continue
                    }
                }
                self.resolveBonjourEndpoint(r.endpoint)
            }
        }
        browser.start(queue: discoveryQueue)
        bonjourBrowser = browser
    }

    nonisolated private func resolveBonjourEndpoint(_ endpoint: NWEndpoint) {
        let resolver = NWConnection(to: endpoint, using: .tcp)
        let once = OnceFlag()
        let cleanup: @Sendable () -> Void = {
            guard once.claim() else { return }
            resolver.stateUpdateHandler = nil
            resolver.cancel()
        }
        discoveryQueue.asyncAfter(deadline: .now() + .seconds(3)) {
            cleanup()
        }
        resolver.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let remote = resolver.currentPath?.remoteEndpoint,
                   case .hostPort(let host, let port) = remote,
                   let ip = Self.extractIpv4(host) {
                    let resolvedPort = Int(port.rawValue)
                    Task { @MainActor [weak self] in
                        guard let self, self.isPaired else { return }
                        let portArg = resolvedPort > 0 ? resolvedPort : nil
                        PairingStore.shared.updateIps([ip], wsPort: portArg)
                        if !self.isConnected {
                            self.connectNow(candidateIps: [ip], wsPort: portArg)
                        }
                    }
                }
                cleanup()
            case .failed, .cancelled:
                cleanup()
            default:
                break
            }
        }
        resolver.start(queue: discoveryQueue)
    }

    private func startNetworkMonitor() {
        pathMonitor?.cancel()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let isSatisfied = (path.status == .satisfied)
            Task { @MainActor [weak self] in
                guard let self, self.isPaired else { return }
                let newSig = LanDiscovery.currentLanSignature()
                let lanChanged = (newSig != self.lastLanSignature)
                self.lastLanSignature = newSig

                guard isSatisfied else { return }
                if lanChanged {
                    self.retryAttemptCount = 0
                    self.startDiscovery()
                    if self.isConnected {
                        self.verifyConnectionOrReconnectOnNetworkChange()
                    } else {
                        self.connectNow(force: true)
                    }
                } else if !self.isConnected && !self.isConnecting {
                    self.startDiscovery()
                    self.connectNow()
                }
            }
        }
        monitor.start(queue: discoveryQueue)
        pathMonitor = monitor
    }

    private func verifyConnectionOrReconnectOnNetworkChange() {
        guard let task = wsTask else {
            isConnected = false
            connectNow(force: true)
            return
        }
        let once = OnceFlag()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard once.claim(), let self, self.wsTask === task else { return }
            task.cancel(with: .goingAway, reason: nil)
            self.wsTask = nil
            self.isConnected = false
            self.connectNow(force: true)
        }
        task.sendPing { [weak self] err in
            Task { @MainActor [weak self] in
                guard once.claim(), let self, self.wsTask === task else { return }
                if err != nil {
                    task.cancel(with: .goingAway, reason: nil)
                    self.wsTask = nil
                    self.isConnected = false
                    self.connectNow(force: true)
                }
            }
        }
    }
}
