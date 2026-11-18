import Foundation
import Intents
import UIKit
import UserNotifications

private final class BgTaskToken: @unchecked Sendable {
    private let lock = NSLock()
    private var id: UIBackgroundTaskIdentifier = .invalid

    func start(name: String) {
        let taskId = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.end()
        }
        lock.lock()
        id = taskId
        lock.unlock()
    }

    func end() {
        lock.lock()
        let current = id
        id = .invalid
        lock.unlock()
        if current != .invalid {
            UIApplication.shared.endBackgroundTask(current)
        }
    }
}

private enum SmsNotifySource {
    case localWs
    case remotePush
}

private struct SeenSmsEntry {
    let smsId: String?
    let contentKey: String
    let source: SmsNotifySource
    let recordedAt: Date
}

final class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var currentAlertTokenHex: String = ""
    @Published var lowBatteryAlertEnabled: Bool {
        didSet {
            UserDefaults.standard.set(lowBatteryAlertEnabled, forKey: Self.lowBatteryAlertPrefKey)
        }
    }

    private let dedupLock = NSLock()
    private var seenSmsEntries: [SeenSmsEntry] = []
    private var activeViewingKey: String? = nil
    private var lowBatteryAlertSentInCycle: Bool = false
    private var lastLowBatteryAlertAt: Date = .distantPast
    private static let dedupTtlSeconds: TimeInterval = 120.0
    private static let lowBatteryAlertPrefKey = "simbridge.lowBatteryAlertEnabled"

    private override init() {
        if UserDefaults.standard.object(forKey: Self.lowBatteryAlertPrefKey) == nil {
            self.lowBatteryAlertEnabled = true
            UserDefaults.standard.set(true, forKey: Self.lowBatteryAlertPrefKey)
        } else {
            self.lowBatteryAlertEnabled = UserDefaults.standard.bool(forKey: Self.lowBatteryAlertPrefKey)
        }
        super.init()
    }

    func setActivelyViewingConversationKey(_ normalizedKey: String?) {
        dedupLock.lock()
        activeViewingKey = normalizedKey
        dedupLock.unlock()
    }

    private func recordOrCheckDuplicateLocked(
        smsId: String?,
        normAddress: String,
        trimmedBody: String,
        source: SmsNotifySource
    ) -> Bool {
        let now = Date()
        seenSmsEntries.removeAll { now.timeIntervalSince($0.recordedAt) > Self.dedupTtlSeconds }

        let cleanId = (smsId?.isEmpty == false) ? smsId : nil
        let contentKey = normAddress.isEmpty ? "" : "\(normAddress)|\(trimmedBody)"

        let alreadySeen = seenSmsEntries.contains { entry in
            if let cleanId, let existingId = entry.smsId, existingId == cleanId {
                return true
            }
            if !contentKey.isEmpty, entry.contentKey == contentKey {
                return true
            }
            return false
        }
        if alreadySeen {
            return true
        }
        seenSmsEntries.append(
            SeenSmsEntry(
                smsId: cleanId,
                contentKey: contentKey,
                source: source,
                recordedAt: now
            )
        )
        if seenSmsEntries.count > 80 {
            seenSmsEntries.removeFirst(seenSmsEntries.count - 80)
        }
        return false
    }

    @MainActor
    func handleIncomingLocalSms(_ sms: SmsMessageDto) {
        guard !sms.isOutgoing else { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        // Never fire local banners for historical messages older than 90 seconds.
        guard (nowMs - sms.timestampMs) <= 90_000 else { return }

        let normKey = ContactsHelper.normalizeAddressKey(sms.address)
        let trimmedBody = sms.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else { return }
        let cleanId = sms.id.isEmpty ? nil : sms.id
        let isForegroundActive = (UIApplication.shared.applicationState == .active)

        dedupLock.lock()
        let isDuplicate = recordOrCheckDuplicateLocked(
            smsId: cleanId,
            normAddress: normKey,
            trimmedBody: trimmedBody,
            source: .localWs
        )
        let isViewingThisChat = isForegroundActive && !normKey.isEmpty && (activeViewingKey == normKey)
        dedupLock.unlock()

        if isDuplicate || isViewingThisChat {
            return
        }

        let resolvedSender = ContactsHelper.shared.resolveName(for: sms.address)
            ?? (sms.contactName?.isEmpty == false ? sms.contactName! : sms.address)
        let avatarData = ContactsHelper.shared.thumbnailData(for: sms.address)
        let contactId = ContactsHelper.shared.contactIdentifier(for: sms.address)
        let otp = (sms.otpCode?.isEmpty == false) ? sms.otpCode : nil
        let address = sms.address
        let body = sms.body
        let simSlot = sms.simSlot

        Task {
            let center = UNUserNotificationCenter.current()
            let delivered = await center.deliveredNotifications()
            let alreadyInCenter = delivered.contains { notif in
                let info = notif.request.content.userInfo
                if let cleanId, let existingId = info["smsId"] as? String, existingId == cleanId {
                    return true
                }
                let existingAddr = (info["address"] as? String) ?? ""
                let existingBody = ((info["body"] as? String) ?? notif.request.content.body)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return !normKey.isEmpty
                    && ContactsHelper.normalizeAddressKey(existingAddr) == normKey
                    && existingBody == trimmedBody
            }
            guard !alreadyInCenter else { return }

            let content = UNMutableNotificationContent()
            content.title = resolvedSender
            if let otp {
                content.subtitle = "OTP Kodu: \(otp)"
                content.categoryIdentifier = "SMS_OTP"
            } else {
                content.subtitle = "SIM \(simSlot + 1)"
                content.categoryIdentifier = "SMS_MESSAGE"
            }
            content.body = body
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            if !normKey.isEmpty {
                content.threadIdentifier = normKey
            }

            var userInfo: [String: Any] = [
                "address": address,
                "body": body,
                "simSlot": simSlot
            ]
            if let cleanId {
                userInfo["smsId"] = cleanId
            }
            if let otp {
                userInfo["otpCode"] = otp
            }
            content.userInfo = userInfo

            let convId = normKey.isEmpty ? address : normKey
            let senderHandle = INPersonHandle(
                value: convId,
                type: (!convId.isEmpty && convId.allSatisfy(\.isNumber)) ? .phoneNumber : .unknown
            )
            let senderAvatar = avatarData.map { INImage(imageData: $0) }
            let senderPerson = INPerson(
                personHandle: senderHandle,
                nameComponents: nil,
                displayName: resolvedSender,
                image: senderAvatar,
                contactIdentifier: contactId,
                customIdentifier: convId
            )
            let sendIntent = INSendMessageIntent(
                recipients: nil,
                outgoingMessageType: .outgoingMessageText,
                content: body,
                speakableGroupName: nil,
                conversationIdentifier: convId,
                serviceName: "SimBridge",
                sender: senderPerson,
                attachments: nil
            )
            let interaction = INInteraction(intent: sendIntent, response: nil)
            interaction.direction = .incoming
            interaction.donate(completion: nil)

            let finalContent: UNNotificationContent
            do {
                finalContent = try content.updating(from: sendIntent)
            } catch {
                finalContent = content
            }

            let reqId = "simbridge-local-sms-\(cleanId ?? UUID().uuidString)"
            let req = UNNotificationRequest(identifier: reqId, content: finalContent, trigger: nil)
            try? await center.add(req)
        }
    }

    func clearDeliveredNotifications(forAddress address: String) {
        let targetKey = ContactsHelper.normalizeAddressKey(address)
        guard !targetKey.isEmpty else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            let delivered = await center.deliveredNotifications()
            let matchingIds = delivered.compactMap { notif -> String? in
                let addr = (notif.request.content.userInfo["address"] as? String) ?? ""
                return ContactsHelper.normalizeAddressKey(addr) == targetKey ? notif.request.identifier : nil
            }
            if !matchingIds.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: matchingIds)
            }
        }
    }

    func clearAllDeliveredSmsNotifications() {
        Task {
            let center = UNUserNotificationCenter.current()
            let delivered = await center.deliveredNotifications()
            let smsIds = delivered.compactMap { notif -> String? in
                let info = notif.request.content.userInfo
                if info["address"] != nil || info["smsId"] != nil {
                    return notif.request.identifier
                }
                return nil
            }
            if !smsIds.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: smsIds)
            }
        }
    }

    func handleGatewayBatteryStatus(deviceName: String, batteryPct: Int, isCharging: Bool) {
        guard batteryPct > 0 else { return }
        let now = Date()
        var shouldNotify = false
        dedupLock.lock()
        if isCharging || batteryPct >= 25 {
            lowBatteryAlertSentInCycle = false
        } else if batteryPct <= 15
                    && !lowBatteryAlertSentInCycle
                    && now.timeIntervalSince(lastLowBatteryAlertAt) >= 1800 {
            let enabled = UserDefaults.standard.object(forKey: Self.lowBatteryAlertPrefKey) == nil
                ? true
                : UserDefaults.standard.bool(forKey: Self.lowBatteryAlertPrefKey)
            if enabled {
                lowBatteryAlertSentInCycle = true
                lastLowBatteryAlertAt = now
                shouldNotify = true
            }
        }
        dedupLock.unlock()

        guard shouldNotify else { return }
        Task {
            let content = UNMutableNotificationContent()
            content.title = "Redmi Pili Düşük (%\(batteryPct))"
            let label = deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Android Gateway" : deviceName
            content.body = "\(label) pil seviyesi kritik. Köprünün kesilmemesi için şarja takın."
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            let req = UNNotificationRequest(
                identifier: "simbridge-gateway-low-battery",
                content: content,
                trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(req)
        }
    }

    func refreshAuthorizationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            DispatchQueue.main.async {
                self.authorizationStatus = status
            }
        }
    }

    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // options: [] ensures tapping "Kodu Kopyala" executes silently in background without foregrounding!
        let copyAction = UNNotificationAction(
            identifier: "COPY_OTP",
            title: "Kodu Kopyala",
            options: []
        )
        let replyAction = UNTextInputNotificationAction(
            identifier: "QUICK_REPLY",
            title: "Yanıtla",
            options: [],
            textInputButtonTitle: "Gönder",
            textInputPlaceholder: "SMS mesajı..."
        )
        let markReadAction = UNNotificationAction(
            identifier: "MARK_READ",
            title: "Okundu İşaretle",
            options: []
        )

        let otpCategory = UNNotificationCategory(
            identifier: "SMS_OTP",
            actions: [copyAction, replyAction, markReadAction],
            intentIdentifiers: [],
            options: []
        )
        let msgCategory = UNNotificationCategory(
            identifier: "SMS_MESSAGE",
            actions: [replyAction, markReadAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([otpCategory, msgCategory])

        center.requestAuthorization(options: [.alert, .sound, .badge, .timeSensitive]) { granted, _ in
            self.refreshAuthorizationStatus()
            if granted {
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        }
    }

    func didRegisterRemoteToken(_ deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        if Thread.isMainThread {
            currentAlertTokenHex = hex
        } else {
            DispatchQueue.main.async {
                self.currentAlertTokenHex = hex
            }
        }
        Task { @MainActor in
            BridgeClient.shared.updatePushTokens(alertToken: hex)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if notification.request.trigger is UNPushNotificationTrigger {
            let info = notification.request.content.userInfo
            let smsId = info["smsId"] as? String
            let address = (info["address"] as? String) ?? ""
            let body = ((info["body"] as? String) ?? notification.request.content.body)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let normKey = ContactsHelper.normalizeAddressKey(address)
            let isAppActive = Thread.isMainThread ? (UIApplication.shared.applicationState == .active) : true

            dedupLock.lock()
            let isDuplicate = recordOrCheckDuplicateLocked(
                smsId: smsId,
                normAddress: normKey,
                trimmedBody: body,
                source: .remotePush
            )
            let isViewingThisChat = isAppActive && !normKey.isEmpty && (activeViewingKey == normKey)
            dedupLock.unlock()

            if isDuplicate || isViewingThisChat {
                completionHandler([])
                return
            }
        }
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let smsId = info["smsId"] as? String
        let rawAddr = (info["address"] as? String) ?? ""
        let rawBody = ((info["body"] as? String) ?? response.notification.request.content.body)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawAddr.isEmpty || smsId != nil {
            let normKey = ContactsHelper.normalizeAddressKey(rawAddr)
            dedupLock.lock()
            _ = recordOrCheckDuplicateLocked(
                smsId: smsId,
                normAddress: normKey,
                trimmedBody: rawBody,
                source: .remotePush
            )
            dedupLock.unlock()
        }
        if response.actionIdentifier == "COPY_OTP",
           let otp = info["otpCode"] as? String,
           !otp.isEmpty {
            UIPasteboard.general.string = otp
        } else if response.actionIdentifier == "MARK_READ",
                  let address = info["address"] as? String,
                  !address.isEmpty {
            let bgToken = BgTaskToken()
            bgToken.start(name: "SimBridgeMarkSmsRead")
            Task { @MainActor in
                await BridgeClient.shared.markConversationReadAsync(address: address, forceRemoteSync: true)
                completionHandler()
                bgToken.end()
            }
            return
        } else if response.actionIdentifier == "QUICK_REPLY",
                  let textResp = response as? UNTextInputNotificationResponse,
                  let address = info["address"] as? String {
            let replyText = textResp.userText.trimmingCharacters(in: .whitespacesAndNewlines)
            let simSlot = (info["simSlot"] as? Int) ?? 0
            guard !replyText.isEmpty else {
                completionHandler()
                return
            }
            let bgToken = BgTaskToken()
            bgToken.start(name: "SimBridgeQuickReply")
            Task { @MainActor in
                _ = await BridgeClient.shared.sendSmsAsync(address: address, body: replyText, simSlot: simSlot)
                completionHandler()
                bgToken.end()
            }
            return
        } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
                  let address = info["address"] as? String,
                  !address.isEmpty {
            Task { @MainActor in
                AppRouter.shared.openSmsConversation(address: address)
            }
        }
        completionHandler()
    }
}
