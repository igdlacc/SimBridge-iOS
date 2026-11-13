import Foundation
import UIKit
import UserNotifications

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private(set) var currentAlertTokenHex: String = ""

    private override init() {
        super.init()
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
            if !replyText.isEmpty {
                Task { @MainActor in
                    BridgeClient.shared.connectNow()
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    BridgeClient.shared.sendCommand(
                        BridgeWsMessage(
                            type: "send_sms",
                            simSlot: simSlot,
                            clientMsgId: UUID().uuidString,
                            address: address,
                            body: replyText
                        )
                    )
                }
            }
        }
        completionHandler()
    }
}
