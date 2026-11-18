import BackgroundTasks
import Intents
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate {
    private var lastActivityKey: String?
    private var lastActivityAt: Date = .distantPast

    static var permittedRefreshIdentifiers: [String] {
        (Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String])
            ?? ["com.simbridge.ios.refresh"]
    }

    static var activeRefreshTaskIdentifier: String {
        let bundleId = Bundle.main.bundleIdentifier ?? "com.simbridge.ios"
        let candidate = "\(bundleId).refresh"
        let permitted = permittedRefreshIdentifiers
        if permitted.contains(candidate) {
            return candidate
        }
        return permitted.first ?? "com.simbridge.ios.refresh"
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        _ = CallKitManager.shared
        _ = BridgeClient.shared
        VoipPushManager.shared.start()
        NotificationManager.shared.configure()
        LocationKeepAliveManager.shared.startIfAuthorized()

        application.setMinimumBackgroundFetchInterval(UIApplication.backgroundFetchIntervalMinimum)
        for identifier in Set(Self.permittedRefreshIdentifiers) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
                Self.handleAppRefresh(task: task)
            }
        }
        Self.scheduleAppRefresh()

        if let dict = launchOptions?[.userActivityDictionary] as? [AnyHashable: Any],
           let activity = dict["UIApplicationLaunchOptionsUserActivityKey"] as? NSUserActivity {
            _ = handleStartCallUserActivity(activity)
        }
        return true
    }

    static func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: activeRefreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handleAppRefresh(task: BGTask) {
        scheduleAppRefresh()
        let lock = NSLock()
        var finished = false
        let completeTask: @Sendable (Bool) -> Void = { success in
            lock.lock()
            let already = finished
            finished = true
            lock.unlock()
            if !already {
                task.setTaskCompleted(success: success)
            }
        }
        task.expirationHandler = {
            completeTask(false)
        }
        Task { @MainActor in
            BridgeClient.shared.performBackgroundRefresh { success in
                completeTask(success)
            }
        }
    }

    func application(
        _ application: UIApplication,
        performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            BridgeClient.shared.performBackgroundRefresh { ok in
                completionHandler(ok ? .newData : .noData)
            }
        }
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            BridgeClient.shared.performBackgroundRefresh { ok in
                completionHandler(ok ? .newData : .noData)
            }
        }
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

        if rawNumber == nil && fallbackName == nil, let webUrl = userActivity.webpageURL {
            let scheme = webUrl.scheme?.lowercased() ?? ""
            if scheme == "tel" || scheme == "telprompt" || scheme == "simbridge" {
                handleIncomingUrl(webUrl)
                return true
            }
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
        let scheme = url.scheme?.lowercased() ?? ""
        var rawTarget: String?
        if scheme == "tel" || scheme == "telprompt" {
            let raw = url.absoluteString.replacingOccurrences(
                of: "^(?i)tel(prompt)?:(//)?",
                with: "",
                options: .regularExpression
            )
            let decoded = raw.removingPercentEncoding ?? raw
            let cleaned = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                rawTarget = cleaned
            }
        } else if scheme == "simbridge" {
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
                        BridgeClient.shared.setAppForegroundState(true)
                        BridgeClient.shared.handleAppBecameActive()
                        ContactsHelper.shared.refreshAuthorizationStatus()
                        NotificationManager.shared.refreshAuthorizationStatus()
                        LocationKeepAliveManager.shared.refreshAuthorizationState()
                        LocationKeepAliveManager.shared.promptIfNotDetermined()
                    } else if newPhase == .background {
                        BridgeClient.shared.setAppForegroundState(false)
                        LocationKeepAliveManager.shared.startIfAuthorized()
                        AppDelegate.scheduleAppRefresh()
                    }
                }
        }
    }
}

struct MainTabView: View {
    @ObservedObject private var bridge = BridgeClient.shared
    @ObservedObject private var router = AppRouter.shared

    private var unreadSmsCount: Int {
        bridge.smsMessages.filter { !$0.isOutgoing && !$0.isRead }.count
    }

    var body: some View {
        TabView(selection: $router.selectedTab) {
            DialerView()
                .tabItem { Label("Tuşlar", systemImage: "circle.grid.3x3.fill") }
                .tag(AppTab.dialer)

            RecentsView()
                .tabItem { Label("Aramalar", systemImage: "clock.fill") }
                .tag(AppTab.recents)

            SmsView()
                .tabItem { Label("Mesajlar", systemImage: "message.fill") }
                .badge(unreadSmsCount)
                .tag(AppTab.sms)

            SettingsView()
                .tabItem {
                    Label(
                        "Ayarlar",
                        systemImage: bridge.isConnected ? "antenna.radiowaves.left.and.right" : "gear"
                    )
                }
                .tag(AppTab.settings)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !bridge.activeCalls.isEmpty || bridge.lastCallError != nil {
                VStack(spacing: 6) {
                    GlobalErrorBanner()
                    if let active = bridge.activeCalls.first {
                        GlobalActiveCallBar(call: active)
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 6)
                .background(.ultraThinMaterial)
            }
        }
        .sheet(isPresented: $router.activeCallSheetPresented) {
            ActiveCallDetailSheet()
                .presentationDetents([.medium, .large])
        }
        .onChange(of: bridge.activeCalls.isEmpty) { isEmpty in
            if isEmpty && router.activeCallSheetPresented {
                router.activeCallSheetPresented = false
            }
        }
        .onAppear {
            UNUserNotificationCenter.current().setBadgeCount(unreadSmsCount, withCompletionHandler: nil)
        }
        .onChange(of: unreadSmsCount) { count in
            UNUserNotificationCenter.current().setBadgeCount(count, withCompletionHandler: nil)
        }
    }
}
