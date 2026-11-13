import Intents
import SwiftUI

final class AppDelegate: NSObject, UIApplicationDelegate {
    private var lastActivityKey: String?
    private var lastActivityAt: Date = .distantPast

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        _ = CallKitManager.shared
        VoipPushManager.shared.start()
        NotificationManager.shared.configure()

        if let dict = launchOptions?[.userActivityDictionary] as? [AnyHashable: Any],
           let activity = dict["UIApplicationLaunchOptionsUserActivityKey"] as? NSUserActivity {
            _ = handleStartCallUserActivity(activity)
        }
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
        handleStartCallUserActivity(userActivity)
    }

    @discardableResult
    func handleStartCallUserActivity(_ userActivity: NSUserActivity) -> Bool {
        var rawNumber: String?
        var fallbackName: String?

        if let intent = userActivity.interaction?.intent as? INStartCallIntent {
            let contact = intent.contacts?.first
            rawNumber = contact?.personHandle?.value
            fallbackName = contact?.displayName
        } else if let intent = userActivity.interaction?.intent as? INStartAudioCallIntent {
            let contact = intent.contacts?.first
            rawNumber = contact?.personHandle?.value
            fallbackName = contact?.displayName
        }

        let targetQuery = (rawNumber?.isEmpty == false ? rawNumber : fallbackName)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let targetQuery, !targetQuery.isEmpty else { return false }

        let now = Date()
        if lastActivityKey == targetQuery && now.timeIntervalSince(lastActivityAt) < 1.5 {
            return true
        }
        lastActivityKey = targetQuery
        lastActivityAt = now

        Task { @MainActor in
            BridgeClient.shared.handleAppBecameActive()
            if let resolved = ContactsHelper.shared.resolveTarget(for: targetQuery) {
                CallKitManager.shared.startOutgoingCall(
                    number: resolved.number,
                    contactName: resolved.name ?? fallbackName
                )
            } else {
                let name = ContactsHelper.shared.resolveName(for: targetQuery) ?? fallbackName
                CallKitManager.shared.startOutgoingCall(number: targetQuery, contactName: name)
            }
        }
        return true
    }

    func handleIncomingUrl(_ url: URL) {
        guard url.scheme?.lowercased() == "simbridge" else { return }
        var rawTarget: String?
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let qVal = comps.queryItems?.first(where: { $0.name == "number" || $0.name == "tel" || $0.name == "target" })?.value,
           !qVal.isEmpty {
            rawTarget = qVal
        } else {
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !path.isEmpty {
                rawTarget = path
            } else if let host = url.host, host.lowercased() != "call", !host.isEmpty {
                rawTarget = host
            }
        }
        guard let rawTarget, !rawTarget.isEmpty else { return }

        Task { @MainActor in
            BridgeClient.shared.handleAppBecameActive()
            if let resolved = ContactsHelper.shared.resolveTarget(for: rawTarget) {
                CallKitManager.shared.startOutgoingCall(number: resolved.number, contactName: resolved.name)
            } else {
                let name = ContactsHelper.shared.resolveName(for: rawTarget)
                CallKitManager.shared.startOutgoingCall(number: rawTarget, contactName: name)
            }
        }
    }
}

@main
struct SimBridgeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .onContinueUserActivity(NSStringFromClass(INStartCallIntent.self)) { activity in
                    _ = appDelegate.handleStartCallUserActivity(activity)
                }
                .onContinueUserActivity("INStartCallIntent") { activity in
                    _ = appDelegate.handleStartCallUserActivity(activity)
                }
                .onContinueUserActivity("INStartAudioCallIntent") { activity in
                    _ = appDelegate.handleStartCallUserActivity(activity)
                }
                .onOpenURL { url in
                    appDelegate.handleIncomingUrl(url)
                }
                .onChange(of: scenePhase) { newPhase in
                    if newPhase == .active {
                        BridgeClient.shared.handleAppBecameActive()
                    }
                }
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
