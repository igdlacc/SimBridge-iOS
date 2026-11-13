import Foundation

struct PairingQrPayload: Codable {
    let v: Int
    let bridgeId: String
    let deviceName: String
    let ips: [String]
    let wsPort: Int
    let udpPort: Int
    let keyB64: String
}

struct SimSlotDto: Codable, Identifiable, Hashable {
    let simSlot: Int
    let subscriptionId: Int
    let carrierName: String
    let phoneNumber: String?

    var id: Int { simSlot }
}

struct CallStateDto: Codable, Identifiable, Hashable {
    let callId: String
    let number: String
    let contactName: String?
    let direction: String
    let state: String
    let simSlot: Int
    let startedAtMs: Int64
    let connectedAtMs: Int64
    let disconnectReason: String?
    let muted: Bool
    let onHold: Bool
    let audioActive: Bool
    let callHash: Int32

    var id: String { callId }
}

struct RecentCallDto: Codable, Identifiable, Hashable {
    let id: String
    let number: String
    let contactName: String?
    let type: String
    let timestampMs: Int64
    let durationSec: Int64
    let simSlot: Int
}

struct SmsMessageDto: Codable, Identifiable, Hashable {
    let id: String
    let threadId: Int64
    let address: String
    let contactName: String?
    let body: String
    let timestampMs: Int64
    let isOutgoing: Bool
    let isRead: Bool
    let simSlot: Int
    let otpCode: String?
}

struct DeviceStatusDto: Codable {
    let deviceName: String
    let batteryPct: Int
    let isCharging: Bool
    let sims: [SimSlotDto]
    let localIps: [String]
    let wsPort: Int
    let udpPort: Int
    let audioProfile: String
    let inCallServiceBound: Bool
    let isPrivileged: Bool
    let downRms: Double
    let upRms: Double
    let udpRxPackets: Int64
    let udpTxPackets: Int64
    let plcFrames: Int64
}

struct EncryptedWsEnvelope: Codable {
    let enc: String
}

struct BridgeWsMessage: Codable {
    var type: String
    var voipToken: String? = nil
    var alertToken: String? = nil
    var clientName: String? = nil
    var callId: String? = nil
    var number: String? = nil
    var simSlot: Int? = nil
    var digit: String? = nil
    var muted: Bool? = nil
    var held: Bool? = nil
    var call: CallStateDto? = nil
    var activeCalls: [CallStateDto]? = nil
    var recentCalls: [RecentCallDto]? = nil
    var clientMsgId: String? = nil
    var address: String? = nil
    var body: String? = nil
    var sms: SmsMessageDto? = nil
    var smsList: [SmsMessageDto]? = nil
    var smsStatus: String? = nil
    var error: String? = nil
    var status: DeviceStatusDto? = nil
    var sinceMs: Int64? = nil
    var ts: Int64? = nil
}

struct LanDiscoveryPayload: Codable, Sendable {
    let bridgeId: String
    let deviceName: String
    let ips: [String]
    let wsPort: Int
    let udpPort: Int
}
