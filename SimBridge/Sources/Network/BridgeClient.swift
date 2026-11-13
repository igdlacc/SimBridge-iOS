import Foundation
import Network
import UIKit

/// Off-MainActor real-time UDP audio transport so CoreAudio/Opus threads never contend on @MainActor.
final class UdpAudioTransport {
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

            let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)
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
            self.receiveLoop(conn: conn, key: key)

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

    private func receiveLoop(conn: NWConnection, key: Data) {
        conn.receiveMessage { [weak self] content, _, _, error in
            guard let self, error == nil else { return }
            if let data = content,
               let decoded = UdpAudioPacket.decode(data: data, key: key),
               decoded.type == UdpAudioPacket.typeAudio {
                AudioEngineManager.shared.onIncomingAudioPacket(seq: decoded.seq, payload: decoded.payload)
            }
            if conn.state != .cancelled {
                self.receiveLoop(conn: conn, key: key)
            }
        }
    }
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
    @Published private(set) var deviceStatus: DeviceStatusDto?
    @Published private(set) var statusBanner: String = "Eşleştirme bekleniyor"
    @Published private(set) var lastCallError: String?

    private let urlSession: URLSession
    private var wsTask: URLSessionWebSocketTask?
    private let udpTransport = UdpAudioTransport()
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
        isPaired = false
        isConnected = false
        connectedHost = nil
        activeCalls = []
        recentCalls = []
        smsMessages = []
        deviceStatus = nil
        statusBanner = "Eşleştirme kaldırıldı"
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

    nonisolated func sendOpusFrame(encoded: Data, seq: UInt16, ts: UInt32, callHash: Int32) {
        udpTransport.sendPacket(
            type: UdpAudioPacket.typeAudio,
            seq: seq,
            timestampSamples: ts,
            callHash: callHash,
            payload: encoded
        )
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
        timeoutNs: UInt64 = 1_500_000_000
    ) async throws -> (URLSessionWebSocketTask, URLSessionWebSocketTask.Message) {
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
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

    nonisolated private func raceWebSocket(
        ips: [String],
        wsPort: Int,
        authToken: String,
        helloEnvStr: String,
        timeoutNs: UInt64
    ) async -> ConnectOutcome? {
        var uniqueIps: [String] = []
        for ip in ips {
            let clean = ip.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty && !uniqueIps.contains(clean) {
                uniqueIps.append(clean)
            }
        }
        guard !uniqueIps.isEmpty else { return nil }

        return await withTaskGroup(of: ConnectOutcome?.self) { group in
            for ip in uniqueIps.prefix(8) {
                guard let url = URL(string: "ws://\(ip):\(wsPort)/ws?auth=\(authToken)") else { continue }
                group.addTask { [self] in
                    if Task.isCancelled { return nil }
                    do {
                        let (task, firstMsg) = try await self.connectWithTimeout(
                            url: url,
                            helloEnvStr: helloEnvStr,
                            timeoutNs: timeoutNs
                        )
                        if Task.isCancelled {
                            task.cancel(with: .goingAway, reason: nil)
                            return nil
                        }
                        return ConnectOutcome(ip: ip, wsPort: wsPort, task: task, firstMsg: firstMsg)
                    } catch {
                        return nil
                    }
                }
            }

            var winner: ConnectOutcome?
            for await outcome in group {
                if let win = outcome {
                    winner = win
                    group.cancelAll()
                    break
                }
            }
            for await extra in group {
                if let extra, extra.task !== winner?.task {
                    extra.task.cancel(with: .goingAway, reason: nil)
                }
            }
            return winner
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

        let winner = await withTaskGroup(of: ConnectOutcome?.self) { group -> ConnectOutcome? in
            if !ips.isEmpty {
                group.addTask { [self] in
                    await self.raceWebSocket(
                        ips: ips,
                        wsPort: wsPort,
                        authToken: authToken,
                        helloEnvStr: envStr,
                        timeoutNs: 1_300_000_000
                    )
                }
            }
            group.addTask { [self] in
                let found = await LanDiscovery.probe(
                    bridgeId: bridgeId,
                    udpPort: udpPort,
                    key: key,
                    includeSubnetSweep: sweepSubnet
                )
                guard !Task.isCancelled, !found.ips.isEmpty else { return nil }
                let targetWs = found.wsPort ?? wsPort
                await MainActor.run {
                    PairingStore.shared.updateIps(found.ips, wsPort: found.wsPort, udpPort: found.udpPort)
                }
                return await self.raceWebSocket(
                    ips: found.ips,
                    wsPort: targetWs,
                    authToken: authToken,
                    helloEnvStr: envStr,
                    timeoutNs: 1_500_000_000
                )
            }

            var picked: ConnectOutcome?
            for await outcome in group {
                if let win = outcome {
                    picked = win
                    group.cancelAll()
                    break
                }
            }
            for await extra in group {
                if let extra, extra.task !== picked?.task {
                    extra.task.cancel(with: .goingAway, reason: nil)
                }
            }
            return picked
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
            PairingStore.shared.updateIps([win.ip], lastWorkingIp: win.ip, wsPort: win.wsPort)
            await self.handleWebSocketMessage(win.firstMsg, key: key)
            self.listenLoop(task: win.task, key: key)
            self.startKeepaliveLoop()
            return
        }

        isConnected = false
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
            if let calls = wsMsg.activeCalls {
                activeCalls = calls
                CallKitManager.shared.reconcileActiveCalls(calls)
            }
            if let recents = wsMsg.recentCalls { recentCalls = recents }
            if let sms = wsMsg.smsList { smsMessages = sms }
            if let st = wsMsg.status { deviceStatus = st }
        case "device_status":
            if let st = wsMsg.status { deviceStatus = st }
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
                }
            }
        case "sms_received":
            if let sms = wsMsg.sms {
                if !smsMessages.contains(where: { $0.id == sms.id }) {
                    smsMessages.insert(sms, at: 0)
                }
            }
        case "sms_sent_status":
            if wsMsg.smsStatus == "sent" || wsMsg.smsStatus == "delivered" {
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
                guard let self, self.isConnected else { return }
                self.sendCommand(BridgeWsMessage(type: "ping"))
            }
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
                            self.connectNow(candidateIps: [ip], wsPort: portArg, force: self.isConnecting)
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
