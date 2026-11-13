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

    private var cachedVoipToken: String?
    private var cachedAlertToken: String?
    private var isConnecting = false
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

    func connectNow(candidateIps: [String]? = nil, wsPort: Int? = nil, udpPort: Int? = nil, force: Bool = false) {
        guard let stored = PairingStore.shared.load(),
              let key = BridgeCrypto.decodeBase64Url(stored.keyB64) else {
            return
        }
        if let candidateIps {
            PairingStore.shared.updateIps(candidateIps)
        }
        if !force && (isConnected || isConnecting) {
            return
        }

        var ips: [String] = []
        if let last = stored.lastWorkingIp { ips.append(last) }
        for ip in (candidateIps ?? []) where !ips.contains(ip) { ips.append(ip) }
        for ip in stored.candidateIps where !ips.contains(ip) { ips.append(ip) }

        guard !ips.isEmpty else { return }
        let targetWsPort = wsPort ?? stored.wsPort

        reconnectTask?.cancel()
        isConnecting = true
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isConnecting = false }
            await self.raceAndConnect(ips: ips, wsPort: targetWsPort, key: key)
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
            connectNow()
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

    private func connectWithTimeout(
        url: URL,
        helloEnvStr: String,
        timeoutNs: UInt64 = 1_800_000_000
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

    private func raceAndConnect(ips: [String], wsPort: Int, key: Data) async {
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

        for ip in ips {
            if Task.isCancelled { return }
            guard let url = URL(string: "ws://\(ip):\(wsPort)/ws?auth=\(authToken)") else { continue }
            do {
                let (task, firstMsg) = try await connectWithTimeout(url: url, helloEnvStr: envStr)
                if Task.isCancelled {
                    task.cancel(with: .goingAway, reason: nil)
                    return
                }
                self.wsTask = task
                self.isConnected = true
                self.connectedHost = ip
                self.statusBanner = "Bağlı (\(ip))"
                PairingStore.shared.updateIps([ip], lastWorkingIp: ip)
                await self.handleWebSocketMessage(firstMsg, key: key)
                self.listenLoop(task: task, key: key)
                self.startKeepaliveLoop()
                return
            } catch {
                // Continue rapidly to next candidate IP after 1.8s timeout.
            }
        }
        isConnected = false
        statusBanner = "Android bekleniyor (yeniden deneniyor...)"
        scheduleAutoRetry()
    }

    private func scheduleAutoRetry() {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
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
        let browser = NWBrowser(for: .bonjour(type: "_simbridge._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            for r in results {
                let resolver = NWConnection(to: r.endpoint, using: .tcp)
                resolver.stateUpdateHandler = { state in
                    if case .ready = state,
                       let remote = resolver.currentPath?.remoteEndpoint,
                       case .hostPort(let host, _) = remote {
                        let ip = "\(host)".components(separatedBy: "%").first ?? ""
                        if !ip.isEmpty && !ip.contains(":") {
                            Task { @MainActor in
                                PairingStore.shared.updateIps([ip])
                                if self?.isConnected == false && self?.isConnecting == false {
                                    self?.connectNow(candidateIps: [ip])
                                }
                            }
                        }
                    }
                    resolver.cancel()
                }
                resolver.start(queue: DispatchQueue.global(qos: .utility))
            }
        }
        browser.start(queue: DispatchQueue.global(qos: .utility))
        bonjourBrowser = browser
    }

    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                guard let self, self.isPaired, !self.isConnected, !self.isConnecting else { return }
                self.connectNow()
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        pathMonitor = monitor
    }
}
