import Foundation
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

final class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    private(set) var currentAlertTokenHex: String = ""

    private override init() {
        super.init()
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

        let otpCategory = UNNotificationCategory(
            identifier: "SMS_OTP",
            actions: [copyAction, replyAction],
            intentIdentifiers: [],
            options: []
        )
        let msgCategory = UNNotificationCategory(
            identifier: "SMS_MESSAGE",
            actions: [replyAction],
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
        currentAlertTokenHex = hex
        Task { @MainActor in
            BridgeClient.shared.updatePushTokens(alertToken: hex)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if response.actionIdentifier == "COPY_OTP",
           let otp = info["otpCode"] as? String,
           !otp.isEmpty {
            UIPasteboard.general.string = otp
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
