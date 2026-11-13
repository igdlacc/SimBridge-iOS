import Intents
import SwiftUI

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        _ = CallKitManager.shared
        VoipPushManager.shared.start()
        NotificationManager.shared.configure()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        NotificationManager.shared.didRegisterRemoteToken(deviceToken)
    }

    func application(
        _ application: UIApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
    ) -> Bool {
        if let intent = userActivity.interaction?.intent as? INStartCallIntent,
           let number = intent.contacts?.first?.personHandle?.value,
           !number.isEmpty {
            Task { @MainActor in
                BridgeClient.shared.connectNow()
                let name = ContactsHelper.shared.resolveName(for: number)
                CallKitManager.shared.startOutgoingCall(number: number, contactName: name)
            }
            return true
        }
        return false
    }
}

@main
struct SimBridgeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            MainTabView()
        }
    }
}

struct MainTabView: View {
    @ObservedObject private var bridge = BridgeClient.shared

    var body: some View {
        TabView {
            DialerView()
                .tabItem { Label("Tuşlar", systemImage: "circle.grid.3x3.fill") }

            RecentsView()
                .tabItem { Label("Aramalar", systemImage: "clock.fill") }

            SmsView()
                .tabItem { Label("Mesajlar", systemImage: "message.fill") }

            SettingsView()
                .tabItem {
                    Label(
                        "Ayarlar",
                        systemImage: bridge.isConnected ? "antenna.radiowaves.left.and.right" : "gear"
                    )
                }
        }
    }
}
