import Contacts
import Foundation
import PushKit

final class VoipPushManager: NSObject, PKPushRegistryDelegate {
    static let shared = VoipPushManager()

    private var registry: PKPushRegistry?
    private(set) var currentVoipTokenHex: String = ""

    private override init() {
        super.init()
    }

    func start() {
        let reg = PKPushRegistry(queue: .main)
        reg.delegate = self
        reg.desiredPushTypes = [.voIP]
        registry = reg
    }

    func pushRegistry(
        _ registry: PKPushRegistry,
        didUpdate pushCredentials: PKPushCredentials,
        for type: PKPushType
    ) {
        guard type == .voIP else { return }
        let hex = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        currentVoipTokenHex = hex
        Task { @MainActor in
            BridgeClient.shared.updatePushTokens(voipToken: hex)
        }
    }

    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        guard type == .voIP else {
            completion()
            return
        }

        let dict = payload.dictionaryPayload
        let callId = (dict["callId"] as? String) ?? UUID().uuidString
        let number = (dict["number"] as? String) ?? "Bilinmeyen"
        let androidName = dict["contactName"] as? String
        let simSlot = (dict["simSlot"] as? Int) ?? 0
        let ips = dict["ips"] as? [String]
        let wsPort = dict["wsPort"] as? Int
        let udpPort = dict["udpPort"] as? Int

        let resolvedName: String?
        if let androidName, !androidName.isEmpty {
            resolvedName = androidName
        } else {
            resolvedName = Self.lookupContactSync(phoneNumber: number)
        }

        // CRITICAL iOS rule: reportNewIncomingCall MUST be invoked synchronously before returning.
        CallKitManager.shared.reportIncomingCall(
            callId: callId,
            number: number,
            contactName: resolvedName,
            simSlot: simSlot
        ) { _ in
            completion()
        }

        Task { @MainActor in
            BridgeClient.shared.connectNow(candidateIps: ips, wsPort: wsPort, udpPort: udpPort)
        }
    }

    private static func lookupContactSync(phoneNumber: String) -> String? {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return nil }
        let suffix = String(phoneNumber.filter { $0.isNumber }.suffix(10))
        guard suffix.count >= 7 else { return nil }
        let store = CNContactStore()
        let pred = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: phoneNumber))
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor
        ]
        guard let matches = try? store.unifiedContacts(matching: pred, keysToFetch: keys),
              let first = matches.first else {
            return nil
        }
        let full = [first.givenName, first.familyName].filter { !$0.isEmpty }.joined(separator: " ")
        return full.isEmpty ? nil : full
    }
}
